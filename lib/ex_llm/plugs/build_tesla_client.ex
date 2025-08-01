defmodule ExLLM.Plugs.BuildTeslaClient do
  @moduledoc """
  Builds a Tesla HTTP client configured for the specific provider.

  This plug creates a Tesla client with the appropriate middleware stack
  for making API calls to the LLM provider. The client is stored in
  `request.tesla_client` for use by subsequent plugs.

  ## Provider-Specific Configuration

  Each provider gets a customized Tesla client with:
  - Base URL for the provider's API
  - Authentication headers
  - Retry logic
  - Timeout settings
  - Circuit breaker integration
  - Telemetry and logging

  ## Caching

  This plug uses the Tesla ClientCache to avoid reconstructing middleware
  on every request. Clients are cached based on provider and configuration
  that affects the middleware stack.

  ## Examples

      plug ExLLM.Plugs.BuildTeslaClient
      
  After this plug runs, `request.tesla_client` will contain a configured
  Tesla client ready to make API calls.
  """

  use ExLLM.Plug
  alias ExLLM.Tesla.{MiddlewareFactory, ClientCache}
  require Logger

  @impl true
  def call(%Request{provider: provider, config: config, options: options} = request, _opts) do
    # Check if this is a streaming request
    # Check in both config and options for stream flags
    is_streaming =
      config[:stream] == true ||
        config[:streaming] == true ||
        options[:stream] == true ||
        options[:streaming] == true ||
        is_function(config[:stream_callback], 1) ||
        is_function(options[:stream_callback], 1)

    Logger.debug(
      "BuildTeslaClient: provider=#{provider}, is_streaming=#{is_streaming}, config.stream=#{config[:stream]}, options.stream=#{options[:stream]}, has_callback=#{is_function(config[:stream_callback], 1) || is_function(options[:stream_callback], 1)}"
    )

    # Include streaming flag in config for cache key
    cache_config = Map.put(config, :is_streaming, is_streaming)

    # Use cache to get or create client
    client =
      ClientCache.get_or_create(provider, cache_config, fn ->
        build_client(provider, config, is_streaming)
      end)

    %{request | tesla_client: client}
  end

  defp build_client(provider, config, is_streaming) do
    # Use the middleware factory to build the middleware stack
    middleware = MiddlewareFactory.build_middleware(provider, config, is_streaming: is_streaming)

    # Get configurable timeout from config, with defaults based on streaming
    timeout = config[:timeout] || if is_streaming, do: 300_000, else: 60_000

    # Configure adapter based on whether this is a streaming request
    adapter_opts =
      if is_streaming do
        # For streaming, use the configurable timeout
        [recv_timeout: timeout]
      else
        [recv_timeout: timeout]
      end

    # Use Tesla.Mock only in certain test scenarios
    # Otherwise use Hackney for Bypass-based tests
    adapter =
      if Application.get_env(:ex_llm, :use_tesla_mock, false) do
        Tesla.Mock
      else
        # Tesla.client expects the adapter in a specific format
        # Using Tesla.Adapter.Hackney directly instead of tuple format
        Tesla.Adapter.Hackney
      end

    Tesla.client(middleware, {adapter, adapter_opts})
  end
end
