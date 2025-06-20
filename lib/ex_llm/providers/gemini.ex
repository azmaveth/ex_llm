defmodule ExLLM.Providers.Gemini do
  @moduledoc """
  Google Gemini API adapter for ExLLM.

  Supports Gemini 2.5, 2.0, and 1.5 models including Flash and Pro variants.

  ## Configuration

  This adapter requires a Google API key.

  ### Using Environment Variables

      # Set environment variables
      export GOOGLE_API_KEY="your-api-key"
      export GEMINI_MODEL="gemini-2.0-flash"  # optional

      # Use with default environment provider
      ExLLM.Providers.Gemini.chat(messages, config_provider: ExLLM.Infrastructure.ConfigProvider.Env)

  ### Using Static Configuration

      config = %{
        gemini: %{
          api_key: "your-api-key",
          model: "gemini-2.5-flash-preview-05-20"
        }
      }
      {:ok, provider} = ExLLM.Infrastructure.ConfigProvider.Static.start_link(config)
      ExLLM.Providers.Gemini.chat(messages, config_provider: provider)

  ## Example Usage

      messages = [
        %{role: "user", content: "Hello, how are you?"}
      ]

      # Simple chat
      {:ok, response} = ExLLM.Providers.Gemini.chat(messages)
      IO.puts(response.content)

      # Streaming chat
      {:ok, stream} = ExLLM.Providers.Gemini.stream_chat(messages)
      for chunk <- stream do
        if chunk.content, do: IO.write(chunk.content)
      end

  ## Safety Settings

  You can customize safety settings:

      options = [
        safety_settings: [
          %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_ONLY_HIGH"},
          %{category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_ONLY_HIGH"}
        ]
      ]
      {:ok, response} = ExLLM.Providers.Gemini.chat(messages, options)
  """

  @behaviour ExLLM.Provider

  alias ExLLM.Types
  alias ExLLM.Providers.Shared.{ConfigHelper, ModelUtils}

  alias ExLLM.Providers.Gemini.Content.{
    GenerateContentRequest,
    GenerateContentResponse,
    Content,
    Part,
    GenerationConfig,
    SafetySetting,
    Tool
  }

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

    api_key = get_api_key(config)

    if !api_key || api_key == "" do
      {:error, "Google API key not configured"}
    else
      model =
        Keyword.get(
          options,
          :model,
          Map.get(config, :model, ConfigHelper.ensure_default_model(:gemini))
        )

      # Convert messages to Gemini Content format
      request = build_content_request(messages, options)

      case ExLLM.Providers.Gemini.Content.generate_content(model, request,
             config_provider: config_provider
           ) do
        {:ok, response} ->
          convert_content_response_to_llm_response(response, model)

        {:error, error} ->
          {:error, error}
      end
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

    api_key = get_api_key(config)

    if !api_key || api_key == "" do
      {:error, "Google API key not configured"}
    else
      model =
        Keyword.get(
          options,
          :model,
          Map.get(config, :model, ConfigHelper.ensure_default_model(:gemini))
        )

      # Convert messages to Gemini Content format
      request = build_content_request(messages, options)

      case ExLLM.Providers.Gemini.Content.stream_generate_content(model, request,
             config_provider: config_provider
           ) do
        {:ok, stream} ->
          # Convert the Content stream to ExLLM stream format
          converted_stream =
            Stream.map(stream, fn response ->
              convert_content_response_to_stream_chunk(response)
            end)

          {:ok, converted_stream}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @impl true
  def list_models(options \\ []) do
    # Use the new Models API module
    case ExLLM.Providers.Gemini.Models.list_models(options) do
      {:ok, response} ->
        # Convert from Models API format to ExLLM Types.Model format
        models =
          response[:models]
          |> Enum.filter(&is_gemini_chat_model_struct?/1)
          |> Enum.map(&convert_api_model_to_types/1)
          |> Enum.sort_by(& &1.id)

        {:ok, models}

      {:error, _reason} ->
        # Fallback to config-based models if API fails
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

        _config = get_config(config_provider)

        # Use ModelLoader with config only
        ExLLM.Infrastructure.Config.ModelLoader.load_models(
          :gemini,
          Keyword.merge(options,
            api_fetcher: fn _opts -> {:ok, []} end,
            config_transformer: &gemini_model_transformer/2
          )
        )
    end
  end

  defp is_gemini_chat_model_struct?(%ExLLM.Providers.Gemini.Models.Model{} = model) do
    # Filter for Gemini chat models from API struct
    String.starts_with?(model.name, "models/gemini")
  end

  defp convert_api_model_to_types(%ExLLM.Providers.Gemini.Models.Model{} = api_model) do
    # Convert from Gemini Models API format to ExLLM Types.Model format
    model_id = String.replace_prefix(api_model.name, "models/", "")

    %Types.Model{
      id: model_id,
      name: api_model.display_name,
      description: api_model.description,
      context_window: api_model.input_token_limit,
      max_output_tokens: api_model.output_token_limit,
      capabilities: %{
        supports_streaming: "streamGenerateContent" in api_model.supported_generation_methods,
        supports_functions: "generateContent" in api_model.supported_generation_methods,
        supports_vision:
          String.contains?(model_id, "vision") ||
            String.contains?(model_id, "gemini-1.5") ||
            String.contains?(model_id, "gemini-2"),
        features: parse_features_from_methods(api_model.supported_generation_methods)
      }
    }
  end

  defp parse_features_from_methods(methods) do
    features = []
    features = if "streamGenerateContent" in methods, do: [:streaming | features], else: features
    features = if "generateContent" in methods, do: [:chat | features], else: features
    features
  end

  # Transform config data to Gemini model format
  defp gemini_model_transformer(model_id, config) do
    %Types.Model{
      id: to_string(model_id),
      name: Map.get(config, :name, ModelUtils.format_model_name(to_string(model_id))),
      description: Map.get(config, :description),
      context_window: Map.get(config, :context_window, 1_048_576),
      capabilities: %{
        supports_streaming: :streaming in Map.get(config, :capabilities, []),
        supports_functions: :function_calling in Map.get(config, :capabilities, []),
        supports_vision: :vision in Map.get(config, :capabilities, []),
        features: Map.get(config, :capabilities, [])
      }
    }
  end

  # Model name formatting moved to shared ModelUtils module

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
    api_key = get_api_key(config)
    !is_nil(api_key) && api_key != ""
  end

  @impl true
  def default_model do
    ConfigHelper.ensure_default_model(:gemini)
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
    api_key = get_api_key(config)

    if !api_key || api_key == "" do
      {:error, "Google API key not configured"}
    else
      model =
        Keyword.get(
          options,
          :model,
          Map.get(config, :embedding_model, "text-embedding-004")
        )

      # Use Gemini Embeddings API - for single text, use embed_text helper
      case inputs do
        [single_text] when is_binary(single_text) ->
          # Single text embedding - pass all options through
          case ExLLM.Providers.Gemini.Embeddings.embed_text(model, single_text, options) do
            {:ok, embedding} ->
              # Convert from Gemini format to ExLLM format - embeddings should be list(list(float()))
              {:ok,
               %Types.EmbeddingResponse{
                 embeddings: [embedding.values],
                 model: model,
                 usage: %{
                   # Estimate, Gemini doesn't provide token counts
                   total_tokens: 100
                 }
               }}

            {:error, error} ->
              {:error, error}
          end

        multiple_texts when is_list(multiple_texts) ->
          # Multiple text embeddings - pass all options through
          case ExLLM.Providers.Gemini.Embeddings.embed_texts(model, multiple_texts, options) do
            {:ok, embeddings} ->
              # Convert from Gemini format to ExLLM format - embeddings should be list(list(float()))
              embedding_vectors = Enum.map(embeddings, & &1.values)

              {:ok,
               %Types.EmbeddingResponse{
                 embeddings: embedding_vectors,
                 model: model,
                 usage: %{
                   # Estimate, Gemini doesn't provide token counts
                   total_tokens: length(multiple_texts) * 100
                 }
               }}

            {:error, error} ->
              {:error, error}
          end

        _ ->
          {:error, "inputs must be a list of strings"}
      end
    end
  end

  @doc """
  Generates embeddings for multiple texts in batch.

  ## Parameters
    * `texts` - List of strings to embed
    * `options` - Options including `:model`, `:task_type`, `:title`, `:output_dimensionality`
  """
  def batch_embed_contents(texts, options \\ [])

  def batch_embed_contents(texts, options) when is_list(texts) do
    embeddings(texts, options)
  end

  @doc """
  Gets information about a specific model.

  ## Parameters
    * `model_name` - The model name (e.g., "gemini-2.0-flash")
    * `options` - Options including `:config_provider`
  """
  def get_model(model_name, options \\ []) do
    case ExLLM.Providers.Gemini.Models.get_model(model_name, options) do
      {:ok, api_model} ->
        # Convert from Gemini Models API format to ExLLM Types.Model format
        model_id = String.replace_prefix(api_model.name, "models/", "")

        types_model = %Types.Model{
          id: model_id,
          name: api_model.display_name,
          description: api_model.description,
          context_window: api_model.input_token_limit,
          max_output_tokens: api_model.output_token_limit,
          capabilities: %{
            supports_streaming: "streamGenerateContent" in api_model.supported_generation_methods,
            supports_functions: "generateContent" in api_model.supported_generation_methods,
            supports_vision:
              String.contains?(model_id, "vision") ||
                String.contains?(model_id, "gemini-1.5") ||
                String.contains?(model_id, "gemini-2"),
            features: parse_features_from_methods(api_model.supported_generation_methods)
          }
        }

        {:ok, types_model}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Counts tokens using a generateContentRequest format.

  ## Parameters
    * `request` - A map in generateContentRequest format
    * `options` - Options including `:config_provider`
  """
  def count_tokens_with_request(request, options \\ []) do
    # Extract model from request
    model = Map.get(request, "model", "gemini-2.0-flash-exp")

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

    # Convert plain map to GenerateContentRequest struct if needed
    generate_content_request =
      case request do
        %GenerateContentRequest{} ->
          request

        map when is_map(map) ->
          # Convert plain map to struct
          contents =
            Map.get(map, "contents", [])
            |> Enum.map(fn content_map ->
              %Content{
                role: Map.get(content_map, "role", "user"),
                parts:
                  Map.get(content_map, "parts", [])
                  |> Enum.map(fn part ->
                    %Part{
                      text: Map.get(part, "text"),
                      inline_data: Map.get(part, "inlineData"),
                      function_call: Map.get(part, "functionCall"),
                      function_response: Map.get(part, "functionResponse"),
                      code_execution_result: Map.get(part, "codeExecutionResult")
                    }
                  end)
              }
            end)

          # Build generation config if present
          generation_config =
            case Map.get(map, "generationConfig") do
              nil ->
                nil

              gc_map ->
                %GenerationConfig{
                  temperature: Map.get(gc_map, "temperature"),
                  top_p: Map.get(gc_map, "topP"),
                  top_k: Map.get(gc_map, "topK"),
                  max_output_tokens: Map.get(gc_map, "maxOutputTokens"),
                  stop_sequences: Map.get(gc_map, "stopSequences"),
                  response_mime_type: Map.get(gc_map, "responseMimeType"),
                  response_schema: Map.get(gc_map, "responseSchema"),
                  thinking_config: Map.get(gc_map, "thinkingConfig")
                }
            end

          # Build safety settings if present
          safety_settings =
            case Map.get(map, "safetySettings") do
              nil ->
                nil

              settings ->
                Enum.map(settings, fn setting ->
                  %SafetySetting{
                    category: Map.get(setting, "category"),
                    threshold: Map.get(setting, "threshold")
                  }
                end)
            end

          %GenerateContentRequest{
            # Let the Tokens module handle model normalization
            model: nil,
            contents: contents,
            generation_config: generation_config,
            safety_settings: safety_settings
          }
      end

    # Create CountTokensRequest struct with generateContentRequest
    count_request = %ExLLM.Providers.Gemini.Tokens.CountTokensRequest{
      generate_content_request: generate_content_request
    }

    case ExLLM.Providers.Gemini.Tokens.count_tokens(model, count_request,
           config_provider: config_provider
         ) do
      {:ok, result} ->
        # Convert response to expected format for tests
        {:ok,
         %{
           "totalTokens" => result.total_tokens,
           "cachedContentTokenCount" => result.cached_content_token_count
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Counts tokens for the given messages.

  ## Parameters
    * `messages` - List of messages to count tokens for
    * `model` - The model name (e.g., "gemini-2.0-flash")
    * `options` - Options including `:config_provider`
  """
  def count_tokens(messages, model, options \\ []) do
    # Convert messages to Gemini Content format
    contents = Enum.map(messages, &convert_message_to_content/1)

    # Create count tokens request
    request = %ExLLM.Providers.Gemini.Tokens.CountTokensRequest{
      contents: contents
    }

    case ExLLM.Providers.Gemini.Tokens.count_tokens(model, request, options) do
      {:ok, response} ->
        # Convert to simple map format expected by tests
        {:ok,
         %{
           "totalTokens" => response.total_tokens,
           "cachedContentTokenCount" => response.cached_content_token_count
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Lists files owned by the requesting project.

  ## Parameters
    * `options` - Options including `:page_size`, `:page_token`, and `:config_provider`
  """
  def list_files(options \\ []) do
    case ExLLM.Providers.Gemini.Files.list_files(options) do
      {:ok, response} ->
        # Convert to simple map format expected by tests
        {:ok,
         %{
           "files" => Enum.map(response.files, &file_to_map/1),
           "nextPageToken" => response.next_page_token
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Creates (uploads) a file.

  ## Parameters
    * `file_content` - Binary content of the file
    * `display_name` - Display name for the file
    * `options` - Options including `:config_provider`
  """
  def create_file(file_content, display_name, options \\ []) do
    # Create a temporary file
    temp_path = Path.join(System.tmp_dir(), "gemini_upload_#{System.unique_integer()}")

    try do
      File.write!(temp_path, file_content)

      upload_options = Keyword.put(options, :display_name, display_name)

      case ExLLM.Providers.Gemini.Files.upload_file(temp_path, upload_options) do
        {:ok, file} ->
          {:ok, file_to_map(file)}

        {:error, error} ->
          {:error, error}
      end
    after
      File.rm(temp_path)
    end
  end

  @doc """
  Gets metadata for a specific file.

  ## Parameters
    * `file_name` - The file name (e.g., "files/abc-123")
    * `options` - Options including `:config_provider`
  """
  def get_file(file_name, options \\ []) do
    case ExLLM.Providers.Gemini.Files.get_file(file_name, options) do
      {:ok, file} ->
        {:ok, file_to_map(file)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Deletes a file.

  ## Parameters
    * `file_name` - The file name (e.g., "files/abc-123")
    * `options` - Options including `:config_provider`
  """
  def delete_file(file_name, options \\ []) do
    case ExLLM.Providers.Gemini.Files.delete_file(file_name, options) do
      :ok ->
        {:ok, %{}}

      {:error, error} ->
        {:error, error}
    end
  end

  # Context Caching API placeholder functions
  @doc """
  Lists cached contents (placeholder - not yet implemented).
  """
  def list_cached_contents(_options \\ []) do
    {:error, {:function_not_implemented, "Context Caching API not yet implemented"}}
  end

  @doc """
  Creates cached content (placeholder - not yet implemented).
  """
  def create_cached_content(_content, _model, _options \\ []) do
    {:error, {:function_not_implemented, "Context Caching API not yet implemented"}}
  end

  @doc """
  Gets cached content (placeholder - not yet implemented).
  """
  def get_cached_content(_cached_name, _options \\ []) do
    {:error, {:function_not_implemented, "Context Caching API not yet implemented"}}
  end

  @doc """
  Deletes cached content (placeholder - not yet implemented).
  """
  def delete_cached_content(_cached_name, _options \\ []) do
    {:error, {:function_not_implemented, "Context Caching API not yet implemented"}}
  end

  @doc """
  Lists tuned models (placeholder - not yet implemented).
  """
  def list_tuned_models(_options \\ []) do
    {:error, {:function_not_implemented, "Tuned Models API not yet implemented"}}
  end

  # Semantic Retrieval API placeholder functions
  @doc """
  Lists corpora (placeholder - not yet implemented).
  """
  def list_corpora(_options \\ []) do
    {:error, {:function_not_implemented, "Semantic Retrieval API not yet implemented"}}
  end

  @doc """
  Creates a corpus (placeholder - not yet implemented).
  """
  def create_corpus(_corpus_name, _options \\ []) do
    {:error, {:function_not_implemented, "Semantic Retrieval API not yet implemented"}}
  end

  @doc """
  Gets a corpus (placeholder - not yet implemented).
  """
  def get_corpus(_corpus_id, _options \\ []) do
    {:error, {:function_not_implemented, "Semantic Retrieval API not yet implemented"}}
  end

  @doc """
  Deletes a corpus (placeholder - not yet implemented).
  """
  def delete_corpus(_corpus_id, _options \\ []) do
    {:error, {:function_not_implemented, "Semantic Retrieval API not yet implemented"}}
  end

  # Default model fetching moved to shared ConfigHelper module

  # Private functions

  defp get_config(config_provider) do
    case config_provider do
      provider when is_atom(provider) ->
        provider.get_all(:gemini)

      provider when is_pid(provider) ->
        ExLLM.Infrastructure.ConfigProvider.Static.get_all(provider)
        |> Map.get(:gemini, %{})
    end
  end

  defp get_api_key(config) do
    Map.get(config, :api_key) || System.get_env("GOOGLE_API_KEY") ||
      System.get_env("GEMINI_API_KEY")
  end

  # New helper functions for Content API integration
  defp build_content_request(messages, options) do
    contents = Enum.map(messages, &convert_message_to_content/1)

    # Extract system instruction if present
    {system_instruction, contents} = extract_system_instruction(contents)

    %GenerateContentRequest{
      contents: contents,
      system_instruction: system_instruction,
      generation_config: build_generation_config(options),
      safety_settings: build_safety_settings(options),
      tools: build_tools(options)
    }
  end

  defp convert_message_to_content(%{role: role, content: content}) do
    %Content{
      role: convert_role(role),
      parts: [%Part{text: content}]
    }
  end

  defp convert_message_to_content(message) when is_map(message) do
    role = Map.get(message, "role", "user")
    content = Map.get(message, "content", "")

    %Content{
      role: convert_role(role),
      parts: [%Part{text: content}]
    }
  end

  # Gemini doesn't have system role
  defp convert_role("system"), do: "user"
  defp convert_role("assistant"), do: "model"
  defp convert_role(role), do: to_string(role)

  defp extract_system_instruction(contents) do
    # Filter contents with the "system" role
    system_contents = contents |> Enum.filter(fn content -> content.role == "system" end)
    
    case system_contents do
      [] -> 
        {nil, contents}
      system_messages ->
        # Flatten and filter parts
        system_parts = system_messages |> Enum.flat_map(& &1.parts)
        
        # Map and join the system instruction text  
        system_text = system_parts |> Enum.map(& &1.text) |> Enum.join(" ")
        
        system_instruction = %Content{role: "system", parts: [%Part{text: system_text}]}
        remaining_contents = contents |> Enum.reject(fn content -> content.role == "system" end)
        
        {system_instruction, remaining_contents}
    end
  end

  defp build_generation_config(options) do
    base_config = %{
      temperature: Keyword.get(options, :temperature),
      top_p: Keyword.get(options, :top_p),
      top_k: Keyword.get(options, :top_k),
      max_output_tokens: Keyword.get(options, :max_tokens),
      stop_sequences: Keyword.get(options, :stop_sequences),
      response_mime_type: Keyword.get(options, :response_mime_type)
    }

    # Add advanced generation features
    advanced_config =
      base_config
      |> maybe_add_field(:response_modalities, Keyword.get(options, :response_modalities))
      |> maybe_add_field(:speech_config, Keyword.get(options, :speech_config))
      |> maybe_add_field(:thinking_config, Keyword.get(options, :thinking_config))

    # Convert to GenerationConfig struct if any fields are set
    if Enum.any?(advanced_config, fn {_k, v} -> v != nil end) do
      struct(GenerationConfig, advanced_config)
    else
      nil
    end
  end

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  defp build_safety_settings(options) do
    case Keyword.get(options, :safety_settings) do
      nil ->
        nil

      settings ->
        Enum.map(settings, fn setting ->
          %SafetySetting{
            category: setting[:category] || setting["category"],
            threshold: setting[:threshold] || setting["threshold"]
          }
        end)
    end
  end

  defp build_tools(options) do
    case Keyword.get(options, :tools) do
      nil ->
        nil

      tools ->
        # Handle both formats:
        # 1. Direct function list (from tests)
        # 2. Tool struct with function_declarations
        tools
        |> List.wrap()
        |> Enum.map(&convert_tool/1)
    end
  end

  defp convert_tool(tool) when is_map(tool) do
    cond do
      # If it already has function_declarations, use as is
      Map.has_key?(tool, :function_declarations) or Map.has_key?(tool, "function_declarations") ->
        %Tool{
          function_declarations: tool[:function_declarations] || tool["function_declarations"]
        }

      # If it looks like a function definition (has name, description, parameters)
      Map.has_key?(tool, "name") or Map.has_key?(tool, :name) ->
        %Tool{
          function_declarations: [tool]
        }

      # Otherwise assume it's a tool with function declarations
      true ->
        %Tool{
          function_declarations: []
        }
    end
  end

  defp convert_content_response_to_llm_response(%GenerateContentResponse{} = response, model) do
    case response.candidates do
      [candidate | _] ->
        content = extract_text_from_candidate(candidate)

        # Get usage data
        usage =
          if response.usage_metadata do
            %{
              input_tokens: response.usage_metadata.prompt_token_count,
              output_tokens: response.usage_metadata.candidates_token_count,
              total_tokens: response.usage_metadata.total_token_count
            }
          else
            # Estimate if not provided
            %{
              input_tokens: 100,
              output_tokens: ExLLM.Core.Cost.estimate_tokens(content),
              total_tokens: 100 + ExLLM.Core.Cost.estimate_tokens(content)
            }
          end

        # Check for function calls in the candidate
        tool_calls = extract_tool_calls_from_candidate(candidate)

        # Check for audio content
        audio_content = extract_audio_from_candidate(candidate)

        response = %Types.LLMResponse{
          content: content,
          usage: usage,
          model: model,
          finish_reason: candidate.finish_reason || "stop",
          cost: ExLLM.Core.Cost.calculate("gemini", model, usage),
          tool_calls: tool_calls
        }

        # Add audio_content if present
        response =
          if audio_content do
            Map.put(response, :audio_content, audio_content)
          else
            response
          end

        # Add safety_ratings if present
        response =
          if candidate.safety_ratings do
            Map.put(response, :safety_ratings, candidate.safety_ratings)
          else
            response
          end

        {:ok, response}

      [] ->
        # Check if blocked
        if response.prompt_feedback && response.prompt_feedback["blockReason"] do
          {:error, "Response blocked: #{response.prompt_feedback["blockReason"]}"}
        else
          {:error, "No candidates returned"}
        end
    end
  end

  defp extract_text_from_candidate(candidate) do
    candidate.content.parts
    |> Enum.map(fn part -> part.text || "" end)
    |> Enum.join("")
  end

  defp extract_tool_calls_from_candidate(candidate) do
    # Check if any parts contain function calls
    function_calls =
      candidate.content.parts
      |> Enum.filter(fn part ->
        Map.has_key?(part, :function_call) && part.function_call != nil
      end)
      |> Enum.map(fn part ->
        fc = part.function_call
        # Function call is a map with string keys
        %{
          # Gemini doesn't provide IDs, use name
          id: Map.get(fc, "name", "unknown"),
          type: "function",
          function: %{
            name: Map.get(fc, "name", "unknown"),
            arguments: Map.get(fc, "args", %{})
          }
        }
      end)

    if Enum.empty?(function_calls), do: nil, else: function_calls
  end

  defp extract_audio_from_candidate(candidate) do
    # Check if any parts contain audio data
    audio_parts =
      candidate.content.parts
      |> Enum.filter(fn part ->
        Map.has_key?(part, :inline_data) &&
          part.inline_data != nil &&
          Map.get(part.inline_data, :mime_type, "") =~ "audio"
      end)
      |> Enum.map(fn part -> Map.get(part.inline_data, :data) end)

    case audio_parts do
      [] -> nil
      # Return first audio part
      [audio | _] -> audio
    end
  end

  defp convert_content_response_to_stream_chunk(%GenerateContentResponse{} = response) do
    case response.candidates do
      [candidate | _] ->
        text = extract_text_from_candidate(candidate)

        %Types.StreamChunk{
          content: text,
          finish_reason: candidate.finish_reason
        }

      [] ->
        %Types.StreamChunk{
          content: "",
          finish_reason: "stop"
        }
    end
  end

  # Helper function to convert File struct to map for tests
  defp file_to_map(%ExLLM.Providers.Gemini.Files.File{} = file) do
    %{
      "name" => file.name,
      "displayName" => file.display_name,
      "mimeType" => file.mime_type,
      "sizeBytes" => file.size_bytes,
      "createTime" => datetime_to_string(file.create_time),
      "updateTime" => datetime_to_string(file.update_time),
      "expirationTime" => datetime_to_string(file.expiration_time),
      "sha256Hash" => file.sha256_hash,
      "uri" => file.uri,
      "downloadUri" => file.download_uri,
      "state" => atom_to_state_string(file.state),
      "source" => atom_to_source_string(file.source)
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp atom_to_state_string(:state_unspecified), do: "STATE_UNSPECIFIED"
  defp atom_to_state_string(:processing), do: "PROCESSING"
  defp atom_to_state_string(:active), do: "ACTIVE"
  defp atom_to_state_string(:failed), do: "FAILED"
  defp atom_to_state_string(other), do: to_string(other)

  defp atom_to_source_string(nil), do: nil
  defp atom_to_source_string(:source_unspecified), do: "SOURCE_UNSPECIFIED"
  defp atom_to_source_string(:uploaded), do: "UPLOADED"
  defp atom_to_source_string(:generated), do: "GENERATED"
  defp atom_to_source_string(other), do: to_string(other)

  # Semantic Retrieval APIs

  @doc """
  Performs semantic search over a corpus.

  ## Parameters
    * `corpus_name` - The corpus name (e.g., "corpora/my-corpus-123")
    * `query` - The search query
    * `options` - Options including `:max_results`, `:metadata_filters`, `:oauth_token`
  """
  def query_corpus(_corpus_name, _query, _options \\ []) do
    # TODO: Implement corpora.query API
    {:error, {:function_not_implemented, "query_corpus/3 not yet implemented"}}
  end

  @doc """
  Performs semantic search within a specific document.

  ## Parameters
    * `document_name` - The document name (e.g., "corpora/my-corpus/documents/my-doc")
    * `query` - The search query
    * `options` - Options including `:max_results`, `:metadata_filters`, `:oauth_token`
  """
  def query_document(_document_name, _query, _options \\ []) do
    # TODO: Implement documents.query API
    {:error, {:function_not_implemented, "query_document/3 not yet implemented"}}
  end

  # Question Answering API

  @doc """
  Generates a grounded answer from inline passages or semantic retriever.

  ## Parameters
    * `question` - The question to answer
    * `passages` - List of passage maps with "id" and "content" keys
    * `answer_style` - Answer style: "ABSTRACTIVE", "EXTRACTIVE", or "VERBOSE"
    * `options` - Options including `:model`, `:temperature`, `:safety_settings`
  """
  def generate_answer(_question, _passages, _answer_style, _options \\ []) do
    # TODO: Implement models.generateAnswer API
    {:error, {:function_not_implemented, "generate_answer/4 not yet implemented"}}
  end

  # Tuned Models APIs

  @doc """
  Creates a new tuned model.

  ## Parameters
    * `config` - Tuning configuration including base model, training data, etc.
    * `options` - Options including `:oauth_token`
  """
  def create_tuned_model(_config, _options \\ []) do
    # TODO: Implement tunedModels.create API
    {:error, {:function_not_implemented, "create_tuned_model/2 not yet implemented"}}
  end

  @doc """
  Transfers ownership of a tuned model to another user.

  ## Parameters
    * `model_name` - The tuned model name
    * `new_owner_email` - Email address of the new owner
    * `options` - Options including `:oauth_token`
  """
  def transfer_tuned_model_ownership(_model_name, _new_owner_email, _options \\ []) do
    # TODO: Implement tunedModels.transferOwnership API
    {:error, {:function_not_implemented, "transfer_tuned_model_ownership/3 not yet implemented"}}
  end

  # Batch Operations

  @doc """
  Creates multiple chunks in batch.

  ## Parameters
    * `document_name` - The document name
    * `chunks` - List of chunk data
    * `options` - Options including `:oauth_token`
  """
  def batch_create_chunks(_document_name, _chunks, _options \\ []) do
    # TODO: Implement chunks.batchCreate API
    {:error, {:function_not_implemented, "batch_create_chunks/3 not yet implemented"}}
  end
end
