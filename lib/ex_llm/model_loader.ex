defmodule ExLLM.ModelLoader do
  @moduledoc """
  Dynamic model loader for ExLLM adapters.
  
  Provides functionality to:
  1. Fetch models from provider APIs where available
  2. Fall back to YAML configuration files
  3. Cache results to avoid repeated API calls
  """
  
  require Logger
  alias ExLLM.{Types, ModelConfig}
  
  @cache_ttl_seconds 3600  # 1 hour cache
  @cache_table :ex_llm_model_cache
  
  @doc """
  Loads models for a provider, attempting API first then falling back to config.
  
  ## Options
  - `:force_refresh` - Skip cache and fetch fresh data
  - `:api_fetcher` - Function to fetch from API: fn(options) -> {:ok, models} | {:error, reason}
  - `:config_transformer` - Function to transform config data to Types.Model structs
  """
  def load_models(provider, options \\ []) do
    force_refresh = Keyword.get(options, :force_refresh, false)
    
    # Initialize cache table if needed
    ensure_cache_table()
    
    # Check cache first unless force refresh
    unless force_refresh do
      case get_from_cache(provider) do
        {:ok, models} -> 
          {:ok, models}
        :miss ->
          fetch_and_cache_models(provider, options)
      end
    else
      fetch_and_cache_models(provider, options)
    end
  end
  
  @doc """
  Clears the model cache for a specific provider or all providers.
  """
  def clear_cache(provider \\ :all) do
    ensure_cache_table()
    
    if provider == :all do
      :ets.delete_all_objects(@cache_table)
    else
      :ets.delete(@cache_table, {provider, :models})
    end
    
    :ok
  end
  
  # Private functions
  
  defp ensure_cache_table do
    case :ets.info(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:set, :public, :named_table])
      _ ->
        :ok
    end
  end
  
  defp get_from_cache(provider) do
    case :ets.lookup(@cache_table, {provider, :models}) do
      [{_, {models, timestamp}}] ->
        if :os.system_time(:second) - timestamp < @cache_ttl_seconds do
          {:ok, models}
        else
          # Cache expired
          :ets.delete(@cache_table, {provider, :models})
          :miss
        end
      [] ->
        :miss
    end
  end
  
  defp fetch_and_cache_models(provider, options) do
    api_fetcher = Keyword.get(options, :api_fetcher)
    config_transformer = Keyword.get(options, :config_transformer, &default_config_transformer/2)
    
    models = 
      if api_fetcher do
        # Try API first
        case api_fetcher.(options) do
          {:ok, api_models} ->
            Logger.debug("Loaded #{length(api_models)} models from #{provider} API")
            api_models
            
          {:error, reason} ->
            Logger.debug("Failed to fetch models from #{provider} API: #{inspect(reason)}, falling back to config")
            load_from_config(provider, config_transformer)
        end
      else
        # No API fetcher provided, use config only
        load_from_config(provider, config_transformer)
      end
    
    # Cache the results
    :ets.insert(@cache_table, {{provider, :models}, {models, :os.system_time(:second)}})
    
    {:ok, models}
  end
  
  defp load_from_config(provider, transformer) do
    models_config = ModelConfig.get_all_models(provider)
    
    models_config
    |> Enum.map(fn {model_id, config} ->
      transformer.(model_id, config)
    end)
    |> Enum.sort_by(& &1.id)
  end
  
  defp default_config_transformer(model_id, config) do
    %Types.Model{
      id: to_string(model_id),
      name: Map.get(config, :name, to_string(model_id)),
      description: Map.get(config, :description),
      context_window: Map.get(config, :context_window, 4096),
      capabilities: %{
        supports_streaming: :streaming in Map.get(config, :capabilities, []),
        supports_functions: :function_calling in Map.get(config, :capabilities, []),
        supports_vision: :vision in Map.get(config, :capabilities, []),
        features: Map.get(config, :capabilities, [])
      }
    }
  end
end