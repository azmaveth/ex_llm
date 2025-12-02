defmodule ExLLM.Testing.TestCacheConfig do
  @moduledoc """
  Configuration for the ExLLM test caching system.

  Test caching is **disabled by default** to prevent interference with unit tests
  that expect specific error conditions (timeouts, API errors, etc.).

  To enable test caching, set the environment variable:
  ```
  export EX_LLM_TEST_CACHE_ENABLED=true
  ```

  Or configure it in your test configuration:
  ```elixir
  config :ex_llm, :test_cache, %{
    enabled: true,
    cache_live_api_tests: true
  }
  ```
  """

  @type fallback_strategy :: :latest_success | :latest_any | :best_match
  @type timestamp_format :: :iso8601 | :unix | :compact
  @type hash_algorithm :: :sha256 | :md5 | :blake2b

  @type config :: %{
          enabled: boolean(),
          auto_detect: boolean(),
          cache_dir: String.t(),
          organization: :by_provider | :by_test_module | :by_tag,
          cache_integration_tests: boolean(),
          cache_oauth2_tests: boolean(),
          cache_live_api_tests: boolean(),
          cache_destructive_operations: boolean(),
          replay_by_default: boolean(),
          save_on_miss: boolean(),
          ttl: non_neg_integer() | :infinity,
          timestamp_format: timestamp_format(),
          fallback_strategy: fallback_strategy(),
          max_entries_per_cache: non_neg_integer(),
          cleanup_older_than: non_neg_integer(),
          compress_older_than: non_neg_integer(),
          deduplicate_content: boolean(),
          content_hash_algorithm: hash_algorithm()
        }

  @defaults %{
    enabled: false,
    auto_detect: false,
    cache_dir: "test/cache",
    organization: :by_provider,
    cache_integration_tests: false,
    cache_oauth2_tests: false,
    cache_live_api_tests: false,
    cache_destructive_operations: false,
    replay_by_default: true,
    save_on_miss: true,
    # 7 days in milliseconds
    ttl: 7 * 24 * 60 * 60 * 1000,
    timestamp_format: :iso8601,
    fallback_strategy: :latest_success,
    max_entries_per_cache: 10,
    # 30 days in milliseconds
    cleanup_older_than: 30 * 24 * 60 * 60 * 1000,
    # 7 days in milliseconds
    compress_older_than: 7 * 24 * 60 * 60 * 1000,
    deduplicate_content: true,
    content_hash_algorithm: :sha256
  }

  @doc """
  Get the complete test cache configuration.

  Configuration is loaded in this priority order:
  1. Environment variables (highest priority)
  2. Application configuration
  3. Default values (lowest priority)
  """
  @spec get_config() :: config()
  def get_config do
    @defaults
    |> merge_app_config()
    |> merge_env_config()
    |> validate_config()
  end

  @doc """
  Check if test caching is enabled for the current environment.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = get_config()

    cond do
      not config.enabled -> false
      not config.auto_detect -> config.enabled
      Application.get_env(:ex_llm, :environment, :prod) == :test -> true
      true -> config.enabled
    end
  end

  @doc """
  Get the cache directory, ensuring it exists.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    dir = get_config().cache_dir
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Get TTL for specific test context.
  """
  @spec get_ttl(test_tags :: [atom()], provider :: atom()) :: non_neg_integer() | :infinity
  def get_ttl(test_tags, provider) do
    base_ttl = get_config().ttl

    # Allow per-provider and per-tag TTL overrides
    env_ttl =
      cond do
        :oauth2 in test_tags ->
          get_env_ttl("OAUTH2")

        provider ->
          get_env_ttl(provider |> to_string() |> String.upcase())

        true ->
          nil
      end

    env_ttl || base_ttl
  end

  @doc """
  Get fallback strategy for specific test context.
  """
  @spec get_fallback_strategy(test_tags :: [atom()]) :: fallback_strategy()
  def get_fallback_strategy(test_tags) do
    base_strategy = get_config().fallback_strategy

    # Allow per-tag strategy overrides
    env_strategy =
      cond do
        :oauth2 in test_tags -> get_env_strategy("OAUTH2")
        :integration in test_tags -> get_env_strategy("INTEGRATION")
        true -> nil
      end

    env_strategy || base_strategy
  end

  # Private functions

  defp merge_app_config(defaults) do
    app_config = Application.get_env(:ex_llm, :test_cache, %{})
    Map.merge(defaults, app_config)
  end

  defp merge_env_config(config) do
    env_config = %{}

    env_config = maybe_put_env_bool(env_config, :enabled, "EX_LLM_TEST_CACHE_ENABLED")
    env_config = maybe_put_env_bool(env_config, :auto_detect, "EX_LLM_TEST_CACHE_AUTO_DETECT")
    env_config = maybe_put_env_string(env_config, :cache_dir, "EX_LLM_TEST_CACHE_DIR")

    env_config =
      maybe_put_env_bool(env_config, :cache_live_api_tests, "EX_LLM_TEST_CACHE_LIVE_API_TESTS")

    env_config =
      maybe_put_env_bool(
        env_config,
        :cache_destructive_operations,
        "EX_LLM_TEST_CACHE_DESTRUCTIVE_OPS"
      )

    env_config =
      maybe_put_env_bool(env_config, :replay_by_default, "EX_LLM_TEST_CACHE_REPLAY_ONLY")

    env_config = maybe_put_env_bool(env_config, :save_on_miss, "EX_LLM_TEST_CACHE_SAVE_ON_MISS")
    env_config = maybe_put_env_ttl(env_config, :ttl, "EX_LLM_TEST_CACHE_TTL")

    env_config =
      maybe_put_env_strategy(
        env_config,
        :fallback_strategy,
        "EX_LLM_TEST_CACHE_FALLBACK_STRATEGY"
      )

    env_config =
      maybe_put_env_int(env_config, :max_entries_per_cache, "EX_LLM_TEST_CACHE_MAX_ENTRIES")

    env_config =
      maybe_put_env_duration(
        env_config,
        :cleanup_older_than,
        "EX_LLM_TEST_CACHE_CLEANUP_OLDER_THAN"
      )

    env_config =
      maybe_put_env_bool(env_config, :deduplicate_content, "EX_LLM_TEST_CACHE_DEDUPLICATE")

    Map.merge(config, env_config)
  end

  defp maybe_put_env_bool(config, key, env_var) do
    case System.get_env(env_var) do
      nil -> config
      "true" -> Map.put(config, key, true)
      "false" -> Map.put(config, key, false)
      _ -> config
    end
  end

  defp maybe_put_env_string(config, key, env_var) do
    case System.get_env(env_var) do
      nil -> config
      value when is_binary(value) and value != "" -> Map.put(config, key, value)
      _ -> config
    end
  end

  defp maybe_put_env_int(config, key, env_var) do
    case System.get_env(env_var) do
      nil ->
        config

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> Map.put(config, key, int)
          _ -> config
        end
    end
  end

  defp maybe_put_env_ttl(config, key, env_var) do
    case System.get_env(env_var) do
      nil ->
        config

      "0" ->
        Map.put(config, key, :infinity)

      "infinity" ->
        Map.put(config, key, :infinity)

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> Map.put(config, key, seconds * 1000)
          _ -> config
        end
    end
  end

  defp maybe_put_env_duration(config, key, env_var) do
    case System.get_env(env_var) do
      nil ->
        config

      value ->
        case parse_duration(value) do
          {:ok, duration} -> Map.put(config, key, duration)
          :error -> config
        end
    end
  end

  defp maybe_put_env_strategy(config, key, env_var) do
    case System.get_env(env_var) do
      nil -> config
      "latest_success" -> Map.put(config, key, :latest_success)
      "latest_any" -> Map.put(config, key, :latest_any)
      "best_match" -> Map.put(config, key, :best_match)
      _ -> config
    end
  end

  defp get_env_ttl(prefix) do
    env_var = "EX_LLM_TEST_CACHE_#{prefix}_TTL"

    case System.get_env(env_var) do
      nil ->
        nil

      "0" ->
        :infinity

      "infinity" ->
        :infinity

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds * 1000
          _ -> nil
        end
    end
  end

  defp get_env_strategy(prefix) do
    env_var = "EX_LLM_TEST_CACHE_#{prefix}_STRATEGY"

    case System.get_env(env_var) do
      "latest_success" -> :latest_success
      "latest_any" -> :latest_any
      "best_match" -> :best_match
      _ -> nil
    end
  end

  defp parse_duration(duration_str) do
    case Regex.run(~r/^(\d+)([smhd])$/, String.downcase(duration_str)) do
      [_, number, unit] ->
        case Integer.parse(number) do
          {num, ""} ->
            multiplier =
              case unit do
                "s" -> 1000
                "m" -> 60 * 1000
                "h" -> 60 * 60 * 1000
                "d" -> 24 * 60 * 60 * 1000
              end

            {:ok, num * multiplier}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp validate_config(config) do
    # Ensure critical paths exist
    if config.enabled and config.cache_dir do
      File.mkdir_p!(config.cache_dir)
    end

    # Validate fallback strategy
    valid_strategies = [:latest_success, :latest_any, :best_match]

    unless config.fallback_strategy in valid_strategies do
      raise ArgumentError,
            "Invalid fallback_strategy: #{config.fallback_strategy}. Must be one of: #{inspect(valid_strategies)}"
    end

    # Validate TTL
    case config.ttl do
      :infinity ->
        :ok

      ttl when is_integer(ttl) and ttl > 0 ->
        :ok

      _ ->
        raise ArgumentError,
              "Invalid TTL: #{config.ttl}. Must be positive integer (milliseconds) or :infinity"
    end

    config
  end
end
