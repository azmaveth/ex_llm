defmodule ExLLM.TestCacheDetector do
  @moduledoc """
  Intelligent detection of test scenarios requiring automatic caching.

  This module provides runtime detection of integration tests, OAuth2 tests,
  and other scenarios that should trigger automatic response caching.
  """

  @type test_context :: %{
          module: atom(),
          test_name: String.t(),
          tags: [atom()],
          pid: pid()
        }

  @doc """
  Check if an integration test is currently running.
  """
  @spec integration_test_running?() :: boolean()
  def integration_test_running? do
    case get_current_test_context() do
      {:ok, context} -> :integration in context.tags
      :error -> false
    end
  end

  @doc """
  Check if an OAuth2 test is currently running.
  """
  @spec oauth2_test_running?() :: boolean()
  def oauth2_test_running? do
    case get_current_test_context() do
      {:ok, context} ->
        :oauth2 in context.tags or
          String.contains?(to_string(context.module), "OAuth2") or
          String.contains?(context.test_name, "oauth2")

      :error ->
        false
    end
  end

  @doc """
  Check if a live API test is currently running.
  """
  @spec live_api_test_running?() :: boolean()
  def live_api_test_running? do
    case get_current_test_context() do
      {:ok, context} -> :live_api in context.tags
      :error -> false
    end
  end

  @doc """
  Check if the current test involves destructive operations that shouldn't be cached.
  """
  @spec is_destructive_operation?() :: boolean()
  def is_destructive_operation? do
    case get_current_test_context() do
      {:ok, context} ->
        cond do
          # Check test tags
          :no_cache in context.tags -> true
          :destructive in context.tags -> true
          :delete in context.tags -> true
          :create in context.tags -> true
          :modify in context.tags -> true
          # Check test name patterns
          is_destructive_test_name?(context.test_name) -> true
          # Check module patterns
          String.contains?(to_string(context.module), "Destructive") -> true
          true -> false
        end

      :error ->
        false
    end
  end

  @doc """
  Check if test response caching should be enabled based on current context.
  """
  @spec should_cache_responses?() :: boolean()
  def should_cache_responses? do
    config = ExLLM.TestCacheConfig.get_config()

    cond do
      not config.enabled -> false
      not config.auto_detect -> config.enabled
      Mix.env() != :test -> false
      is_destructive_operation?() and not config.cache_destructive_operations -> false
      true -> should_cache_current_test?(config)
    end
  end

  @doc """
  Get the current test context if available.
  """
  @spec get_current_test_context() :: {:ok, test_context()} | :error
  def get_current_test_context do
    case get_exunit_context() do
      {:ok, context} -> {:ok, context}
      :error -> get_process_context()
    end
  end

  @doc """
  Store test context in the current process for later retrieval.
  """
  @spec set_test_context(test_context()) :: :ok
  def set_test_context(context) do
    Process.put(:ex_llm_test_context, context)
    :ok
  end

  @doc """
  Clear test context from the current process.
  """
  @spec clear_test_context() :: :ok
  def clear_test_context do
    Process.delete(:ex_llm_test_context)
    :ok
  end

  @doc """
  Generate a cache key based on the current test context.
  """
  @spec generate_cache_key(provider :: atom(), endpoint :: String.t()) :: String.t()
  def generate_cache_key(provider, endpoint) do
    case get_current_test_context() do
      {:ok, context} ->
        config = ExLLM.TestCacheConfig.get_config()
        build_cache_key(provider, endpoint, context, config.organization)

      :error ->
        # Fallback when no test context available
        "#{provider}/#{sanitize_endpoint(endpoint)}"
    end
  end

  # Private functions

  defp should_cache_current_test?(config) do
    case get_current_test_context() do
      {:ok, context} ->
        cond do
          # Primary detection: :live_api tag
          :live_api in context.tags and config.cache_live_api_tests ->
            true

          # Legacy support: :integration tag
          :integration in context.tags and config.cache_integration_tests ->
            true

          # OAuth2 tests
          :oauth2 in context.tags and config.cache_oauth2_tests ->
            true

          # Module name-based detection (legacy)
          String.contains?(to_string(context.module), "Integration") and
              config.cache_integration_tests ->
            true

          String.contains?(to_string(context.module), "OAuth2") and config.cache_oauth2_tests ->
            true

          true ->
            false
        end

      :error ->
        false
    end
  end

  defp get_exunit_context do
    # For now, we rely on explicit context setting
    # This could be enhanced to automatically detect ExUnit context
    :error
  end

  defp get_process_context do
    case Process.get(:ex_llm_test_context) do
      nil -> :error
      context when is_map(context) -> {:ok, context}
      _ -> :error
    end
  end

  defp build_cache_key(provider, endpoint, context, organization) do
    base_key =
      case organization do
        :by_provider ->
          "#{provider}/#{sanitize_endpoint(endpoint)}"

        :by_test_module ->
          module_name = context.module |> to_string() |> String.split(".") |> List.last()
          "#{module_name}/#{provider}/#{sanitize_endpoint(endpoint)}"

        :by_tag ->
          tag =
            cond do
              :oauth2 in context.tags -> "oauth2"
              :integration in context.tags -> "integration"
              true -> "unit"
            end

          "#{tag}/#{provider}/#{sanitize_endpoint(endpoint)}"
      end

    # Ensure key is filesystem-safe
    base_key
    |> String.replace(~r/[^a-zA-Z0-9\/_-]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp sanitize_endpoint(endpoint) do
    endpoint
    |> String.trim_leading("/")
    |> String.replace("/", "_")
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  # Helper to detect destructive test names
  defp is_destructive_test_name?(test_name) do
    destructive_patterns = [
      ~r/delete/i,
      ~r/remove/i,
      ~r/destroy/i,
      ~r/create.*corpus/i,
      ~r/upload.*file/i,
      ~r/batch.*delete/i,
      ~r/purge/i,
      ~r/clear/i,
      ~r/wipe/i,
      ~r/reset/i
    ]

    Enum.any?(destructive_patterns, &Regex.match?(&1, test_name))
  end
end
