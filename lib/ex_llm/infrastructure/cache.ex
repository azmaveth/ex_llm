defmodule ExLLM.Infrastructure.Cache do
  @moduledoc """
  Production caching implementation for ExLLM using ETS-based storage.

  This module provides the runtime caching infrastructure for LLM responses,
  operating as part of ExLLM's dual-cache architecture. It focuses exclusively
  on production performance optimization, while test-specific caching is handled
  separately through the strategy pattern.

  For a complete understanding of ExLLM's caching architecture, see the
  [Caching Architecture Guide](docs/caching_architecture.md).

  ## Features

  - Fast ETS-based in-memory caching with sub-millisecond access
  - Configurable TTL with automatic expiration
  - Optional disk persistence for cache warming
  - Cache statistics and monitoring via telemetry
  - Thread-safe concurrent access

  ## Architecture Role

  This module serves as the production cache implementation within ExLLM's
  strategy pattern. It no longer directly handles test caching concerns, which
  are now properly isolated in the test strategy implementation.

  ```
  User Request → Pipeline → Cache Strategy → Production Cache (this module)
  ```

  ## Usage

      # Runtime caching only (default)
      {:ok, response} = ExLLM.chat(:anthropic, messages, cache: true)
      
      # With custom TTL
      {:ok, response} = ExLLM.chat(:anthropic, messages, 
        cache: true,
        cache_ttl: :timer.minutes(30)
      )
      
      # Skip cache for this request
      {:ok, response} = ExLLM.chat(:anthropic, messages, cache: false)

  ## Configuration

      config :ex_llm, :cache,
        enabled: true,
        storage: {ExLLM.Infrastructure.Cache.Storage.ETS, []},
        default_ttl: :timer.minutes(15),
        cleanup_interval: :timer.minutes(5),
        persist_disk: false,
        disk_path: "/tmp/ex_llm_cache"

  ## Cache Strategy Configuration

  The caching behavior is controlled by the configured strategy:

      # Production (default)
      config :ex_llm,
        cache_strategy: ExLLM.Cache.Strategies.Production

      # Testing
      config :ex_llm,
        cache_strategy: ExLLM.Cache.Strategies.Test

  ## Telemetry Events

  This module emits the following telemetry events:

  - `[:ex_llm, :cache, :hit]` - Cache hit with key
  - `[:ex_llm, :cache, :miss]` - Cache miss with key  
  - `[:ex_llm, :cache, :put]` - Item stored with size in bytes
  - `[:ex_llm, :cache, :evict]` - Item evicted from cache

  ## Disk Persistence

  Enable disk persistence to automatically save cached responses:

      # Environment variable
      export EX_LLM_CACHE_PERSIST=true
      export EX_LLM_CACHE_DIR="/path/to/cache"  # Optional
      
      # Or application config
      config :ex_llm,
        cache_persist_disk: true,
        cache_disk_path: "/tmp/ex_llm_cache"

  When enabled, cached responses are written to disk for cache warming or
  mock adapter usage. This is separate from test caching.
  """

  use GenServer
  alias ExLLM.Infrastructure.Logger

  # alias ExLLM.Infrastructure.Cache.Storage

  @default_ttl :timer.minutes(15)
  @cleanup_interval :timer.minutes(5)
  @default_storage {ExLLM.Infrastructure.Cache.Storage.ETS, []}

  defmodule Stats do
    @moduledoc """
    Cache statistics.
    """
    defstruct hits: 0, misses: 0, evictions: 0, errors: 0

    @type t :: %__MODULE__{
            hits: non_neg_integer(),
            misses: non_neg_integer(),
            evictions: non_neg_integer(),
            errors: non_neg_integer()
          }
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :storage_mod,
      :storage_state,
      :stats,
      :cleanup_interval,
      :default_ttl,
      :persist_disk,
      :disk_path
    ]
  end

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached response if available and not expired.
  """
  @spec get(String.t()) :: {:ok, any()} | :miss
  def get(key) do
    result = GenServer.call(__MODULE__, {:get, key})

    # Log cache access and emit telemetry
    case result do
      {:ok, _} ->
        Logger.log_cache_event(:hit, key)
        ExLLM.Infrastructure.Telemetry.emit_cache_hit(key)

      :miss ->
        Logger.log_cache_event(:miss, key)
        ExLLM.Infrastructure.Telemetry.emit_cache_miss(key)
    end

    result
  catch
    :exit, _ ->
      Logger.log_cache_event(:error, key, %{reason: :genserver_not_running})
      :miss
  end

  @doc """
  Store a response in the cache with TTL.
  """
  @spec put(String.t(), any(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    # Log cache write
    Logger.log_cache_event(:put, key, %{
      ttl: Keyword.get(opts, :ttl, @default_ttl)
    })

    # Emit telemetry for cache put
    size_bytes = :erlang.external_size(value)
    ExLLM.Infrastructure.Telemetry.emit_cache_put(key, size_bytes)

    GenServer.cast(__MODULE__, {:put, key, value, opts})
  catch
    :exit, _ ->
      Logger.log_cache_event(:error, key, %{reason: :genserver_not_running})
      :ok
  end

  @doc """
  Delete a specific cache entry.
  """
  @spec delete(String.t()) :: :ok
  def delete(key) do
    GenServer.cast(__MODULE__, {:delete, key})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Clear all cache entries.
  """
  @spec clear() :: :ok
  def clear do
    Logger.log_cache_event(:clear, "all")
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: Stats.t()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %Stats{}
  end

  @doc """
  Update disk persistence configuration at runtime.
  """
  @spec configure_disk_persistence(boolean(), String.t() | nil) :: :ok
  def configure_disk_persistence(enabled, disk_path \\ nil) do
    GenServer.call(__MODULE__, {:configure_disk_persistence, enabled, disk_path})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Generate a cache key for a chat request.

  The key is based on:
  - Provider
  - Model
  - Messages content
  - Relevant options (temperature, max_tokens, etc.)
  """
  @spec generate_cache_key(atom(), list(map()), keyword()) :: String.t()
  def generate_cache_key(provider, messages, options) do
    # Extract cache-relevant options
    relevant_opts =
      options
      |> Keyword.take([
        :model,
        :temperature,
        :max_tokens,
        :top_p,
        :top_k,
        :frequency_penalty,
        :presence_penalty,
        :stop_sequences,
        :system
      ])
      |> Enum.sort()

    # Create cache key components
    key_data = %{
      provider: provider,
      messages: normalize_messages(messages),
      options: relevant_opts
    }

    # Generate deterministic hash
    :crypto.hash(:sha256, :erlang.term_to_binary(key_data))
    |> Base.encode64(padding: false)
  end

  @doc """
  Check if caching should be used for this request.

  Returns false for:
  - Streaming requests
  - Requests with functions/tools
  - Explicitly disabled caching
  """
  @spec should_cache?(keyword()) :: boolean()
  def should_cache?(options) do
    cond do
      # Explicitly disabled
      Keyword.get(options, :cache) == false -> false
      # Streaming not cacheable
      Keyword.has_key?(options, :stream) -> false
      # Function calling might have side effects
      Keyword.has_key?(options, :functions) -> false
      Keyword.has_key?(options, :tools) -> false
      # Instructor/structured output with validation
      Keyword.has_key?(options, :response_model) -> false
      # Default to enabled if cache option is present
      Keyword.has_key?(options, :cache) -> true
      # Or if global caching is enabled
      true -> Application.get_env(:ex_llm, :cache_enabled, false)
    end
  end

  @doc """
  Wrap a cache-aware function execution.

  This is the main integration point for ExLLM modules. It uses a configured
  strategy to handle caching.
  """
  @spec with_cache(String.t(), keyword(), fun()) :: any()
  def with_cache(cache_key, opts, fun) do
    strategy = Application.get_env(:ex_llm, :cache_strategy, ExLLM.Cache.Strategies.Production)
    strategy.with_cache(cache_key, opts, fun)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Get configuration
    config = Application.get_env(:ex_llm, :cache, [])

    # Get disk persistence config from environment or config
    persist_disk =
      System.get_env("EX_LLM_CACHE_PERSIST") == "true" or
        Application.get_env(:ex_llm, :cache_persist_disk, false)

    disk_path =
      System.get_env("EX_LLM_CACHE_DIR") ||
        Application.get_env(:ex_llm, :cache_disk_path, "/tmp/ex_llm_cache")

    # Merge options
    opts =
      Keyword.merge(
        [
          storage: @default_storage,
          default_ttl: @default_ttl,
          cleanup_interval: @cleanup_interval,
          persist_disk: persist_disk,
          disk_path: disk_path
        ],
        Keyword.merge(config, opts)
      )

    # Initialize storage backend
    {storage_mod, storage_opts} = Keyword.get(opts, :storage)

    case storage_mod.init(storage_opts) do
      {:ok, storage_state} ->
        # Schedule periodic cleanup
        schedule_cleanup(Keyword.get(opts, :cleanup_interval))

        state = %State{
          storage_mod: storage_mod,
          storage_state: storage_state,
          stats: %Stats{},
          cleanup_interval: Keyword.get(opts, :cleanup_interval),
          default_ttl: Keyword.get(opts, :default_ttl),
          persist_disk: Keyword.get(opts, :persist_disk),
          disk_path: Keyword.get(opts, :disk_path)
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:storage_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {result, new_state} = do_get(key, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    case state.storage_mod.clear(state.storage_state) do
      {:ok, new_storage_state} ->
        new_state = %{state | storage_state: new_storage_state, stats: %Stats{}}
        {:reply, :ok, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call({:configure_disk_persistence, enabled, disk_path}, _from, state) do
    new_disk_path = disk_path || state.disk_path
    new_state = %{state | persist_disk: enabled, disk_path: new_disk_path}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:put, key, value, opts}, state) do
    ttl = Keyword.get(opts, :ttl, state.default_ttl)
    expires_at = System.system_time(:millisecond) + ttl

    case state.storage_mod.put(key, value, expires_at, state.storage_state) do
      {:ok, new_storage_state} ->
        # Optionally persist to disk for testing/development
        if state.persist_disk do
          persist_to_disk_async(key, value, opts, state)
        end

        {:noreply, %{state | storage_state: new_storage_state}}

      _ ->
        # Log error but don't crash
        Logger.error("ExLLM.Cache: Failed to store key #{key}")
        new_stats = %{state.stats | errors: state.stats.errors + 1}
        {:noreply, %{state | stats: new_stats}}
    end
  end

  @impl true
  def handle_cast({:delete, key}, state) do
    case state.storage_mod.delete(key, state.storage_state) do
      {:ok, new_storage_state} ->
        {:noreply, %{state | storage_state: new_storage_state}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Storage backends handle their own expiration
    # This is mainly for collecting stats or maintenance

    # For ETS backend, we can check expired entries
    if state.storage_mod == ExLLM.Infrastructure.Cache.Storage.ETS do
      # Get storage info
      case state.storage_mod.info(state.storage_state) do
        {:ok, info, _} ->
          Logger.debug("ExLLM.Cache: Storage size: #{info.size} entries")

        _ ->
          :ok
      end
    end

    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  ## Private Functions

  defp persist_to_disk_async(cache_key, cached_response, opts, state) do
    # Extract metadata for disk storage
    provider = Keyword.get(opts, :provider)
    endpoint = determine_endpoint_from_opts(opts)
    request_metadata = extract_request_metadata(opts)

    # Use Task.start to avoid blocking ETS operations
    Task.start(fn ->
      try do
        ExLLM.Testing.MockResponseRecorder.store_from_cache(
          cache_key,
          cached_response,
          provider,
          endpoint,
          request_metadata,
          state.disk_path
        )
      rescue
        error ->
          Logger.error("Failed to persist cache to disk: #{inspect(error)}")
      end
    end)
  end

  defp determine_endpoint_from_opts(opts) do
    cond do
      Keyword.get(opts, :stream) == true -> "streaming"
      Keyword.has_key?(opts, :functions) or Keyword.has_key?(opts, :tools) -> "chat"
      true -> "chat"
    end
  end

  defp extract_request_metadata(opts) do
    %{
      model: Keyword.get(opts, :model),
      temperature: Keyword.get(opts, :temperature),
      max_tokens: Keyword.get(opts, :max_tokens),
      top_p: Keyword.get(opts, :top_p),
      cached_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp do_get(key, state) do
    case state.storage_mod.get(key, state.storage_state) do
      {:ok, value, new_storage_state} ->
        new_stats = %{state.stats | hits: state.stats.hits + 1}
        new_state = %{state | storage_state: new_storage_state, stats: new_stats}
        {{:ok, value}, new_state}

      {:miss, new_storage_state} ->
        new_stats = %{state.stats | misses: state.stats.misses + 1}
        new_state = %{state | storage_state: new_storage_state, stats: new_stats}
        {:miss, new_state}
    end
  end

  defp normalize_messages(messages) do
    # Normalize messages to ensure consistent cache keys
    Enum.map(messages, fn msg ->
      %{
        role: Map.get(msg, :role) || Map.get(msg, "role"),
        content: Map.get(msg, :content) || Map.get(msg, "content")
      }
    end)
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end
