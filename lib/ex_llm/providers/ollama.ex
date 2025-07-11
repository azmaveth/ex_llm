defmodule ExLLM.Providers.Ollama do
  @moduledoc """
  Ollama API adapter for ExLLM - provides local model inference via Ollama server.

  ## Configuration

  This adapter requires a running Ollama server. By default, it connects to localhost:11434.

  ### Using Environment Variables

      # Set environment variables
      export OLLAMA_API_BASE="http://localhost:11434"  # optional
      export OLLAMA_MODEL="llama2"  # optional

      # Use with default environment provider
      ExLLM.Providers.Ollama.chat(messages, config_provider: ExLLM.Infrastructure.ConfigProvider.Env)

  ### Using Static Configuration

      config = %{
        ollama: %{
          base_url: "http://localhost:11434",
          model: "llama2"
        }
      }
      {:ok, provider} = ExLLM.Infrastructure.ConfigProvider.Static.start_link(config)
      ExLLM.Providers.Ollama.chat(messages, config_provider: provider)

  ## Example Usage

      messages = [
        %{role: "user", content: "Hello, how are you?"}
      ]

      # Simple chat
      {:ok, response} = ExLLM.Providers.Ollama.chat(messages)
      IO.puts(response.content)

      # Streaming chat
      {:ok, stream} = ExLLM.Providers.Ollama.stream_chat(messages)
      for chunk <- stream do
        if chunk.content, do: IO.write(chunk.content)
      end

  ## Available Models

  To see available models, ensure Ollama is running and use:

      {:ok, models} = ExLLM.Providers.Ollama.list_models()

  ## Configuration Management

  The adapter provides functions to generate and update model configurations:

      # Generate configuration for all installed models
      {:ok, yaml} = ExLLM.Providers.Ollama.generate_config()
      
      # Save the configuration
      {:ok, path} = ExLLM.Providers.Ollama.generate_config(save: true)
      
      # Update a specific model's configuration
      {:ok, yaml} = ExLLM.Providers.Ollama.update_model_config("llama3.1")

  This is useful for keeping your `config/models/ollama.yml` in sync with your
  locally installed models and their actual capabilities.
  """

  @behaviour ExLLM.Provider

  alias ExLLM.Providers.Shared.{ConfigHelper, EnhancedStreamingCoordinator}
  alias ExLLM.Providers.Shared.HTTP.Core
  alias ExLLM.{Infrastructure.Logger, Types}

  @default_base_url "http://localhost:11434"

  @impl true
  def chat(messages, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    raw_model = Keyword.get(options, :model, Map.get(config, :model))
    # Strip provider prefix if present
    model = strip_provider_prefix(raw_model || get_default_model())

    # Ensure we have a model
    model = model || get_default_model()

    body = %{
      model: model,
      messages: format_messages(messages),
      stream: false
    }

    # Add tools/functions if provided
    body =
      cond do
        tools = Keyword.get(options, :tools) ->
          Map.put(body, :tools, tools)

        functions = Keyword.get(options, :functions) ->
          Map.put(body, :tools, format_functions_as_tools(functions))

        true ->
          body
      end

    # Add other optional parameters
    body = add_optional_params(body, options)

    # Add context if provided (for maintaining conversation state)
    body =
      case Keyword.get(options, :context) do
        nil -> body
        context -> Map.put(body, "context", context)
      end

    # Ollama can be slow, especially with function calling
    # Default to 2 minutes, but allow override
    timeout = Keyword.get(options, :timeout, 120_000)

    client = Core.client(provider: :ollama, base_url: get_base_url(config))

    case Tesla.post(client, "/api/chat", body, opts: [timeout: timeout]) do
      {:ok, %Tesla.Env{status: 200, body: response_body}} ->
        {:ok, parse_response(response_body, model)}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        ExLLM.Infrastructure.Error.api_error(status, error_body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @impl true
  def stream_chat(messages, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    raw_model = Keyword.get(options, :model, Map.get(config, :model))
    # Strip provider prefix if present
    model = strip_provider_prefix(raw_model || get_default_model())

    # Ensure we have a model
    model = model || get_default_model()

    formatted_messages = format_messages(messages)

    body = %{
      model: model,
      messages: formatted_messages,
      stream: true
    }

    # Add tools/functions if provided
    body =
      cond do
        tools = Keyword.get(options, :tools) ->
          Map.put(body, :tools, tools)

        functions = Keyword.get(options, :functions) ->
          Map.put(body, :tools, format_functions_as_tools(functions))

        true ->
          body
      end

    # Add other optional parameters
    body = add_optional_params(body, options)

    # Add context if provided (for maintaining conversation state)
    body =
      case Keyword.get(options, :context) do
        nil -> body
        context -> Map.put(body, "context", context)
      end

    # Debug log the request
    Logger.debug(
      "Ollama request - Model: #{model}, Messages: #{inspect(formatted_messages, limit: :infinity)}"
    )

    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/chat"

    # Create stream with enhanced coordinator
    chunks_ref = make_ref()
    parent = self()

    # Setup callback that sends chunks to parent
    callback = fn chunk ->
      send(parent, {chunks_ref, {:chunk, chunk}})
    end

    # Enhanced streaming options with Ollama-specific features
    stream_options = [
      parse_chunk_fn: &parse_ollama_chunk/1,
      provider: :ollama,
      model: model,
      stream_recovery: Keyword.get(options, :stream_recovery, false),
      track_metrics: Keyword.get(options, :track_metrics, false),
      on_metrics: Keyword.get(options, :on_metrics),
      buffer_chunks: Keyword.get(options, :buffer_chunks, 1),
      timeout: Keyword.get(options, :timeout, 120_000),
      # Enable enhanced features if requested
      enable_flow_control: Keyword.get(options, :enable_flow_control, false),
      enable_batching: Keyword.get(options, :enable_batching, false),
      track_detailed_metrics: Keyword.get(options, :track_detailed_metrics, false)
    ]

    Logger.with_context([provider: :ollama, model: model], fn ->
      {:ok, stream_id} =
        EnhancedStreamingCoordinator.start_stream(url, body, headers, callback, stream_options)

      # Create Elixir stream that receives chunks
      stream =
        Stream.resource(
          fn -> {chunks_ref, stream_id} end,
          fn {ref, _id} = state ->
            receive do
              {^ref, {:chunk, chunk}} -> {[chunk], state}
            after
              100 -> {[], state}
            end
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    end)
  end

  @impl true
  def list_models(options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    # Use ModelLoader with API fetching from Ollama server
    ExLLM.Infrastructure.Config.ModelLoader.load_models(
      :ollama,
      Keyword.merge(options,
        api_fetcher: fn _opts -> fetch_ollama_models(config) end,
        config_transformer: &ollama_model_transformer/2
      )
    )
  end

  defp fetch_ollama_models(config) do
    client = Core.client(provider: :ollama, base_url: get_base_url(config))

    case Tesla.get(client, "/api/tags", opts: [timeout: 5_000]) do
      {:ok, %Tesla.Env{status: 200, body: body}} when is_map(body) ->
        models =
          (body["models"] || [])
          |> Enum.map(&parse_ollama_api_model/1)

        {:ok, models}

      {:ok, %Tesla.Env{status: 200, body: _}} ->
        {:error, "Invalid response format from Ollama API"}

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        ExLLM.Infrastructure.Error.api_error(status, error_body)

      {:error, reason} ->
        Logger.debug("Failed to connect to Ollama: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_ollama_api_model(model) do
    model_name = model["name"]

    # Try to get detailed info if available
    {capabilities, context_window} =
      case get_model_details(model_name) do
        {:ok, details} ->
          caps = details["capabilities"] || []

          ctx =
            get_context_from_model_info(details["model_info"]) ||
              get_ollama_context_window(model)

          {caps, ctx}

        _ ->
          {[], get_ollama_context_window(model)}
      end

    # Determine features based on capabilities or fallback to name detection
    supports_functions =
      "tools" in capabilities ||
        ("completion" in capabilities && "tools" in capabilities) ||
        supports_function_calling?(model_name)

    supports_embeddings =
      "embedding" in capabilities ||
        String.contains?(model_name, "embed")

    features = [:streaming]
    features = if supports_functions, do: [:function_calling | features], else: features
    features = if is_vision_model?(model_name), do: [:vision | features], else: features
    features = if supports_embeddings, do: [:embeddings | features], else: features

    %Types.Model{
      id: model_name,
      name: model_name,
      description: format_ollama_description(model),
      context_window: context_window,
      capabilities: %{
        supports_streaming: true,
        supports_functions: supports_functions,
        supports_vision: is_vision_model?(model_name),
        supports_embeddings: supports_embeddings,
        features: features
      }
    }
  end

  defp get_model_details(model_name) do
    # Try to get detailed info via show endpoint
    # This is optional - if it fails, we fall back to basic info
    try do
      case show_model(model_name) do
        {:ok, details} -> {:ok, details}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp get_context_from_model_info(nil), do: nil

  defp get_context_from_model_info(model_info) do
    # Try different architecture fields
    model_info["qwen3.context_length"] ||
      model_info["llama.context_length"] ||
      model_info["bert.context_length"] ||
      model_info["mistral.context_length"] ||
      model_info["gemma.context_length"] ||
      nil
  end

  defp format_ollama_description(model) do
    details = model["details"] || %{}
    family = details["family"]
    param_size = details["parameter_size"]
    quantization = details["quantization_level"]

    parts =
      [family, param_size, quantization]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    if parts != "", do: parts, else: nil
  end

  defp get_ollama_context_window(model) do
    # Try to extract from model details or use default
    case get_in(model, ["details", "parameter_size"]) do
      nil ->
        4_096

      size_str when is_binary(size_str) ->
        # Convert parameter size to approximate context window
        if String.contains?(size_str, "B") do
          # Rough estimation: larger models typically have larger context
          cond do
            String.contains?(size_str, "70B") -> 32_768
            String.contains?(size_str, "34B") -> 16_384
            String.contains?(size_str, "13B") -> 8_192
            String.contains?(size_str, "7B") -> 4_096
            true -> 4_096
          end
        else
          4_096
        end

      _ ->
        4_096
    end
  end

  defp is_vision_model?(model_name) do
    String.contains?(model_name, "vision") ||
      String.contains?(model_name, "llava") ||
      String.contains?(model_name, "bakllava")
  end

  defp supports_function_calling?(model_name) do
    # Models that support function calling in Ollama
    # Based on Ollama documentation and model capabilities
    function_capable_models = [
      # Llama 3.1+ supports tools
      "llama3.1",
      "llama3.2",
      "llama3.3",
      # Qwen 2.5 supports tools
      "qwen2.5",
      "qwen2",
      # Mistral models support tools
      "mistral",
      "mixtral",
      # Gemma 2 supports tools
      "gemma2",
      # Command R supports tools
      "command-r",
      # Firefunction is specifically for functions
      "firefunction"
    ]

    Enum.any?(function_capable_models, fn model ->
      String.contains?(String.downcase(model_name), model)
    end)
  end

  # Transform config data to Ollama model format
  defp ollama_model_transformer(model_id, config) do
    %Types.Model{
      id: to_string(model_id),
      name: Map.get(config, :name, to_string(model_id)),
      description: Map.get(config, :description),
      context_window: Map.get(config, :context_window, 4_096),
      capabilities: %{
        supports_streaming: :streaming in Map.get(config, :capabilities, []),
        supports_functions: :function_calling in Map.get(config, :capabilities, []),
        supports_vision: :vision in Map.get(config, :capabilities, []),
        features: Map.get(config, :capabilities, [])
      }
    }
  end

  @impl true
  def configured?(options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    base_url = get_base_url(config)
    # Ollama only needs a base URL to be configured
    !is_nil(base_url) && base_url != ""
  end

  @impl true
  def default_model do
    get_default_model()
  end

  # Private helper to get default model from config
  defp get_default_model do
    model = ConfigHelper.ensure_default_model(:ollama)
    # Strip the "ollama/" prefix if present
    strip_provider_prefix(model)
  end

  defp strip_provider_prefix(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      ["ollama", actual_model] -> actual_model
      _ -> model
    end
  end

  defp strip_provider_prefix(nil), do: nil

  # Private functions

  defp get_config(config_provider) do
    config_provider.get_all(:ollama)
  end

  defp get_base_url(config) when is_map(config) do
    # Check environment variable first, then config, then default
    System.get_env("OLLAMA_API_BASE") ||
      Map.get(config, :base_url) ||
      @default_base_url
  end

  defp get_base_url(_), do: get_base_url(%{})

  defp format_messages(messages) do
    Enum.map(messages, &format_single_message/1)
  end

  defp format_single_message(msg) do
    role = to_string(msg.role || msg["role"])
    content = format_message_content(msg.content || msg["content"])

    build_formatted_message(role, content)
  end

  defp format_message_content(content) when is_binary(content), do: content

  defp format_message_content(content) when is_list(content),
    do: process_multimodal_content(content)

  defp format_message_content(content), do: to_string(content)

  defp process_multimodal_content(content_list) do
    {text_parts, images} = extract_content_parts(content_list)

    # Combine text parts
    text = text_parts |> Enum.reverse() |> Enum.join("\n")

    # Return tuple if we have images, otherwise just text
    if images != [], do: {text, Enum.reverse(images)}, else: text
  end

  defp extract_content_parts(content_list) do
    Enum.reduce(content_list, {[], []}, &process_content_item/2)
  end

  defp process_content_item(item, {texts, imgs}) do
    case extract_item_type(item) do
      {:text, text} -> {[text | texts], imgs}
      {:image, url} -> process_image_url(url, texts, imgs)
      :unknown -> {texts, imgs}
    end
  end

  defp extract_item_type(%{"type" => "text", "text" => text}), do: {:text, text}
  defp extract_item_type(%{type: "text", text: text}), do: {:text, text}

  defp extract_item_type(%{"type" => "image_url", "image_url" => %{"url" => url}}),
    do: {:image, url}

  defp extract_item_type(%{type: "image_url", image_url: %{url: url}}), do: {:image, url}
  defp extract_item_type(_), do: :unknown

  defp process_image_url(url, texts, imgs) do
    case extract_base64_from_url(url) do
      nil -> {texts, imgs}
      base64 -> {texts, [base64 | imgs]}
    end
  end

  defp build_formatted_message(role, {text, images}) when is_list(images) do
    # Multimodal message
    %{
      role: role,
      content: text,
      images: images
    }
  end

  defp build_formatted_message(role, text) do
    # Regular text message
    %{
      role: role,
      content: text
    }
  end

  defp extract_base64_from_url(url) do
    case url do
      "data:image/" <> rest ->
        # Extract base64 data from data URL
        case String.split(rest, ";base64,", parts: 2) do
          [_mime, base64] -> base64
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_response(response, model) do
    usage = %{
      input_tokens: response["prompt_eval_count"] || 0,
      output_tokens: response["eval_count"] || 0,
      total_tokens: (response["prompt_eval_count"] || 0) + (response["eval_count"] || 0)
    }

    message = response["message"] || %{}

    # Check if this is a tool call response
    tool_calls = message["tool_calls"]

    %Types.LLMResponse{
      content: message["content"] || "",
      usage: usage,
      model: model,
      finish_reason: if(response["done"], do: "stop", else: nil),
      tool_calls: parse_tool_calls(tool_calls),
      cost: nil
    }
  end

  defp parse_tool_calls(nil), do: nil
  defp parse_tool_calls([]), do: nil

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn call ->
      %{
        id: call["id"] || generate_tool_call_id(),
        type: "function",
        function: %{
          name: get_in(call, ["function", "name"]),
          arguments: get_in(call, ["function", "arguments"])
        }
      }
    end)
  end

  defp generate_tool_call_id do
    "call_" <> Base.encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp format_functions_as_tools(functions) do
    Enum.map(functions, fn func ->
      %{
        type: "function",
        function: %{
          name: func.name || func["name"],
          description: func.description || func["description"],
          parameters: func.parameters || func["parameters"] || %{}
        }
      }
    end)
  end

  defp add_optional_params(body, options) do
    # Standard parameters
    optional_params = [
      {:temperature, "temperature"},
      # Ollama uses num_predict instead of max_tokens
      {:max_tokens, "num_predict"},
      {:top_p, "top_p"},
      {:top_k, "top_k"},
      {:seed, "seed"},
      {:stop, "stop"},
      {:keep_alive, "keep_alive"},
      {:suffix, "suffix"}
    ]

    body =
      Enum.reduce(optional_params, body, fn {opt_key, api_key}, acc ->
        case Keyword.get(options, opt_key) do
          nil -> acc
          value -> Map.put(acc, api_key, value)
        end
      end)

    # Handle format parameter specially
    body =
      case Keyword.get(options, :format) do
        nil -> body
        "json" -> Map.put(body, "format", "json")
        :json -> Map.put(body, "format", "json")
        format -> Map.put(body, "format", format)
      end

    # Handle the options parameter which contains model-specific settings
    case Keyword.get(options, :options) do
      nil ->
        # Check for individual option parameters
        add_model_specific_options(body, options)

      opts when is_map(opts) ->
        Map.put(body, "options", opts)

      opts when is_list(opts) ->
        Map.put(body, "options", Map.new(opts))
    end
  end

  defp add_model_specific_options(body, options) do
    # Model-specific options that can be passed individually
    model_options = [
      # Context and prediction settings
      {:num_ctx, "num_ctx"},
      {:num_batch, "num_batch"},
      # Alternative to max_tokens
      {:num_predict, "num_predict"},

      # GPU settings
      {:num_gpu, "num_gpu"},
      {:main_gpu, "main_gpu"},
      {:low_vram, "low_vram"},

      # Memory settings
      {:f16_kv, "f16_kv"},
      {:use_mmap, "use_mmap"},
      {:use_mlock, "use_mlock"},

      # Sampling parameters
      {:mirostat, "mirostat"},
      {:mirostat_tau, "mirostat_tau"},
      {:mirostat_eta, "mirostat_eta"},
      {:repeat_penalty, "repeat_penalty"},
      {:repeat_last_n, "repeat_last_n"},
      {:frequency_penalty, "frequency_penalty"},
      {:presence_penalty, "presence_penalty"},
      {:tfs_z, "tfs_z"},
      {:typical_p, "typical_p"},

      # Other settings
      {:num_thread, "num_thread"},
      {:numa, "numa"},
      {:vocab_only, "vocab_only"},
      {:penalize_newline, "penalize_newline"}
    ]

    # Collect model-specific options if provided individually
    collected_options =
      Enum.reduce(model_options, %{}, fn {opt_key, api_key}, acc ->
        case Keyword.get(options, opt_key) do
          nil -> acc
          value -> Map.put(acc, api_key, value)
        end
      end)

    if map_size(collected_options) > 0 do
      Map.put(body, "options", collected_options)
    else
      body
    end
  end

  defp flush_mailbox do
    receive do
      :stream_done ->
        Logger.debug("Flushing stale :stream_done message")
        flush_mailbox()

      {:chunk, _} ->
        Logger.debug("Flushing stale chunk message")
        flush_mailbox()

      {:stream_error, _} ->
        Logger.debug("Flushing stale error message")
        flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp parse_stream_chunk(data, model) when is_binary(data) do
    # Ollama uses NDJSON format
    case Jason.decode(data) do
      {:ok, chunk} ->
        if chunk["done"] do
          # Stream completed
          finish_reason = chunk["finish_reason"]

          if finish_reason == "error" do
            error_msg = chunk["error"] || "Unknown error"
            Logger.warning("Ollama streaming error: #{error_msg}")
          end

          # Return nil to signal completion
          nil
        else
          content = get_in(chunk, ["message", "content"]) || ""

          # Log if we're getting chunks but no content
          if content == "" do
            Logger.debug("Ollama: Received chunk with empty content: #{inspect(chunk)}")
          end

          %Types.StreamChunk{
            content: content,
            finish_reason: nil,
            model: model
          }
        end

      {:error, _} ->
        # Skip invalid JSON
        nil
    end
  end

  @impl true
  def embeddings(inputs, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    raw_model =
      Keyword.get(options, :model, Map.get(config, :embedding_model, "nomic-embed-text"))

    # Strip provider prefix if present
    model = strip_provider_prefix(raw_model)

    # Ensure inputs is a list
    inputs = if is_binary(inputs), do: [inputs], else: inputs

    # Ollama's /api/embed endpoint expects a single request with the input
    body = %{
      model: model,
      # Changed from prompt to input, and now supports batch
      input: inputs
    }

    headers = [{"content-type", "application/json"}]
    # Changed from /api/embeddings to /api/embed
    url = "#{get_base_url(config)}/api/embed"

    # Get timeout with default
    timeout = Keyword.get(options, :timeout, 30_000)

    case Req.post(url, json: body, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        # Ollama returns embeddings in the "embeddings" field
        embeddings = response_body["embeddings"] || []

        {:ok,
         %Types.EmbeddingResponse{
           embeddings: embeddings,
           model: model,
           usage: %{
             input_tokens: estimate_embedding_tokens(inputs),
             # Embeddings don't have output tokens
             output_tokens: 0,
             total_tokens: estimate_embedding_tokens(inputs)
           }
         }}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Generate a completion for the given prompt using Ollama's /api/generate endpoint.

  This is for non-chat completions, useful for base models or specific use cases.

  ## Options
  - `:model` - The model to use (required)
  - `:prompt` - The prompt text (required)
  - `:suffix` - Text to append after the generation
  - `:images` - List of base64-encoded images for multimodal models
  - `:format` - Response format (e.g., "json")
  - `:options` - Model-specific options (temperature, seed, etc.)
  - `:context` - Context from previous request for maintaining conversation state
  - `:raw` - If true, no formatting will be applied to the prompt
  - `:keep_alive` - How long to keep the model loaded (e.g., "5m")
  - `:timeout` - Request timeout in milliseconds

  ## Examples

      # Simple completion
      {:ok, response} = ExLLM.Providers.Ollama.generate("Complete this: The sky is", 
        model: "llama3.1")
      
      # With options
      {:ok, response} = ExLLM.Providers.Ollama.generate("Write a haiku about coding",
        model: "llama3.1",
        options: %{temperature: 0.7, seed: 42})
      
      # Maintain conversation context
      {:ok, response1} = ExLLM.Providers.Ollama.generate("Hi, I'm learning Elixir",
        model: "llama3.1")
      {:ok, response2} = ExLLM.Providers.Ollama.generate("What should I learn first?",
        model: "llama3.1",
        context: response1.context)
  """
  def generate(prompt, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    raw_model = Keyword.get(options, :model) || get_default_model()
    model = strip_provider_prefix(raw_model)

    # Build request body
    body = %{
      model: model,
      prompt: prompt,
      stream: false
    }

    # Add optional parameters
    body =
      body
      |> maybe_add_param(:suffix, options)
      |> maybe_add_param(:images, options)
      |> maybe_add_param(:format, options)
      |> maybe_add_param(:options, options)
      |> maybe_add_param(:context, options)
      |> maybe_add_param(:raw, options)
      |> maybe_add_param(:keep_alive, options)

    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/generate"

    timeout = Keyword.get(options, :timeout, 120_000)

    req_options = [
      json: body,
      headers: headers,
      receive_timeout: timeout,
      retry: false
    ]

    case Req.post(url, req_options) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, parse_generate_response(response, model)}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Stream a completion using the /api/generate endpoint.

  Similar to `generate/2` but returns a stream of response chunks.
  """
  def stream_generate(prompt, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    raw_model = Keyword.get(options, :model) || get_default_model()
    model = strip_provider_prefix(raw_model)

    # Build request body
    body = %{
      model: model,
      prompt: prompt,
      stream: true
    }

    # Add optional parameters
    body =
      body
      |> maybe_add_param(:suffix, options)
      |> maybe_add_param(:images, options)
      |> maybe_add_param(:format, options)
      |> maybe_add_param(:options, options)
      |> maybe_add_param(:context, options)
      |> maybe_add_param(:raw, options)
      |> maybe_add_param(:keep_alive, options)

    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/generate"
    parent = self()

    # Clear any stale messages from mailbox
    flush_mailbox()

    timeout = Keyword.get(options, :timeout, 120_000)

    # Start async request task
    Task.start(fn ->
      case Req.post(url, json: body, headers: headers, receive_timeout: timeout, into: :self) do
        {:ok, response} ->
          if response.status == 200 do
            handle_generate_stream_response(response, parent, model)
          else
            Logger.error(
              "Ollama API error - Status: #{response.status}, Body: #{inspect(response.body)}"
            )

            send(
              parent,
              {:stream_error,
               ExLLM.Infrastructure.Error.api_error(response.status, response.body)}
            )
          end

        {:error, reason} ->
          Logger.error("Ollama connection error: #{inspect(reason)}")
          send(parent, {:stream_error, ExLLM.Infrastructure.Error.connection_error(reason)})
      end
    end)

    # Create stream that receives messages
    stream =
      Stream.resource(
        fn -> :ok end,
        fn state ->
          receive do
            {:chunk, chunk} ->
              {[chunk], state}

            :stream_done ->
              {:halt, state}

            {:stream_error, error} ->
              Logger.error("Stream error: #{inspect(error)}")
              {:halt, {:error, error}}
          after
            100 -> {[], state}
          end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  defp parse_generate_response(response, model) do
    usage = %{
      input_tokens: response["prompt_eval_count"] || 0,
      output_tokens: response["eval_count"] || 0,
      total_tokens: (response["prompt_eval_count"] || 0) + (response["eval_count"] || 0)
    }

    # Store context and timing info in the response
    # We'll add context to the content as a special marker for now
    content = response["response"] || ""

    # Include context and timing metadata if available
    metadata = build_generate_metadata(response)

    %Types.LLMResponse{
      content: content,
      usage: usage,
      model: model,
      finish_reason: if(response["done"], do: "stop", else: nil),
      cost: nil,
      metadata: metadata
    }
  end

  defp handle_generate_stream_response(response, parent, model) do
    %Req.Response.Async{ref: ref} = response.body

    receive do
      {^ref, {:data, data}} ->
        # Parse each line of the NDJSON response
        lines = String.split(data, "\n", trim: true)

        lines
        |> Enum.each(fn line ->
          case Jason.decode(line) do
            {:ok, chunk} ->
              if chunk["done"] do
                send(parent, :stream_done)
              else
                content = chunk["response"] || ""

                stream_chunk = %Types.StreamChunk{
                  content: content,
                  finish_reason: nil,
                  metadata: build_stream_chunk_metadata(chunk)
                }

                send(parent, {:chunk, stream_chunk})
              end

            {:error, _} ->
              # Skip invalid JSON lines
              :ok
          end
        end)

        # Continue receiving more data
        handle_generate_stream_response(response, parent, model)

      {^ref, :done} ->
        Logger.debug("Ollama: Generate stream done")
        send(parent, :stream_done)

      {^ref, {:error, reason}} ->
        send(parent, {:stream_error, {:error, reason}})
    after
      120_000 ->
        send(parent, {:stream_error, {:error, :timeout}})
    end
  end

  defp maybe_add_param(body, key, options) do
    case Keyword.get(options, key) do
      nil -> body
      value -> Map.put(body, key, value)
    end
  end

  @doc """
  Get detailed information about a specific model.

  Uses Ollama's /api/show endpoint to retrieve model details including
  modelfile, parameters, template, and more.

  ## Examples

      {:ok, info} = ExLLM.Providers.Ollama.show_model("llama3.1")
  """
  def show_model(model_name, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    model = strip_provider_prefix(model_name)

    body = %{name: model}
    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/show"

    case Req.post(url, json: body, headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Copy a model to a new name.

  Uses Ollama's /api/copy endpoint to create a copy of an existing model
  with a new name.

  ## Examples

      {:ok, _} = ExLLM.Providers.Ollama.copy_model("llama3.1", "my-llama")
  """
  def copy_model(source, destination, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    body = %{
      source: strip_provider_prefix(source),
      destination: strip_provider_prefix(destination)
    }

    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/copy"

    case Req.post(url, json: body, headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200}} ->
        {:ok, %{message: "Model copied successfully"}}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Delete a model from Ollama.

  Uses Ollama's /api/delete endpoint to remove a model from the local
  model store.

  ## Examples

      {:ok, _} = ExLLM.Providers.Ollama.delete_model("old-model")
  """
  def delete_model(model_name, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    model = strip_provider_prefix(model_name)

    body = %{name: model}
    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/delete"

    case Req.delete(url, json: body, headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200}} ->
        {:ok, %{message: "Model deleted successfully"}}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Pull a model from the Ollama library.

  Uses Ollama's /api/pull endpoint to download a model. This returns
  a stream of progress updates.

  ## Examples

      {:ok, stream} = ExLLM.Providers.Ollama.pull_model("llama3.1:latest")
      for update <- stream do
        IO.puts("Status: \#{update["status"]}")
      end
  """
  def pull_model(model_name, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    model = strip_provider_prefix(model_name)

    body = %{
      name: model,
      stream: true
    }

    # Add insecure flag if requested
    body =
      if Keyword.get(options, :insecure, false) do
        Map.put(body, "insecure", true)
      else
        body
      end

    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/pull"
    parent = self()

    flush_mailbox()

    # Start async request task
    Task.start(fn ->
      case Req.post(url, json: body, headers: headers, receive_timeout: 300_000, into: :self) do
        {:ok, response} ->
          if response.status == 200 do
            handle_pull_stream_response(response, parent)
          else
            send(
              parent,
              {:stream_error,
               ExLLM.Infrastructure.Error.api_error(response.status, response.body)}
            )
          end

        {:error, reason} ->
          send(parent, {:stream_error, ExLLM.Infrastructure.Error.connection_error(reason)})
      end
    end)

    # Create stream that receives messages
    stream =
      Stream.resource(
        fn -> :ok end,
        fn state ->
          receive do
            {:pull_update, update} ->
              {[update], state}

            :stream_done ->
              {:halt, state}

            {:stream_error, error} ->
              throw(error)
          after
            100 -> {[], state}
          end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  @doc """
  Push a model to the Ollama library.

  Uses Ollama's /api/push endpoint to upload a model.

  ## Examples

      {:ok, stream} = ExLLM.Providers.Ollama.push_model("my-model:latest")
  """
  def push_model(model_name, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    model = strip_provider_prefix(model_name)

    body = %{
      name: model,
      stream: true
    }

    # Add insecure flag if requested
    body =
      if Keyword.get(options, :insecure, false) do
        Map.put(body, "insecure", true)
      else
        body
      end

    headers = [{"content-type", "application/json"}]
    url = "#{get_base_url(config)}/api/push"
    parent = self()

    flush_mailbox()

    # Start async request task
    Task.start(fn ->
      case Req.post(url, json: body, headers: headers, receive_timeout: 300_000, into: :self) do
        {:ok, response} ->
          if response.status == 200 do
            handle_push_stream_response(response, parent)
          else
            send(
              parent,
              {:stream_error,
               ExLLM.Infrastructure.Error.api_error(response.status, response.body)}
            )
          end

        {:error, reason} ->
          send(parent, {:stream_error, ExLLM.Infrastructure.Error.connection_error(reason)})
      end
    end)

    # Create stream that receives messages
    stream =
      Stream.resource(
        fn -> :ok end,
        fn state ->
          receive do
            {:push_update, update} ->
              {[update], state}

            :stream_done ->
              {:halt, state}

            {:stream_error, error} ->
              throw(error)
          after
            100 -> {[], state}
          end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  @doc """
  List currently loaded models.

  Uses Ollama's /api/ps endpoint to show which models are currently
  loaded in memory.

  ## Examples

      {:ok, loaded} = ExLLM.Providers.Ollama.list_running_models()
  """
  def list_running_models(options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    url = "#{get_base_url(config)}/api/ps"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response["models"] || []}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Get Ollama version information.

  ## Examples

      {:ok, version} = ExLLM.Providers.Ollama.version()
  """
  def version(options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)
    url = "#{get_base_url(config)}/api/version"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        ExLLM.Infrastructure.Error.api_error(status, body)

      {:error, reason} ->
        ExLLM.Infrastructure.Error.connection_error(reason)
    end
  end

  @doc """
  Generate YAML configuration for all locally installed Ollama models.

  This function fetches information about all installed models and generates
  a YAML configuration that can be saved to `config/models/ollama.yml`.

  ## Options

  - `:save` - When true, saves the configuration to the file (default: false)
  - `:path` - Custom path for the YAML file (default: "config/models/ollama.yml")
  - `:merge` - When true, merges with existing configuration (default: true)

  ## Examples

      # Generate configuration and return as string
      {:ok, yaml} = ExLLM.Providers.Ollama.generate_config()
      
      # Save directly to config/models/ollama.yml
      {:ok, path} = ExLLM.Providers.Ollama.generate_config(save: true)
      
      # Save to custom location
      {:ok, path} = ExLLM.Providers.Ollama.generate_config(
        save: true, 
        path: "my_ollama_config.yml"
      )
      
      # Replace existing configuration instead of merging
      {:ok, yaml} = ExLLM.Providers.Ollama.generate_config(merge: false)
  """
  def generate_config(options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    config = get_config(config_provider)

    # Fetch all models
    case fetch_ollama_models(config) do
      {:ok, models} ->
        # Build model configuration
        model_configs = build_model_configs(models, config)

        # Determine default model
        default_model = determine_default_model(model_configs, options)

        # Build full configuration
        yaml_config = %{
          "provider" => "ollama",
          "default_model" => default_model,
          "models" => model_configs,
          "metadata" => %{
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "source" => "ollama_generate_config"
          }
        }

        # Handle merging if requested
        yaml_config =
          if Keyword.get(options, :merge, true) do
            merge_with_existing_config(yaml_config, options)
          else
            yaml_config
          end

        # Convert to YAML
        yaml_string = to_yaml(yaml_config)

        # Save if requested
        if Keyword.get(options, :save, false) do
          save_config_to_file(yaml_string, options)
        else
          {:ok, yaml_string}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Update configuration for a specific model in ollama.yml.

  This function fetches the latest information for a specific model and
  updates its entry in the configuration file.

  ## Options

  - `:save` - When true, saves the configuration to the file (default: true)
  - `:path` - Custom path for the YAML file (default: "config/models/ollama.yml")

  ## Examples

      # Update a specific model's configuration
      {:ok, yaml} = ExLLM.Providers.Ollama.update_model_config("llama3.1")
      
      # Update without saving (preview changes)
      {:ok, yaml} = ExLLM.Providers.Ollama.update_model_config("llama3.1", save: false)
  """
  def update_model_config(model_name, options \\ []) do
    config_provider =
      Keyword.get(
        options,
        :config_provider,
        Application.get_env(
          :ex_llm,
          :config_provider,
          ExLLM.Infrastructure.ConfigProvider.Default
        )
      )

    model = strip_provider_prefix(model_name)

    # Get detailed info for this specific model
    case show_model(model, config_provider: config_provider) do
      {:ok, details} ->
        # Build configuration for this model
        model_config = build_single_model_config(model, details)

        # Load existing configuration
        path = Keyword.get(options, :path, "config/models/ollama.yml")
        existing_config = load_yaml_config(path)

        # Update the specific model
        updated_config =
          existing_config
          |> put_in(["models", "ollama/#{model}"], model_config)
          |> put_in(["metadata", "updated_at"], DateTime.utc_now() |> DateTime.to_iso8601())
          |> put_in(["metadata", "source"], "ollama_update_model")

        # Convert to YAML
        yaml_string = to_yaml(updated_config)

        # Save if requested (default: true for this function)
        if Keyword.get(options, :save, true) do
          save_config_to_file(yaml_string, options)
        else
          {:ok, yaml_string}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_pull_stream_response(response, parent) do
    %Req.Response.Async{ref: ref} = response.body

    receive do
      {^ref, {:data, data}} ->
        lines = String.split(data, "\n", trim: true)

        lines
        |> Enum.each(fn line ->
          case Jason.decode(line) do
            {:ok, update} ->
              if update["status"] == "success" do
                send(parent, :stream_done)
              else
                send(parent, {:pull_update, update})
              end

            {:error, _} ->
              :ok
          end
        end)

        handle_pull_stream_response(response, parent)

      {^ref, :done} ->
        send(parent, :stream_done)

      {^ref, {:error, reason}} ->
        send(parent, {:stream_error, {:error, reason}})
    after
      300_000 ->
        send(parent, {:stream_error, {:error, :timeout}})
    end
  end

  defp handle_push_stream_response(response, parent) do
    %Req.Response.Async{ref: ref} = response.body

    receive do
      {^ref, {:data, data}} ->
        lines = String.split(data, "\n", trim: true)

        lines
        |> Enum.each(fn line ->
          case Jason.decode(line) do
            {:ok, update} ->
              if update["status"] == "success" do
                send(parent, :stream_done)
              else
                send(parent, {:push_update, update})
              end

            {:error, _} ->
              :ok
          end
        end)

        handle_push_stream_response(response, parent)

      {^ref, :done} ->
        send(parent, :stream_done)

      {^ref, {:error, reason}} ->
        send(parent, {:stream_error, {:error, reason}})
    after
      300_000 ->
        send(parent, {:stream_error, {:error, :timeout}})
    end
  end

  @impl true
  def list_embedding_models(options \\ []) do
    {:ok, models} = list_models(options)

    # Filter to only embedding models
    embedding_models =
      models
      |> Enum.filter(fn model ->
        String.contains?(model.name, "embed") ||
          String.contains?(model.name, "embedding")
      end)
      |> Enum.map(fn model ->
        %Types.EmbeddingModel{
          name: model.name,
          dimensions: estimate_embedding_dimensions(model.name),
          # Ollama processes one at a time
          max_inputs: 1,
          provider: :ollama,
          description: model.description
        }
      end)

    {:ok, embedding_models}
  end

  defp estimate_embedding_tokens(inputs) when is_list(inputs) do
    inputs
    |> Enum.map(&String.length/1)
    |> Enum.sum()
    # Rough estimate: 4 chars per token
    |> div(4)
  end

  defp estimate_embedding_dimensions(model_name) do
    cond do
      String.contains?(model_name, "nomic") -> 768
      String.contains?(model_name, "mxbai") -> 512
      String.contains?(model_name, "all-minilm") -> 384
      # Default dimension
      true -> 1024
    end
  end

  # Helper functions for generate_config

  @dialyzer {:nowarn_function, build_model_configs: 2}
  defp build_model_configs(models, config) do
    base_url = get_base_url(config)

    models
    |> Enum.reduce(%{}, fn model, acc ->
      model_name = model.name

      # Try to get detailed info for better configuration
      detailed_config =
        case get_model_details_direct(model_name, base_url) do
          {:ok, details} ->
            build_single_model_config(model_name, details)

          _ ->
            # Fallback to basic info from list_models
            build_basic_model_config(model)
        end

      Map.put(acc, "ollama/#{model_name}", detailed_config)
    end)
  end

  @dialyzer {:nowarn_function, get_model_details_direct: 2}
  defp get_model_details_direct(model_name, base_url) do
    body = %{name: model_name}
    headers = [{"content-type", "application/json"}]
    url = "#{base_url}/api/show"

    case Req.post(url, json: body, headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      _ ->
        :error
    end
  end

  defp build_single_model_config(model_name, details) do
    # Extract capabilities from API response
    capabilities = details["capabilities"] || []

    # Get context window from model_info
    context_window =
      case details["model_info"] do
        nil -> 4096
        info -> get_context_from_model_info(info) || 4096
      end

    # Build capability list
    cap_list = ["streaming"]

    cap_list =
      if "tools" in capabilities || ("completion" in capabilities && "tools" in capabilities) do
        ["function_calling" | cap_list]
      else
        cap_list
      end

    cap_list =
      if "embedding" in capabilities do
        ["embeddings" | cap_list]
      else
        cap_list
      end

    # Add vision if in model name (API doesn't report this yet)
    cap_list =
      if is_vision_model?(model_name) do
        ["vision" | cap_list]
      else
        cap_list
      end

    # Build config map
    config = %{
      "context_window" => context_window,
      "capabilities" => Enum.sort(cap_list)
    }

    # Add parameter size if available
    case details["details"] do
      %{"parameter_size" => size} when is_binary(size) ->
        Map.put(config, "parameter_size", size)

      _ ->
        config
    end
  end

  @dialyzer {:nowarn_function, build_basic_model_config: 1}
  defp build_basic_model_config(model) do
    # Fallback for when we can't get detailed info
    %{
      "context_window" => model.context_window || 4096,
      "capabilities" =>
        model.capabilities.features
        |> Enum.map(&to_string/1)
        |> Enum.sort()
    }
  end

  @dialyzer {:nowarn_function, determine_default_model: 2}
  defp determine_default_model(model_configs, options) do
    cond do
      # If explicitly provided
      default = Keyword.get(options, :default_model) ->
        default

      # If existing config has a default, preserve it
      existing = load_existing_default(options) ->
        existing

      # If we have the common default model
      Map.has_key?(model_configs, "ollama/llama3.1") ->
        "ollama/llama3.1"

      # Otherwise use the first model
      true ->
        case Map.keys(model_configs) do
          [] -> "ollama/llama2"
          [first | _] -> first
        end
    end
  end

  @dialyzer {:nowarn_function, merge_with_existing_config: 2}
  defp merge_with_existing_config(new_config, options) do
    path = Keyword.get(options, :path, "config/models/ollama.yml")
    existing_config = load_yaml_config(path)

    # Deep merge, preserving existing data where not updated
    %{
      "provider" => "ollama",
      "default_model" => new_config["default_model"] || existing_config["default_model"],
      "models" => deep_merge_models(existing_config["models"] || %{}, new_config["models"]),
      "metadata" => new_config["metadata"]
    }
  end

  @dialyzer {:nowarn_function, deep_merge_models: 2}
  defp deep_merge_models(existing_models, new_models) do
    # Start with all new models
    merged = new_models

    # Add any existing models not in the new set
    Enum.reduce(existing_models, merged, fn {model_name, model_config}, acc ->
      if Map.has_key?(acc, model_name) do
        # Model exists in new config, merge preserving any custom fields
        updated_config = Map.merge(model_config, acc[model_name])
        Map.put(acc, model_name, updated_config)
      else
        # Model not in new config, preserve it
        Map.put(acc, model_name, model_config)
      end
    end)
  end

  defp load_yaml_config(path) do
    # Path is a hardcoded config file path, not user input
    # sobelow_skip ["Traversal.FileModule"]
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, config} -> config
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @dialyzer {:nowarn_function, load_existing_default: 1}
  defp load_existing_default(options) do
    path = Keyword.get(options, :path, "config/models/ollama.yml")
    config = load_yaml_config(path)
    config["default_model"]
  end

  defp to_yaml(data) do
    # Convert to YAML format manually since YamlElixir doesn't provide write functions
    # This is a simple implementation that handles our specific use case
    build_yaml_string(data, 0)
  end

  defp build_yaml_string(data, indent_level) when is_map(data) do
    data
    |> Enum.map(fn {key, value} ->
      indent = String.duplicate("  ", indent_level)

      case value do
        v when is_map(v) and map_size(v) > 0 ->
          "#{indent}#{key}:\n#{build_yaml_string(v, indent_level + 1)}"

        v when is_list(v) and length(v) > 0 ->
          items =
            Enum.map(v, fn item ->
              "#{indent}- #{item}"
            end)
            |> Enum.join("\n")

          "#{indent}#{key}:\n#{items}"

        v when is_binary(v) or is_atom(v) ->
          "#{indent}#{key}: #{format_yaml_value(v)}"

        v when is_integer(v) or is_float(v) ->
          "#{indent}#{key}: #{v}"

        _ ->
          "#{indent}#{key}: #{inspect(value)}"
      end
    end)
    |> Enum.join("\n")
  end

  defp format_yaml_value(value) when is_binary(value) do
    # Quote if contains special characters
    if String.contains?(value, ["\n", ":", "#", "@", "*", "&", "!", "|", ">", "'", "\"", "%", "?"]) do
      "'#{String.replace(value, "'", "''")}'"
    else
      value
    end
  end

  defp format_yaml_value(value) when is_atom(value), do: to_string(value)

  defp save_config_to_file(yaml_string, options) do
    # Path is controlled by the developer, not user input
    # sobelow_skip ["Traversal.FileModule"]
    path = Keyword.get(options, :path, "config/models/ollama.yml")

    # Ensure directory exists
    # sobelow_skip ["Traversal.FileModule"]
    File.mkdir_p!(Path.dirname(path))

    # Path is controlled by the developer, not user input
    # sobelow_skip ["Traversal.FileModule"]
    case File.write(path, yaml_string) do
      :ok ->
        Logger.info("Saved Ollama configuration to #{path}")
        {:ok, path}

      {:error, reason} ->
        {:error, "Failed to save configuration: #{inspect(reason)}"}
    end
  end

  # Helper functions for metadata extraction

  defp build_generate_metadata(response) do
    %{}
    |> maybe_add_metadata(:context, response["context"])
    |> maybe_add_metadata(:total_duration, response["total_duration"])
    |> maybe_add_metadata(:load_duration, response["load_duration"])
    |> maybe_add_metadata(:prompt_eval_duration, response["prompt_eval_duration"])
    |> maybe_add_metadata(:eval_duration, response["eval_duration"])
  end

  defp build_stream_chunk_metadata(chunk) do
    %{}
    |> maybe_add_metadata(:model, chunk["model"])
    |> maybe_add_metadata(:created_at, chunk["created_at"])
  end

  defp maybe_add_metadata(metadata, _key, nil), do: metadata
  defp maybe_add_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  # Parse streaming chunk for EnhancedStreamingCoordinator.
  # This wraps the existing parse_stream_chunk function to work with the coordinator.
  defp parse_ollama_chunk(data) do
    # The coordinator doesn't provide model context, so we'll extract it from the chunk
    case Jason.decode(data) do
      {:ok, chunk} ->
        model = chunk["model"] || "unknown"
        parse_stream_chunk(data, model)

      {:error, _} ->
        # Skip invalid JSON chunks
        nil
    end
  end
end
