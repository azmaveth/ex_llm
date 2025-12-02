defmodule ExLLM.Providers.Bumblebee.ModelLoader do
  @moduledoc """
  Handles loading and caching of Bumblebee models for local inference.

  This GenServer manages the lifecycle of loaded models, ensuring efficient
  memory usage and providing fast access to cached models.

  ## Features

  - Automatic model downloading from HuggingFace
  - Model caching to avoid reloading
  - Memory management with model unloading
  - Hardware acceleration detection
  - Support for local model paths
  """

  use GenServer
  alias ExLLM.Infrastructure.Logger
  alias ExLLM.Providers.Bumblebee.EXLAConfig

  @model_cache_dir Application.compile_env(
                     :ex_lmm,
                     :model_cache_path,
                     Path.expand("~/.ex_llm/models")
                   )

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load a model by name or path. Returns {:ok, model_info} or {:error, reason}.

  ## Examples

      {:ok, model} = ModelLoader.load_model("HuggingFaceTB/SmolLM2-1.7B-Instruct")
      {:ok, model} = ModelLoader.load_model("/path/to/local/model")
  """
  def load_model(model_identifier) do
    GenServer.call(__MODULE__, {:load_model, model_identifier}, :infinity)
  end

  @doc """
  Get information about a loaded model.
  """
  def get_model_info(model_identifier) do
    GenServer.call(__MODULE__, {:get_model_info, model_identifier})
  end

  @doc """
  List all loaded models.
  """
  def list_loaded_models() do
    GenServer.call(__MODULE__, :list_loaded_models)
  end

  @doc """
  Unload a model from memory.
  """
  def unload_model(model_identifier) do
    GenServer.call(__MODULE__, {:unload_model, model_identifier})
  end

  @doc """
  Get information about hardware acceleration.
  """
  def get_acceleration_info() do
    GenServer.call(__MODULE__, :get_acceleration_info)
  end

  # Server callbacks

  def init(_opts) do
    # Ensure model cache directory exists
    File.mkdir_p!(@model_cache_dir)

    # Configure EXLA backend for optimal performance
    EXLAConfig.configure_backend()
    EXLAConfig.enable_mixed_precision()
    EXLAConfig.optimize_memory()

    # Log acceleration info
    acc_info = EXLAConfig.acceleration_info()
    Logger.info("Model loader initialized with #{acc_info.name} acceleration")

    state = %{
      models: %{},
      loading: MapSet.new(),
      acceleration: acc_info
    }

    {:ok, state}
  end

  def handle_call({:load_model, model_identifier}, _from, state) do
    cond do
      Map.has_key?(state.models, model_identifier) ->
        {:reply, {:ok, state.models[model_identifier]}, state}

      MapSet.member?(state.loading, model_identifier) ->
        {:reply, {:error, :already_loading}, state}

      true ->
        state = %{state | loading: MapSet.put(state.loading, model_identifier)}

        case do_load_model(model_identifier) do
          {:ok, model_info} ->
            state = %{
              state
              | models: Map.put(state.models, model_identifier, model_info),
                loading: MapSet.delete(state.loading, model_identifier)
            }

            {:reply, {:ok, model_info}, state}

          {:error, _reason} = error ->
            state = %{state | loading: MapSet.delete(state.loading, model_identifier)}
            {:reply, error, state}
        end
    end
  end

  def handle_call({:get_model_info, model_identifier}, _from, state) do
    case Map.get(state.models, model_identifier) do
      nil -> {:reply, {:error, :not_loaded}, state}
      info -> {:reply, {:ok, info}, state}
    end
  end

  def handle_call(:list_loaded_models, _from, state) do
    models = Map.keys(state.models)
    {:reply, models, state}
  end

  def handle_call({:unload_model, model_identifier}, _from, state) do
    if Map.has_key?(state.models, model_identifier) do
      state = %{state | models: Map.delete(state.models, model_identifier)}
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_loaded}, state}
    end
  end

  def handle_call(:get_acceleration_info, _from, state) do
    {:reply, state.acceleration, state}
  end

  # Private functions

  defp do_load_model(model_identifier) do
    if Code.ensure_loaded?(Bumblebee) do
      Logger.info("Loading model: #{model_identifier}")

      # Check if this is an MLX model
      if is_mlx_model?(model_identifier) do
        load_mlx_model(model_identifier)
      else
        load_standard_model(model_identifier)
      end
    else
      {:error, "Bumblebee is not available"}
    end
  end

  defp is_mlx_model?(model_identifier) do
    String.contains?(model_identifier, "-mlx") or
      String.contains?(model_identifier, "mlx-") or
      String.contains?(model_identifier, "flux")
  end

  defp load_mlx_model(model_identifier) do
    Logger.info("Detected MLX model: #{model_identifier}")

    # MLX models aren't directly supported by Bumblebee
    # Return a helpful error with guidance
    {:error,
     """
     MLX models like '#{model_identifier}' are not directly supported by Bumblebee.

     MLX models are optimized for Apple's MLX framework and use different formats.

     Suggestions:
     1. Try the non-MLX version: Look for the same model without '-mlx' suffix
     2. Use a different Qwen model: 'Qwen/Qwen2.5-3B-Instruct' or 'Qwen/Qwen2.5-7B-Instruct'
     3. Keep the MLX model listed for discovery but use standard models for inference

     Your MLX models are still valuable for use with other MLX-compatible tools.
     """}
  end

  defp load_standard_model(model_identifier) do
    try do
      # Determine if this is a HuggingFace model or local path
      {repository_id, opts} = parse_model_identifier(model_identifier)

      # Load the model with Bumblebee
      with {:ok, model_info} <- load_bumblebee_model(repository_id, opts),
           {:ok, tokenizer} <- load_bumblebee_tokenizer(repository_id, opts),
           {:ok, generation_config} <- load_bumblebee_generation_config(repository_id, opts) do
        # Create serving for text generation with optimized settings
        serving_opts = EXLAConfig.serving_options()

        serving =
          create_text_generation_serving(
            model_info,
            tokenizer,
            generation_config,
            Keyword.merge(serving_opts, stream: true)
          )

        model_data = %{
          model_info: model_info,
          tokenizer: tokenizer,
          generation_config: generation_config,
          serving: serving,
          repository_id: repository_id,
          loaded_at: DateTime.utc_now()
        }

        Logger.info("Successfully loaded model: #{model_identifier}")
        {:ok, model_data}
      else
        {:error, reason} ->
          Logger.error("Failed to load model #{model_identifier}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Exception loading model #{model_identifier}: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end

  defp parse_model_identifier(identifier) do
    cond do
      # Local file path
      String.starts_with?(identifier, "/") or String.starts_with?(identifier, "~/") ->
        path = Path.expand(identifier)
        {path, []}

      # HuggingFace model ID
      String.contains?(identifier, "/") ->
        {identifier, []}

      # Shorthand for common models
      true ->
        case identifier do
          "llama2" -> {"meta-llama/Llama-2-7b-hf", []}
          "mistral" -> {"mistralai/Mistral-7B-v0.1", []}
          "phi" -> {"microsoft/phi-2", []}
          _ -> {identifier, []}
        end
    end
  end

  # Conditional compilation wrappers for Bumblebee functions

  defp load_bumblebee_model(repository_id, opts) do
    if Code.ensure_loaded?(Bumblebee) do
      # Convert to Bumblebee's expected format
      repo =
        if String.starts_with?(repository_id, "/") do
          {:local, repository_id}
        else
          {:hf, repository_id}
        end

      apply(Bumblebee, :load_model, [repo, opts])
    else
      {:error, "Bumblebee not available"}
    end
  end

  defp load_bumblebee_tokenizer(repository_id, opts) do
    if Code.ensure_loaded?(Bumblebee) do
      # Convert to Bumblebee's expected format
      repo =
        if String.starts_with?(repository_id, "/") do
          {:local, repository_id}
        else
          {:hf, repository_id}
        end

      apply(Bumblebee, :load_tokenizer, [repo, opts])
    else
      {:error, "Bumblebee not available"}
    end
  end

  defp load_bumblebee_generation_config(repository_id, opts) do
    if Code.ensure_loaded?(Bumblebee) do
      # Convert to Bumblebee's expected format
      repo =
        if String.starts_with?(repository_id, "/") do
          {:local, repository_id}
        else
          {:hf, repository_id}
        end

      apply(Bumblebee, :load_generation_config, [repo, opts])
    else
      {:error, "Bumblebee not available"}
    end
  end

  defp create_text_generation_serving(model_info, tokenizer, generation_config, opts) do
    if Code.ensure_loaded?(Bumblebee.Text) do
      apply(Bumblebee.Text, :generation, [
        model_info,
        tokenizer,
        generation_config,
        opts
      ])
    else
      nil
    end
  end
end
