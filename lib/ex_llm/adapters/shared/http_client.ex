defmodule ExLLM.Adapters.Shared.HTTPClient do
  @moduledoc """
  Shared HTTP client utilities for ExLLM adapters.

  Provides common HTTP functionality including:
  - JSON API requests with proper headers
  - Server-Sent Events (SSE) streaming support
  - Standardized error handling
  - Response parsing utilities

  This module abstracts common HTTP patterns to reduce duplication
  across provider adapters.
  """

  alias ExLLM.Error
  alias ExLLM.Logger
  alias ExLLM.TestResponseInterceptor

  # 60 seconds
  @default_timeout 60_000
  # 5 minutes for streaming
  @stream_timeout 300_000

  @doc """
  Make a POST request with JSON body to an API endpoint.

  ## Options
  - `:timeout` - Request timeout in milliseconds (default: 60s)
  - `:recv_timeout` - Receive timeout for streaming (default: 5m)
  - `:stream` - Whether this is a streaming request

  ## Examples

      HTTPClient.post_json("https://api.example.com/v1/chat", 
        %{messages: messages},
        [{"Authorization", "Bearer sk-..."}],
        timeout: 30_000
      )
  """
  @spec post_json(String.t(), map(), list({String.t(), String.t()}), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_json(url, body, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    method = Keyword.get(opts, :method, :post)
    provider = Keyword.get(opts, :provider, :unknown)

    headers = prepare_headers(headers)

    # Check test cache before making request
    case TestResponseInterceptor.intercept_request(url, body, headers, opts) do
      {:cached, cached_response} ->
        # Return cached response with metadata
        if Application.get_env(:ex_llm, :debug_test_cache, false) do
          IO.puts("HTTPClient received cached response: #{inspect(Map.keys(cached_response))}")
        end

        response_with_metadata = add_cache_metadata(cached_response)

        if Application.get_env(:ex_llm, :debug_test_cache, false) do
          IO.puts(
            "HTTPClient response after add_cache_metadata: #{inspect(Map.get(response_with_metadata, "metadata"))}"
          )
        end

        {:ok, response_with_metadata}

      {:proceed, request_metadata} ->
        # Make real request
        make_real_request(url, body, headers, method, timeout, provider, request_metadata)

      {:error, _reason} ->
        # Cache error, proceed with real request
        make_real_request(url, body, headers, method, timeout, provider, %{})
    end
  end

  @doc """
  Make a GET request to an API endpoint with proper caching support.

  ## Options
  - `:timeout` - Request timeout in milliseconds (default: 60s)
  - `:provider` - Provider name for logging and caching

  ## Examples

      HTTPClient.get_json("https://api.example.com/v1/models", 
        [{"Authorization", "Bearer sk-..."}],
        provider: :openai
      )
  """
  @spec get_json(String.t(), list({String.t(), String.t()}), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_json(url, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    provider = Keyword.get(opts, :provider, :unknown)

    headers = prepare_headers(headers)

    # Check test cache before making request
    case TestResponseInterceptor.intercept_request(url, %{}, headers, opts) do
      {:cached, cached_response} ->
        # Return cached response with metadata
        {:ok, add_cache_metadata(cached_response)}

      {:proceed, request_metadata} ->
        # Make real GET request
        make_real_get_request(url, headers, timeout, provider, request_metadata)
    end
  end

  @doc """
  Make a streaming POST request using Req's into option.

  This is used by StreamingCoordinator for unified streaming.

  ## Examples

      HTTPClient.post_stream(url, body, [
        headers: headers,
        into: stream_collector_fn
      ])
  """
  @spec post_stream(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def post_stream(url, body, opts \\ []) do
    headers = Keyword.get(opts, :headers, []) |> prepare_headers()
    provider = Keyword.get(opts, :provider, :unknown)

    # Check test cache for streaming requests
    case TestResponseInterceptor.intercept_request(url, body, headers, opts) do
      {:cached, cached_response} ->
        # For streaming, we need to simulate streaming behavior
        simulate_cached_stream(cached_response, opts)

      {:proceed, request_metadata} ->
        # Make real streaming request
        make_real_streaming_request(url, body, headers, provider, request_metadata, opts)

      {:error, _reason} ->
        # Cache error, proceed with real request
        make_real_streaming_request(url, body, headers, provider, %{}, opts)
    end
  end

  @doc """
  Make a streaming POST request that returns Server-Sent Events.

  The callback function will be called for each chunk received.

  ## Examples

      HTTPClient.stream_request(url, body, headers, fn chunk ->
        # Process each SSE chunk
        IO.puts("Received: " <> chunk)
      end)
  """
  @spec stream_request(String.t(), map(), list({String.t(), String.t()}), function(), keyword()) ::
          {:ok, any()} | {:error, term()}
  def stream_request(url, body, headers, callback, opts \\ []) do
    timeout = Keyword.get(opts, :recv_timeout, @stream_timeout)
    parent = self()

    headers = prepare_headers(headers) ++ [{"Accept", "text/event-stream"}]

    # Check test cache for SSE streaming requests
    case TestResponseInterceptor.intercept_request(url, body, headers, opts) do
      {:cached, cached_response} ->
        # Simulate SSE streaming from cached response
        Task.start(fn ->
          simulate_sse_from_cache(cached_response, parent, callback)
        end)

        {:ok, :streaming}

      {:proceed, request_metadata} ->
        # Start async task for real streaming request
        Task.start(fn ->
          start_streaming_request_with_caching(
            url,
            body,
            headers,
            timeout,
            parent,
            callback,
            request_metadata,
            opts
          )
        end)

        {:ok, :streaming}

      {:error, _reason} ->
        # Cache error, proceed with real request
        Task.start(fn ->
          start_streaming_request(url, body, headers, timeout, parent, callback, opts)
        end)

        {:ok, :streaming}
    end
  end

  defp start_streaming_request(url, body, headers, timeout, parent, callback, opts) do
    case Req.post(url, json: body, headers: headers, receive_timeout: timeout, into: :self) do
      {:ok, response} ->
        handle_streaming_response(response, parent, callback, opts)

      {:error, reason} ->
        send(parent, {:stream_error, Error.connection_error(reason)})
    end
  end

  defp handle_streaming_response(response, parent, callback, opts) do
    if response.status in 200..299 do
      handle_req_stream_response(response, parent, callback, "", opts)
    else
      handle_streaming_error(response, parent, opts)
    end
  end

  defp handle_streaming_error(response, parent, opts) do
    # Extract the actual body content, handling async responses
    body =
      case response.body do
        %Req.Response.Async{} ->
          # For async responses, we can't get the body here
          %{"error" => "Streaming error", "status" => response.status}

        other ->
          other
      end

    if error_handler = Keyword.get(opts, :on_error) do
      # Only encode if it's not already a string
      body_string =
        case body do
          body when is_binary(body) -> body
          _ -> Jason.encode!(body)
        end

      error_handler.(response.status, body_string)
    else
      send(parent, {:stream_error, Error.api_error(response.status, body)})
    end
  end

  @doc """
  Parse Server-Sent Events from a data buffer.

  Returns parsed events and remaining buffer.

  ## Examples

      {events, new_buffer} = HTTPClient.parse_sse_chunks("data: {\"text\":\"Hi\"}\\n\\n", "")
  """
  @spec parse_sse_chunks(binary(), binary()) :: {list(map()), binary()}
  def parse_sse_chunks(data, buffer) do
    lines = String.split(buffer <> data, "\n")
    {complete_lines, [last_line]} = Enum.split(lines, -1)

    events =
      complete_lines
      |> Enum.chunk_by(&(&1 == ""))
      |> Enum.reject(&(&1 == [""]))
      |> Enum.map(&parse_sse_event/1)
      |> Enum.reject(&is_nil/1)

    {events, last_line}
  end

  @doc """
  Build a standardized User-Agent header for ExLLM.
  """
  @spec user_agent() :: {String.t(), String.t()}
  def user_agent do
    version = Application.spec(:ex_llm, :vsn) |> to_string()
    {"User-Agent", "ExLLM/#{version} (Elixir)"}
  end

  @doc """
  Build provider-specific headers for API requests.

  ## Options
  - `:provider` - Provider name for specific headers
  - `:api_key` - API key for authorization
  - `:version` - API version header
  - `:organization` - Organization ID (OpenAI)
  - `:project` - Project ID (OpenAI)

  ## Examples

      HTTPClient.build_provider_headers(:openai, 
        api_key: "sk-...", 
        organization: "org-123"
      )
  """
  @spec build_provider_headers(atom(), keyword()) :: list({String.t(), String.t()})
  def build_provider_headers(provider, opts \\ []) do
    base_headers = [
      {"Content-Type", "application/json"},
      user_agent()
    ]

    provider_headers = build_provider_specific_headers(provider, opts)
    base_headers ++ provider_headers
  end

  @doc """
  Prepare headers with common defaults.

  Adds Content-Type and User-Agent if not present.
  """
  @spec prepare_headers(list({String.t(), String.t()})) :: list({String.t(), String.t()})
  def prepare_headers(headers) do
    default_headers = [
      {"Content-Type", "application/json"},
      user_agent()
    ]

    # Merge with defaults, preferring provided headers
    Enum.reduce(default_headers, headers, fn {key, value}, acc ->
      if List.keyfind(acc, key, 0) do
        acc
      else
        [{key, value} | acc]
      end
    end)
  end

  @doc """
  Handle API error responses consistently.

  Attempts to parse error details from JSON responses.
  """
  @spec handle_api_error(integer(), String.t() | map()) :: {:error, term()}
  def handle_api_error(status, body) do
    # Handle both string and map bodies (Req might decode JSON automatically)
    parsed_body =
      case body do
        body when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, decoded} -> decoded
            {:error, _} -> %{"error" => body}
          end

        body when is_map(body) ->
          body
      end

    case parsed_body do
      %{"error" => error} when is_map(error) ->
        handle_structured_error(status, error)

      %{"error" => message} when is_binary(message) ->
        categorize_error(status, message)

      %{"message" => message} ->
        categorize_error(status, message)

      _ ->
        Error.api_error(status, body)
    end
  end

  # Private functions

  defp handle_error_response(status, body) do
    handle_api_error(status, body)
  end

  defp handle_req_stream_response(response, parent, callback, buffer, opts) do
    %Req.Response.Async{ref: ref} = response.body
    provider = Keyword.get(opts, :provider, :unknown)

    receive do
      {^ref, {:data, data}} ->
        {events, new_buffer} = parse_sse_chunks(data, buffer)

        # Log chunk received if streaming logging is enabled
        if length(events) > 0 do
          Logger.log_stream_event(provider, :chunk_received, %{
            event_count: length(events),
            buffer_size: byte_size(new_buffer)
          })
        end

        Enum.each(events, fn event ->
          if event.data != "[DONE]" do
            callback.(event.data)
          end
        end)

        handle_req_stream_response(response, parent, callback, new_buffer, opts)

      {^ref, :done} ->
        Logger.log_stream_event(provider, :stream_complete, %{})
        send(parent, :stream_done)

      {^ref, {:error, reason}} ->
        Logger.log_stream_event(provider, :stream_error, %{reason: inspect(reason)})
        send(parent, {:stream_error, Error.connection_error(reason)})
    after
      Keyword.get(opts, :recv_timeout, @stream_timeout) ->
        Logger.log_stream_event(provider, :stream_timeout, %{timeout_ms: @stream_timeout})
        send(parent, {:stream_error, {:error, :timeout}})
    end
  end

  defp parse_sse_event(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          # SSE event keys are limited to: event, data, id, retry
          case key do
            "event" -> Map.put(acc, :event, String.trim_leading(value))
            "data" -> Map.put(acc, :data, String.trim_leading(value))
            "id" -> Map.put(acc, :id, String.trim_leading(value))
            "retry" -> Map.put(acc, :retry, String.trim_leading(value))
            # Ignore unknown keys for safety
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> case do
      %{data: _} = event -> event
      _ -> nil
    end
  end

  defp handle_structured_error(status, %{"type" => type} = error) do
    message = error["message"] || "Unknown error"

    case type do
      "authentication_error" -> Error.authentication_error(message)
      "rate_limit_error" -> Error.rate_limit_error(message)
      "invalid_request_error" -> Error.validation_error(:request, message)
      _ -> Error.api_error(status, error)
    end
  end

  defp handle_structured_error(status, error) do
    Error.api_error(status, error)
  end

  defp categorize_error(401, message), do: Error.authentication_error(message)
  defp categorize_error(429, message), do: Error.rate_limit_error(message)
  defp categorize_error(503, message), do: Error.service_unavailable(message)
  defp categorize_error(status, message), do: Error.api_error(status, message)

  # Provider-specific header builders

  defp build_provider_specific_headers(:openai, opts) do
    headers = []

    headers =
      if api_key = Keyword.get(opts, :api_key) do
        [{"Authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    headers =
      if org_id = Keyword.get(opts, :organization) do
        [{"OpenAI-Organization", org_id} | headers]
      else
        headers
      end

    headers =
      if project_id = Keyword.get(opts, :project) do
        [{"OpenAI-Project", project_id} | headers]
      else
        headers
      end

    headers
  end

  defp build_provider_specific_headers(:anthropic, opts) do
    headers = [{"anthropic-version", "2023-06-01"}]

    if api_key = Keyword.get(opts, :api_key) do
      [{"x-api-key", api_key} | headers]
    else
      headers
    end
  end

  defp build_provider_specific_headers(:gemini, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:groq, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:xai, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:openrouter, opts) do
    headers = []

    headers =
      if api_key = Keyword.get(opts, :api_key) do
        [{"Authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    headers =
      if site_url = Keyword.get(opts, :site_url) do
        [{"HTTP-Referer", site_url} | headers]
      else
        headers
      end

    headers =
      if app_name = Keyword.get(opts, :app_name) do
        [{"X-Title", app_name} | headers]
      else
        headers
      end

    headers
  end

  defp build_provider_specific_headers(:mistral, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:perplexity, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:bedrock, opts) do
    # AWS Bedrock uses AWS SigV4 authentication, handled elsewhere
    headers = [{"Content-Type", "application/json"}]

    if _version = Keyword.get(opts, :version) do
      [{"Accept", "application/json, application/vnd.amazon.eventstream"} | headers]
    else
      headers
    end
  end

  defp build_provider_specific_headers(:cohere, opts) do
    headers = []

    headers =
      if api_key = Keyword.get(opts, :api_key) do
        [{"Authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    # Cohere requires specific version header
    [{"X-Client-Name", "ExLLM"} | headers]
  end

  defp build_provider_specific_headers(:together_ai, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:replicate, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Token #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:huggingface, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:deepinfra, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:fireworks, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:databricks, opts) do
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:vertex_ai, opts) do
    # Google Cloud Vertex AI uses OAuth2 bearer tokens
    if access_token = Keyword.get(opts, :access_token) do
      [{"Authorization", "Bearer #{access_token}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:azure, opts) do
    headers = []

    headers =
      if api_key = Keyword.get(opts, :api_key) do
        [{"api-key", api_key} | headers]
      else
        headers
      end

    # Azure OpenAI service requires API version
    if api_version = Keyword.get(opts, :api_version) do
      [{"api-version", api_version} | headers]
    else
      headers
    end
  end

  defp build_provider_specific_headers(:lmstudio, opts) do
    # LM Studio local server
    if api_key = Keyword.get(opts, :api_key) do
      [{"Authorization", "Bearer #{api_key}"}]
    else
      []
    end
  end

  defp build_provider_specific_headers(:ollama, _opts) do
    # Ollama typically doesn't require auth
    []
  end

  defp build_provider_specific_headers(_provider, _opts), do: []

  # Test caching private helper functions

  defp make_real_request(url, body, headers, method, timeout, provider, request_metadata) do
    # Log request
    Logger.log_request(provider, url, body, headers)

    req_opts = [headers: headers, receive_timeout: timeout]

    start_time = System.monotonic_time(:millisecond)

    result =
      case method do
        :get -> Req.get(url, req_opts)
        :post -> Req.post(url, [json: body] ++ req_opts)
        :put -> Req.put(url, [json: body] ++ req_opts)
        :patch -> Req.patch(url, [json: body] ++ req_opts)
        :delete -> Req.delete(url, req_opts)
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        # Log successful response
        Logger.log_response(provider, %{status: status, body: response_body}, duration)

        # Save to test cache if enabled
        response_info = %{
          status_code: status,
          headers: [],
          completed_at: DateTime.utc_now(),
          response_time_ms: duration
        }

        TestResponseInterceptor.save_response(request_metadata, response_body, response_info)

        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        # Log error response
        Logger.error("API error response",
          provider: provider,
          status: status,
          body: response_body,
          duration_ms: duration
        )

        # Save error response to cache if enabled
        error_response = %{error: response_body, status: status}

        response_info = %{
          status_code: status,
          headers: [],
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        handle_error_response(status, response_body)

      {:error, reason} ->
        # Log connection error
        Logger.error("Connection error",
          provider: provider,
          error: reason,
          duration_ms: duration
        )

        # Save connection error to cache if enabled
        error_response = %{error: reason, type: "connection_error"}

        response_info = %{
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        Error.connection_error(reason)
    end
  end

  defp make_real_get_request(url, headers, timeout, provider, request_metadata) do
    # Log request
    Logger.log_request(provider, url, nil, headers)

    req_opts = [headers: headers, receive_timeout: timeout]

    start_time = System.monotonic_time(:millisecond)

    result = Req.get(url, req_opts)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        # Log successful response
        Logger.log_response(provider, %{status: status, body: response_body}, duration)

        # Save to test cache if enabled
        response_info = %{
          status_code: status,
          headers: [],
          completed_at: DateTime.utc_now(),
          response_time_ms: duration
        }

        TestResponseInterceptor.save_response(request_metadata, response_body, response_info)

        {:ok, %{status: status, body: add_cache_metadata(response_body)}}

      {:ok, %{status: status, body: response_body}} ->
        # Log error response
        Logger.error("API error response",
          provider: provider,
          status: status,
          duration_ms: duration
        )

        # Save error response to cache if enabled
        error_response = %{error: response_body, status: status}

        response_info = %{
          status_code: status,
          headers: [],
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        {:error, handle_error_response(status, response_body)}

      {:error, reason} ->
        # Log connection error
        Logger.error("Connection error",
          provider: provider,
          error: reason,
          duration_ms: duration
        )

        # Save connection error to cache
        error_response = %{connection_error: reason}

        response_info = %{
          status_code: nil,
          headers: [],
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        {:error, Error.connection_error(reason)}
    end
  end

  defp make_real_streaming_request(url, body, headers, provider, request_metadata, opts) do
    # Log streaming request
    Logger.log_stream_event(provider, :request_start, %{
      url: url,
      body_preview: inspect(body, limit: 100)
    })

    req_opts = [
      json: body,
      headers: headers,
      receive_timeout: Keyword.get(opts, :receive_timeout, @stream_timeout)
    ]

    # Add the into option if provided
    req_opts =
      case Keyword.get(opts, :into) do
        nil -> req_opts
        collector -> Keyword.put(req_opts, :into, collector)
      end

    start_time = System.monotonic_time(:millisecond)

    case Req.post(url, req_opts) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        Logger.log_stream_event(provider, :response_ok, %{status: status})

        # For streaming, we would need to capture the complete response
        # This is more complex and might be handled by the streaming coordinator
        duration = System.monotonic_time(:millisecond) - start_time

        response_info = %{
          status_code: status,
          headers: [],
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          streaming: true
        }

        TestResponseInterceptor.save_response(request_metadata, response, response_info)

        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        Logger.log_stream_event(provider, :response_error, %{status: status, body: body})

        # Save streaming error to cache
        duration = System.monotonic_time(:millisecond) - start_time
        error_response = %{error: body, status: status, type: "streaming_error"}

        response_info = %{
          status_code: status,
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          streaming: true,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        handle_error_response(status, body)

      {:error, reason} ->
        Logger.log_stream_event(provider, :connection_error, %{reason: inspect(reason)})

        # Save connection error to cache
        duration = System.monotonic_time(:millisecond) - start_time
        error_response = %{error: reason, type: "streaming_connection_error"}

        response_info = %{
          completed_at: DateTime.utc_now(),
          response_time_ms: duration,
          streaming: true,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        {:error, Error.connection_error(reason)}
    end
  end

  defp simulate_cached_stream(cached_response, opts) do
    # Simulate streaming behavior from cached response
    case Keyword.get(opts, :into) do
      nil ->
        # Return response directly if no collector
        {:ok, cached_response}

      collector when is_function(collector) ->
        # Simulate streaming with collector function
        case Map.get(cached_response, "chunks") do
          chunks when is_list(chunks) ->
            # Replay chunks through collector
            Task.start(fn ->
              Enum.each(chunks, fn chunk ->
                collector.(chunk)
                # Add small delay to simulate streaming
                Process.sleep(10)
              end)
            end)

            {:ok, cached_response}

          _ ->
            # No chunks available, return as single chunk
            collector.(cached_response)
            {:ok, cached_response}
        end

      _ ->
        {:ok, cached_response}
    end
  end

  defp start_streaming_request_with_caching(
         url,
         body,
         headers,
         timeout,
         parent,
         callback,
         request_metadata,
         opts
       ) do
    case Req.post(url, json: body, headers: headers, receive_timeout: timeout, into: :self) do
      {:ok, response} ->
        handle_streaming_response_with_caching(response, parent, callback, request_metadata, opts)

      {:error, reason} ->
        # Save streaming error to cache
        error_response = %{error: reason, type: "streaming_connection_error"}

        response_info = %{
          completed_at: DateTime.utc_now(),
          streaming: true,
          error: true
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        send(parent, {:stream_error, Error.connection_error(reason)})
    end
  end

  defp handle_streaming_response_with_caching(response, parent, callback, request_metadata, opts) do
    if response.status in 200..299 do
      handle_req_stream_response_with_caching(
        response,
        parent,
        callback,
        "",
        request_metadata,
        opts
      )
    else
      # Save streaming error to cache
      error_response = %{error: response.body, status: response.status, type: "streaming_error"}

      response_info = %{
        status_code: response.status,
        completed_at: DateTime.utc_now(),
        streaming: true,
        error: true
      }

      TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

      handle_streaming_error(response, parent, opts)
    end
  end

  defp handle_req_stream_response_with_caching(
         response,
         parent,
         callback,
         buffer,
         request_metadata,
         opts
       ) do
    %Req.Response.Async{ref: ref} = response.body
    provider = Keyword.get(opts, :provider, :unknown)

    # Accumulate chunks for caching
    accumulated_chunks = []

    stream_loop(
      ref,
      parent,
      callback,
      buffer,
      request_metadata,
      provider,
      accumulated_chunks,
      opts
    )
  end

  defp stream_loop(
         ref,
         parent,
         callback,
         buffer,
         request_metadata,
         provider,
         accumulated_chunks,
         opts
       ) do
    receive do
      {^ref, {:data, data}} ->
        {events, new_buffer} = parse_sse_chunks(data, buffer)

        # Log chunk received if streaming logging is enabled
        if length(events) > 0 do
          Logger.log_stream_event(provider, :chunk_received, %{
            event_count: length(events),
            buffer_size: byte_size(new_buffer)
          })
        end

        # Accumulate chunks for caching
        new_accumulated = accumulated_chunks ++ events

        Enum.each(events, fn event ->
          if event.data != "[DONE]" do
            callback.(event.data)
          end
        end)

        stream_loop(
          ref,
          parent,
          callback,
          new_buffer,
          request_metadata,
          provider,
          new_accumulated,
          opts
        )

      {^ref, :done} ->
        Logger.log_stream_event(provider, :stream_complete, %{})

        # Save complete streaming response to cache
        complete_response = %{
          type: "streaming_complete",
          chunks: accumulated_chunks,
          chunk_count: length(accumulated_chunks)
        }

        response_info = %{
          completed_at: DateTime.utc_now(),
          streaming: true,
          chunk_count: length(accumulated_chunks)
        }

        TestResponseInterceptor.save_response(request_metadata, complete_response, response_info)

        send(parent, :stream_done)

      {^ref, {:error, reason}} ->
        Logger.log_stream_event(provider, :stream_error, %{reason: inspect(reason)})

        # Save partial streaming response with error
        error_response = %{
          error: reason,
          type: "streaming_partial_error",
          chunks: accumulated_chunks,
          chunk_count: length(accumulated_chunks)
        }

        response_info = %{
          completed_at: DateTime.utc_now(),
          streaming: true,
          error: true,
          chunk_count: length(accumulated_chunks)
        }

        TestResponseInterceptor.save_response(request_metadata, error_response, response_info)

        send(parent, {:stream_error, Error.connection_error(reason)})
    after
      Keyword.get(opts, :recv_timeout, @stream_timeout) ->
        Logger.log_stream_event(provider, :stream_timeout, %{timeout_ms: @stream_timeout})

        # Save timeout response
        timeout_response = %{
          error: :timeout,
          type: "streaming_timeout",
          chunks: accumulated_chunks,
          chunk_count: length(accumulated_chunks)
        }

        response_info = %{
          completed_at: DateTime.utc_now(),
          streaming: true,
          error: true,
          chunk_count: length(accumulated_chunks)
        }

        TestResponseInterceptor.save_response(request_metadata, timeout_response, response_info)

        send(parent, {:stream_error, {:error, :timeout}})
    end
  end

  defp simulate_sse_from_cache(cached_response, parent, callback) do
    # Simulate SSE streaming from cached response
    case Map.get(cached_response, "chunks") do
      chunks when is_list(chunks) ->
        # Replay chunks with small delays to simulate streaming
        Enum.each(chunks, fn chunk ->
          if Map.get(chunk, "data") != "[DONE]" do
            callback.(Map.get(chunk, "data", chunk))
          end

          # Small delay to simulate streaming
          Process.sleep(10)
        end)

        send(parent, :stream_done)

      _ ->
        # No chunks available, simulate single response
        callback.(Jason.encode!(cached_response))
        send(parent, :stream_done)
    end
  end

  @doc """
  Add rate limit headers to the request.

  Some providers support rate limit hints in request headers.
  """
  @spec add_rate_limit_headers(list({String.t(), String.t()}), atom(), keyword()) ::
          list({String.t(), String.t()})
  def add_rate_limit_headers(headers, provider, opts \\ []) do
    case provider do
      :openai ->
        # OpenAI supports rate limit increase requests
        if requests_per_minute = Keyword.get(opts, :requests_per_minute) do
          [{"X-Request-RPM", to_string(requests_per_minute)} | headers]
        else
          headers
        end

      _ ->
        headers
    end
  end

  @doc """
  Add idempotency headers for safe request retries.

  Some providers support idempotency keys to prevent duplicate operations.
  """
  @spec add_idempotency_headers(list({String.t(), String.t()}), atom(), keyword()) ::
          list({String.t(), String.t()})
  def add_idempotency_headers(headers, provider, opts \\ []) do
    case provider do
      :openai ->
        if idempotency_key = Keyword.get(opts, :idempotency_key) do
          [{"Idempotency-Key", idempotency_key} | headers]
        else
          headers
        end

      :anthropic ->
        if idempotency_key = Keyword.get(opts, :idempotency_key) do
          [{"Idempotency-Key", idempotency_key} | headers]
        else
          headers
        end

      _ ->
        headers
    end
  end

  @doc """
  Add custom headers specified by the user.

  Allows users to add arbitrary headers for specific use cases.
  """
  @spec add_custom_headers(list({String.t(), String.t()}), keyword()) ::
          list({String.t(), String.t()})
  def add_custom_headers(headers, opts) do
    custom_headers = Keyword.get(opts, :custom_headers, [])
    headers ++ custom_headers
  end

  @doc """
  Make a multipart form POST request to upload files.

  ## Parameters
  - `url` - The endpoint URL
  - `form_data` - A keyword list of form fields, where file fields are {:file, path}
  - `headers` - Request headers
  - `opts` - Additional options

  ## Examples

      HTTPClient.post_multipart(
        "https://api.openai.com/v1/files",
        [
          purpose: "fine-tune",
          file: {:file, "/path/to/file.jsonl"}
        ],
        [{"Authorization", "Bearer sk-..."}]
      )
  """
  @spec post_multipart(String.t(), keyword(), list({String.t(), String.t()}), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_multipart(url, form_data, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    provider = Keyword.get(opts, :provider, :unknown)

    # Prepare multipart form
    multipart =
      Enum.map(form_data, fn
        {field, {:file, path}} ->
          # For file fields, read the file and create a file part
          case File.read(path) do
            {:ok, content} ->
              filename = Path.basename(path)
              {to_string(field), {content, [filename: filename]}}

            {:error, reason} ->
              throw({:file_read_error, path, reason})
          end

        {field, value} when is_binary(value) ->
          # Binary data (for upload parts)
          {to_string(field), value}

        {field, value} ->
          # Regular form fields
          {to_string(field), to_string(value)}
      end)

    # Remove Content-Type from headers as Req will set it with boundary
    headers = List.keydelete(headers, "Content-Type", 0)
    headers = prepare_headers(headers)

    # Log request
    Logger.log_request(
      provider,
      url,
      %{multipart: true, fields: Keyword.keys(form_data)},
      headers
    )

    req_opts = [
      headers: headers,
      receive_timeout: timeout,
      form_multipart: multipart
    ]

    start_time = System.monotonic_time(:millisecond)

    result = Req.post(url, req_opts)
    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        # Log successful response
        Logger.log_response(provider, %{status: status, body: response_body}, duration)
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        # Log error response
        Logger.error("API error response",
          provider: provider,
          status: status,
          body: response_body,
          duration_ms: duration
        )

        handle_error_response(status, response_body)

      {:error, reason} ->
        # Log connection error
        Logger.error("Connection error",
          provider: provider,
          error: reason,
          duration_ms: duration
        )

        Error.connection_error(reason)
    end
  catch
    {:file_read_error, path, reason} ->
      Logger.error("File read error: #{inspect(reason)} for path: #{path}")
      {:error, reason}
  end

  @doc false
  def add_cache_metadata(response) when is_map(response) do
    # Add metadata indicating this response came from cache
    case response do
      %{"metadata" => metadata} when is_map(metadata) ->
        # Preserve existing metadata and add from_cache flag
        %{response | "metadata" => Map.put(metadata, :from_cache, true)}

      _ ->
        # Add new metadata map with from_cache flag
        Map.put(response, "metadata", %{from_cache: true})
    end
  end

  def add_cache_metadata(response), do: response
end
