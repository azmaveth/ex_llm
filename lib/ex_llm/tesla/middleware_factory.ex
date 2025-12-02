defmodule ExLLM.Tesla.MiddlewareFactory do
  @moduledoc """
  Factory for creating common Tesla middleware configurations.

  This module provides shared middleware configurations to reduce duplication
  across different Tesla client builders in the ExLLM codebase.
  """

  @doc """
  Creates the standard middleware stack for LLM provider HTTP clients.

  ## Parameters
  - `provider` - The provider atom (e.g., `:openai`, `:anthropic`)
  - `config` - Provider configuration map
  - `opts` - Additional options for customizing the middleware

  ## Options
  - `:is_streaming` - Whether this client is for streaming requests (default: false)
  - `:include_retry` - Whether to include retry middleware (default: true)
  - `:include_circuit_breaker` - Whether to include circuit breaker (default: true)
  - `:include_telemetry` - Whether to include telemetry (default: true)
  - `:include_logger` - Whether to include logger middleware (default: depends on env)
  - `:include_compression` - Whether to include compression (default: depends on config)
  - `:extra_middleware` - Additional middleware to include in the stack

  ## Examples

      # Standard middleware stack
      middleware = ExLLM.Tesla.MiddlewareFactory.build_middleware(:openai, config)

      # Streaming-specific middleware
      middleware = ExLLM.Tesla.MiddlewareFactory.build_middleware(:openai, config, is_streaming: true)

      # Custom middleware stack
      middleware = ExLLM.Tesla.MiddlewareFactory.build_middleware(:anthropic, config,
        include_retry: false,
        extra_middleware: [{MyCustomMiddleware, custom_opts}]
      )
  """
  @spec build_middleware(atom(), map(), keyword()) :: [Tesla.Client.middleware()]
  def build_middleware(provider, config, opts \\ []) do
    middleware_builders = [
      &add_base_url/4,
      &add_headers/4,
      &add_circuit_breaker/4,
      &add_retry/4,
      &add_timeout/4,
      &add_telemetry/4,
      &add_logger/4,
      &add_json/4,
      &add_compression/4,
      &add_extra_middleware/4
    ]

    middleware =
      Enum.reduce(middleware_builders, [], fn builder, acc ->
        builder.(acc, provider, config, opts)
      end)

    # Reverse to get correct order (first middleware should be last in list)
    Enum.reverse(middleware)
  end

  @doc """
  Creates a Tesla client configured for streaming with minimal middleware.

  This is optimized for streaming use cases where we need to avoid response
  buffering and have specific adapter configurations.

  ## Parameters
  - `headers` - HTTP headers for the request
  - `opts` - Options for the streaming configuration

  ## Options
  - `:recv_timeout` - Receive timeout for streaming (default: 60_000)
  - `:stream_to` - Process to stream response to (default: self())
  """
  @spec build_streaming_client([{String.t(), String.t()}], keyword()) :: Tesla.Client.t()
  def build_streaming_client(headers, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, 60_000)
    stream_to = Keyword.get(opts, :stream_to, self())

    middleware = [
      {Tesla.Middleware.Headers, headers},
      # Prevent response buffering for streaming
      {Tesla.Middleware.JSON, decode: false}
    ]

    adapter_opts = [recv_timeout: recv_timeout, stream_to: stream_to]

    Tesla.client(middleware, {Tesla.Adapter.Hackney, adapter_opts})
  end

  # Private middleware builders

  # Adds BaseUrl middleware if a base URL is configured.
  defp add_base_url(middleware, provider, config, _opts) do
    if base_url = get_base_url(provider, config) do
      [{Tesla.Middleware.BaseUrl, base_url} | middleware]
    else
      middleware
    end
  end

  # Adds Headers middleware with provider-specific headers.
  defp add_headers(middleware, provider, config, opts) do
    is_streaming = Keyword.get(opts, :is_streaming, false)
    base_headers = build_headers(provider, config)

    # Add streaming-specific headers if this is a streaming request
    headers =
      if is_streaming do
        [{"accept", "text/event-stream"}, {"cache-control", "no-cache"} | base_headers]
      else
        base_headers
      end

    [{Tesla.Middleware.Headers, headers} | middleware]
  end

  # Adds CircuitBreaker middleware unless disabled or for streaming.
  defp add_circuit_breaker(middleware, provider, config, opts) do
    is_streaming = Keyword.get(opts, :is_streaming, false)

    if Keyword.get(opts, :include_circuit_breaker, true) && !is_streaming do
      circuit_name = "#{provider}_circuit"

      [
        {ExLLM.Tesla.Middleware.CircuitBreaker,
         name: circuit_name, provider: provider, timeout: config[:circuit_breaker_timeout]}
        | middleware
      ]
    else
      middleware
    end
  end

  # Adds Retry middleware unless disabled or for streaming.
  defp add_retry(middleware, _provider, config, opts) do
    is_streaming = Keyword.get(opts, :is_streaming, false)

    if Keyword.get(opts, :include_retry, true) && !is_streaming do
      [
        {Tesla.Middleware.Retry,
         delay: config[:retry_delay] || 1_000,
         max_retries: config[:retry_attempts] || 3,
         max_delay: config[:max_retry_delay] || 30_000,
         should_retry: &should_retry?/1,
         jitter_factor: 0.2}
        | middleware
      ]
    else
      middleware
    end
  end

  # Adds Timeout middleware.
  defp add_timeout(middleware, _provider, config, opts) do
    is_streaming = Keyword.get(opts, :is_streaming, false)

    # Don't add timeout middleware for streaming requests
    # as they use recv_timeout in the adapter instead
    if is_streaming do
      middleware
    else
      [{Tesla.Middleware.Timeout, timeout: config[:timeout] || 60_000} | middleware]
    end
  end

  # Adds Telemetry middleware unless disabled.
  defp add_telemetry(middleware, provider, _config, opts) do
    if Keyword.get(opts, :include_telemetry, true) do
      [
        {ExLLM.Tesla.Middleware.Telemetry, metadata: %{provider: provider}}
        | middleware
      ]
    else
      middleware
    end
  end

  # Adds Logger middleware based on environment or config.
  defp add_logger(middleware, _provider, config, opts) do
    if Keyword.get(opts, :include_logger, should_include_logger?(config)) do
      [Tesla.Middleware.Logger | middleware]
    else
      middleware
    end
  end

  # Adds JSON middleware with special handling for streaming.
  defp add_json(middleware, _provider, _config, opts) do
    is_streaming = Keyword.get(opts, :is_streaming, false)

    if is_streaming do
      [{Tesla.Middleware.JSON, decode: false} | middleware]
    else
      # Use default JSON middleware configuration for non-streaming requests
      # The engine_opts parameter should be passed to the JSON engine (Jason),
      # not directly to Tesla.Middleware.JSON
      [Tesla.Middleware.JSON | middleware]
    end
  end

  # Adds compression middleware if enabled.
  defp add_compression(middleware, provider, config, opts) do
    if Keyword.get(opts, :include_compression, should_include_compression?(provider, config)) do
      [{Tesla.Middleware.CompressRequest, format: :gzip} | middleware]
    else
      middleware
    end
  end

  # Adds any extra middleware from options.
  defp add_extra_middleware(middleware, _provider, _config, opts) do
    case Keyword.get(opts, :extra_middleware) do
      nil -> middleware
      extra when is_list(extra) -> extra ++ middleware
      extra -> [extra | middleware]
    end
  end

  # Private helper functions

  defp get_base_url(:openai, config) do
    config[:base_url] || "https://api.openai.com"
  end

  defp get_base_url(:anthropic, config) do
    config[:base_url] || "https://api.anthropic.com"
  end

  defp get_base_url(:gemini, config) do
    config[:base_url] || "https://generativelanguage.googleapis.com/v1beta"
  end

  defp get_base_url(:groq, config) do
    config[:base_url] || "https://api.groq.com/openai"
  end

  defp get_base_url(:mistral, config) do
    config[:base_url] || "https://api.mistral.ai"
  end

  defp get_base_url(:openrouter, config) do
    base_url = config[:base_url] || "https://openrouter.ai"
    # OpenRouter needs /api prefix for its API endpoints
    "#{base_url}/api"
  end

  defp get_base_url(:perplexity, config) do
    config[:base_url] || "https://api.perplexity.ai"
  end

  defp get_base_url(:xai, config) do
    config[:base_url] || "https://api.x.ai"
  end

  defp get_base_url(:ollama, config) do
    config[:base_url] || config[:ollama_url] || "http://localhost:11434"
  end

  defp get_base_url(:lmstudio, config) do
    config[:base_url] || config[:lmstudio_url] || "http://localhost:1234"
  end

  defp get_base_url(_provider, config) do
    config[:base_url]
  end

  defp build_headers(:openai, config) do
    base_headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]

    # Add optional OpenAI-specific headers
    base_headers
    |> maybe_add_header("openai-organization", config[:organization])
    |> maybe_add_header("openai-project", config[:project])
  end

  defp build_headers(:anthropic, config) do
    [
      {"content-type", "application/json"},
      {"x-api-key", config[:api_key]},
      {"anthropic-version", config[:anthropic_version] || "2023-06-01"}
    ]
  end

  defp build_headers(:gemini, config) do
    # Gemini can use either API key in header or query param
    if config[:api_key] do
      [
        {"content-type", "application/json"},
        {"x-goog-api-key", config[:api_key]}
      ]
    else
      [{"content-type", "application/json"}]
    end
  end

  defp build_headers(:groq, config) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]
  end

  defp build_headers(:mistral, config) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]
  end

  defp build_headers(:openrouter, config) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]

    # OpenRouter specific headers
    headers
    |> maybe_add_header("http-referer", config[:site_url])
    |> maybe_add_header("x-title", config[:app_name])
  end

  defp build_headers(:perplexity, config) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]
  end

  defp build_headers(:xai, config) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]
  end

  defp build_headers(:ollama, _config) do
    [{"content-type", "application/json"}]
  end

  defp build_headers(:lmstudio, _config) do
    [{"content-type", "application/json"}]
  end

  defp build_headers(_provider, config) do
    # Generic headers with optional auth
    headers = [{"content-type", "application/json"}]

    if config[:api_key] do
      headers ++ [{"authorization", "Bearer #{config[:api_key]}"}]
    else
      headers
    end
  end

  defp maybe_add_header(headers, _name, nil), do: headers

  defp maybe_add_header(headers, name, value) do
    headers ++ [{name, value}]
  end

  defp should_retry?({:ok, %{status: status}}) when status in [429, 500, 502, 503, 504] do
    true
  end

  defp should_retry?({:ok, %{status: 401, body: body}}) do
    # Check if this is a rate-limited 401 rather than a genuine auth error
    case check_rate_limit_401(body) do
      true -> true
      false -> false
    end
  end

  defp should_retry?({:error, :timeout}) do
    true
  end

  defp should_retry?({:error, :closed}) do
    true
  end

  defp should_retry?({:error, :econnrefused}) do
    true
  end

  defp should_retry?({:error, _}) do
    # Retry other errors
    true
  end

  defp should_retry?(_) do
    false
  end

  # Check if a 401 response is actually due to rate limiting
  defp check_rate_limit_401(body) when is_binary(body) do
    lower_body = String.downcase(body)

    Enum.any?(
      [
        "rate limit",
        "too many requests",
        "quota exceeded",
        "retry after",
        "throttle"
      ],
      &String.contains?(lower_body, &1)
    )
  end

  defp check_rate_limit_401(%{"error" => error}) when is_map(error) do
    message = error["message"] || error["error"] || ""
    check_rate_limit_401(message)
  end

  defp check_rate_limit_401(%{"error" => message}) when is_binary(message) do
    check_rate_limit_401(message)
  end

  defp check_rate_limit_401(%{"message" => message}) when is_binary(message) do
    check_rate_limit_401(message)
  end

  defp check_rate_limit_401(_), do: false

  defp should_include_logger?(config) do
    env = Application.get_env(:ex_llm, :environment, :prod)
    config[:debug] || env in [:dev, :test]
  end

  defp should_include_compression?(_provider, config) do
    config[:compression] == true
  end
end
