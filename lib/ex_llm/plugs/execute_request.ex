defmodule ExLLM.Plugs.ExecuteRequest do
  @moduledoc """
  Executes the HTTP request to the LLM provider using the configured Tesla client.

  This plug expects:
  - `request.tesla_client` - A configured Tesla client (from BuildTeslaClient)
  - `request.provider_request` - The formatted request body (from provider-specific PrepareRequest)

  After execution, it sets:
  - `request.response` - The raw Tesla response
  - `request.state` - Updated to `:completed` or `:error`

  ## Options

    * `:endpoint` - Override the endpoint path (defaults to provider-specific)
    * `:method` - HTTP method (defaults to :post)
    
  ## Examples

      plug ExLLM.Plugs.ExecuteRequest
      
      # With custom endpoint
      plug ExLLM.Plugs.ExecuteRequest, endpoint: "/v1/completions"
  """

  use ExLLM.Plug
  alias ExLLM.Infrastructure.Logger
  alias ExLLM.Pipeline.Request
  alias ExLLM.Testing.TestResponseInterceptor, as: TestResponseInterceptor

  @impl true
  def init(opts) do
    Keyword.validate!(opts, [:endpoint, :method])
  end

  @impl true
  def call(%Request{tesla_client: nil} = request, _opts) do
    request
    |> Request.halt_with_error(%{
      plug: __MODULE__,
      error: :missing_tesla_client,
      message: "Tesla client not configured. Did BuildTeslaClient run?"
    })
  end

  def call(%Request{provider_request: nil} = request, _opts) do
    request
    |> Request.halt_with_error(%{
      plug: __MODULE__,
      error: :missing_provider_request,
      message: "Provider request not prepared. Did PrepareRequest run?"
    })
  end

  def call(%Request{} = request, opts) do
    endpoint =
      opts[:endpoint] || request.assigns[:http_path] || get_provider_endpoint(request)

    method = opts[:method] || request.assigns[:http_method] || :post

    # Log the request in debug mode
    Logger.debug("""
    ExLLM ExecuteRequest:
    Provider: #{request.provider}
    Endpoint: #{endpoint}
    Model: #{request.config[:model]}
    Method: #{method}
    Tesla client middleware: #{inspect(request.tesla_client.pre)}
    """)

    # Debug log specifically for streaming
    if request.options[:stream] do
      Logger.debug("ExecuteRequest: This is a STREAMING request")
    end

    # Update state to executing
    request = Request.put_state(request, :executing)

    # Intercept request if caching is enabled
    case maybe_intercept_request(request, endpoint, method) do
      {:cached, final_request, %Tesla.Env{} = cached_response} ->
        # Cache hit, response is already prepared.
        handle_tesla_response(final_request, cached_response)

      {:proceed, request_to_execute} ->
        # Cache miss or caching disabled, make the real request.
        case make_request(
               request_to_execute.tesla_client,
               method,
               endpoint,
               request_to_execute.provider_request
             ) do
          {:ok, response} ->
            maybe_save_response(request_to_execute, response)
            handle_tesla_response(request_to_execute, response)

          {:error, reason} ->
            # Network or other error
            error = build_network_error(reason, request_to_execute.provider)

            request_to_execute
            |> Request.halt_with_error(error)
        end
    end
  end

  defp maybe_intercept_request(request, endpoint, method) do
    if TestResponseInterceptor.should_intercept_request?() do
      # Extract base URL from Tesla client middleware
      base_url =
        request.tesla_client.pre
        |> Enum.find_value(fn
          {Tesla.Middleware.BaseUrl, url} -> url
          _ -> nil
        end)

      url = if base_url, do: base_url <> endpoint, else: endpoint

      body = request.provider_request

      headers =
        request.tesla_client.pre
        |> Enum.find_value([], fn
          {Tesla.Middleware.Headers, h} -> h
          _ -> nil
        end)

      opts = [
        method: to_string(method) |> String.upcase(),
        provider: request.provider
      ]

      case TestResponseInterceptor.intercept_request(url, body, headers, opts) do
        {:cached, cached_body} ->
          # Add from_cache metadata to the cached response body
          enhanced_body =
            case cached_body do
              body when is_map(body) ->
                existing_metadata = Map.get(body, "metadata", %{})
                enhanced_metadata = Map.put(existing_metadata, :from_cache, true)
                Map.put(body, "metadata", enhanced_metadata)

              body ->
                # If body is not a map, we can't add metadata to it
                body
            end

          # Create a fake Tesla.Env with status 200.
          # We need to match the expected Tesla.Env structure more closely
          # to satisfy dialyzer
          fake_response = %Tesla.Env{
            status: 200,
            body: enhanced_body,
            headers: [],
            method: :post,
            url: url,
            query: [],
            opts: opts
          }

          # Also set the metadata on the request for consistency
          updated_request = Request.put_metadata(request, :from_cache, true)
          {:cached, updated_request, fake_response}

        {:proceed, request_metadata} ->
          updated_request = %{request | metadata: Map.merge(request.metadata, request_metadata)}
          {:proceed, updated_request}
      end
    else
      {:proceed, request}
    end
  end

  defp maybe_save_response(
         request,
         %Tesla.Env{status: status, body: body, headers: headers}
       )
       when status in 200..299 do
    response_info = %{http_status: status, response_headers: headers}
    TestResponseInterceptor.save_response(request.metadata, body, response_info)
  end

  defp maybe_save_response(_request, _response), do: :ok

  defp make_request(client, :post, endpoint, body) do
    Tesla.post(client, endpoint, body)
  end

  defp make_request(client, :get, endpoint, _body) do
    Tesla.get(client, endpoint)
  end

  defp make_request(client, :put, endpoint, body) do
    Tesla.put(client, endpoint, body)
  end

  defp make_request(client, :patch, endpoint, body) do
    Tesla.patch(client, endpoint, body)
  end

  defp make_request(client, :delete, endpoint, _body) do
    Tesla.delete(client, endpoint)
  end

  defp handle_tesla_response(%Request{} = request, %Tesla.Env{} = response) do
    if ExLLM.HTTP.successful?(response) do
      # Handle successful Tesla responses
      status = ExLLM.HTTP.get_status(response)
      headers = ExLLM.HTTP.get_headers(response)
      body = ExLLM.HTTP.get_body(response)

      # Handle response body (may already be parsed by Tesla middleware)
      parsed_body =
        case body do
          body when is_binary(body) ->
            case Jason.decode(body) do
              {:ok, parsed} -> parsed
              {:error, _} -> body
            end

          body ->
            # Already parsed (e.g., by Tesla JSON middleware)
            body
        end

      result =
        request
        |> Map.put(:response, response)
        |> Request.assign(:http_response, parsed_body)
        |> Request.put_state(:completed)
        |> Request.put_metadata(:http_status, status)

      result
      |> Request.put_metadata(:response_headers, headers)
    else
      # Handle error Tesla responses with status
      status = ExLLM.HTTP.get_status(response)
      body = ExLLM.HTTP.get_body(response)
      error = build_http_error(status, body, request.provider)

      request
      |> Map.put(:response, response)
      |> Request.halt_with_error(error)
    end
  end

  defp get_provider_endpoint(%Request{provider: :anthropic}), do: "/v1/messages"

  defp get_provider_endpoint(%Request{provider: :gemini, config: config}) do
    model = config[:model] || "gemini-2.0-flash"
    is_streaming = config[:stream] == true
    endpoint = if is_streaming, do: "streamGenerateContent", else: "generateContent"
    "/models/#{model}:#{endpoint}"
  end

  defp get_provider_endpoint(%Request{provider: :ollama}), do: "/api/chat"
  defp get_provider_endpoint(%Request{provider: :perplexity}), do: "/chat/completions"
  defp get_provider_endpoint(%Request{}), do: "/v1/chat/completions"

  defp build_http_error(401, body, provider) do
    %{
      plug: __MODULE__,
      error: :unauthorized,
      message: "Authentication failed for #{provider}. Check your API key.",
      status: 401,
      body: body,
      provider: provider
    }
  end

  defp build_http_error(403, body, provider) do
    %{
      plug: __MODULE__,
      error: :forbidden,
      message: "Access forbidden for #{provider}. Check your permissions.",
      status: 403,
      body: body,
      provider: provider
    }
  end

  defp build_http_error(404, _body, provider) do
    %{
      plug: __MODULE__,
      error: :not_found,
      message: "Endpoint not found for #{provider}. The API may have changed.",
      status: 404,
      provider: provider
    }
  end

  defp build_http_error(429, body, provider) do
    # Try to extract retry-after header
    retry_after = extract_retry_after(body)

    %{
      plug: __MODULE__,
      error: :rate_limited,
      message: "Rate limit exceeded for #{provider}.",
      status: 429,
      body: body,
      provider: provider,
      retry_after: retry_after
    }
  end

  defp build_http_error(500, body, provider) do
    %{
      plug: __MODULE__,
      error: :server_error,
      message: "Internal server error from #{provider}.",
      status: 500,
      body: body,
      provider: provider
    }
  end

  defp build_http_error(status, body, provider) do
    %{
      plug: __MODULE__,
      error: :http_error,
      message: "HTTP error #{status} from #{provider}.",
      status: status,
      body: body,
      provider: provider
    }
  end

  defp build_network_error(:timeout, provider) do
    %{
      plug: __MODULE__,
      error: :timeout,
      message: "Request timeout for #{provider}.",
      provider: provider
    }
  end

  defp build_network_error(:econnrefused, provider) do
    %{
      plug: __MODULE__,
      error: :connection_refused,
      message: "Connection refused for #{provider}. Is the service running?",
      provider: provider
    }
  end

  defp build_network_error(%{reason: :circuit_open} = error, provider) do
    %{
      plug: __MODULE__,
      error: :circuit_open,
      message: error[:message] || "Circuit breaker open for #{provider}.",
      provider: provider,
      retry_after: error[:retry_after]
    }
  end

  defp build_network_error(reason, provider) do
    %{
      plug: __MODULE__,
      error: :network_error,
      message: "Network error for #{provider}: #{inspect(reason)}",
      reason: reason,
      provider: provider
    }
  end

  defp extract_retry_after(body) when is_map(body) do
    # Try common fields where retry-after might be
    body["retry_after"] || body["retryAfter"] || body["retry-after"] || nil
  end

  defp extract_retry_after(_), do: nil
end
