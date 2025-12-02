defmodule ExLLM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure telemetry is started first - check if already started
    case Application.ensure_all_started(:telemetry) do
      {:ok, _apps} ->
        :ok

      {:error, _} ->
        # Telemetry might not be available, continue anyway
        :ok
    end

    # Run startup configuration validation
    ExLLM.Infrastructure.StartupValidator.run_startup_validation()

    # Initialize circuit breaker ETS table
    ExLLM.Infrastructure.CircuitBreaker.init()

    # Delay metrics setup to avoid telemetry warnings
    spawn(fn ->
      Process.sleep(100)
      ExLLM.Infrastructure.CircuitBreaker.Metrics.setup()
    end)

    children =
      [
        # Start StreamRecovery for all adapters
        ExLLM.Core.Streaming.Recovery,
        # Start StreamingEngine with stream tracking
        ExLLM.Providers.Shared.StreamingEngine,
        # Start Tesla Client Cache
        ExLLM.Tesla.ClientCache,
        # Start Cache if enabled
        cache_child_spec(),
        # Start Circuit Breaker Configuration Manager
        ExLLM.Infrastructure.CircuitBreaker.ConfigManager,
        # Start Circuit Breaker Metrics system if enabled
        metrics_child_spec(),
        # Start Ollama Model Registry
        ExLLM.Infrastructure.OllamaModelRegistry
      ]
      |> Enum.filter(& &1)

    # Only start ModelLoader if Bumblebee is available and not in unit test env
    # Check if we're in test mode by looking for ExUnit
    in_test = Code.ensure_loaded?(ExUnit)
    # Allow ModelLoader in integration tests
    force_start_modelloader = System.get_env("EX_LLM_START_MODELLOADER") == "true"

    children =
      if Code.ensure_loaded?(Bumblebee) and (not in_test or force_start_modelloader) do
        children ++ [ExLLM.Providers.Bumblebee.ModelLoader]
      else
        children
      end

    opts = [strategy: :one_for_one, name: ExLLM.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp cache_child_spec do
    if Application.get_env(:ex_llm, :cache_enabled, false) do
      ExLLM.Infrastructure.Cache
    else
      nil
    end
  end

  defp metrics_child_spec do
    config = Application.get_env(:ex_llm, :circuit_breaker_metrics, [])

    if Keyword.get(config, :enabled, false) and :statsd in Keyword.get(config, :backends, []) do
      ExLLM.Infrastructure.CircuitBreaker.Metrics.StatsDReporter
    else
      nil
    end
  end
end
