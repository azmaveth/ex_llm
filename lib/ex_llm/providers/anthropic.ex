defmodule ExLLM.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude API adapter for ExLLM.

  ## Configuration

  This adapter requires an Anthropic API key and optionally a base URL.

  ### Using Environment Variables

      # Set environment variables
      export ANTHROPIC_API_KEY="your-api-key"
      export ANTHROPIC_MODEL="claude-3-5-sonnet-20241022"  # optional

      # Use with default environment provider
      ExLLM.Providers.Anthropic.chat(messages, config_provider: ExLLM.Infrastructure.ConfigProvider.Env)

  ### Using Static Configuration

      config = %{
        anthropic: %{
          api_key: "your-api-key",
          model: "claude-3-5-sonnet-20241022",
          base_url: "https://api.anthropic.com"  # optional
        }
      }
      {:ok, provider} = ExLLM.Infrastructure.ConfigProvider.Static.start_link(config)
      ExLLM.Providers.Anthropic.chat(messages, config_provider: provider)

  ## Example Usage

      messages = [
        %{role: "user", content: "Hello, how are you?"}
      ]

      # Simple chat
      {:ok, response} = ExLLM.Providers.Anthropic.chat(messages)
      IO.puts(response.content)

      # Streaming chat
      {:ok, stream} = ExLLM.Providers.Anthropic.stream_chat(messages)
      for chunk <- stream do
        if chunk.content, do: IO.write(chunk.content)
      end
  """

  @behaviour ExLLM.Provider
  @behaviour ExLLM.Providers.Shared.StreamingBehavior

  alias ExLLM.Types

  alias ExLLM.Providers.Shared.{
    ConfigHelper,
    EnhancedStreamingCoordinator,
    ErrorHandler,
    MessageFormatter,
    StreamingBehavior,
    Validation
  }

  alias ExLLM.Providers.Shared.HTTP.Core

  import ExLLM.Providers.OpenAICompatible,
    only: [format_model_name: 1, default_model_transformer: 2]

  @default_base_url "https://api.anthropic.com"

  @impl true
  def chat(messages, options \\ []) do
    with :ok <- MessageFormatter.validate_messages(messages),
         config_provider <- ConfigHelper.get_config_provider(options),
         config <- ConfigHelper.get_config(:anthropic, config_provider),
         api_key <- ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY"),
         {:ok, _} <- Validation.validate_api_key(api_key) do
      model =
        Keyword.get(
          options,
          :model,
          Map.get(config, :model) || ConfigHelper.ensure_default_model(:anthropic)
        )

      body = build_request_body(messages, model, config, options)
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages"

      case anthropic_request(:post, url, body, headers, api_key, timeout: 60_000) do
        {:ok, response_body} ->
          {:ok, parse_response(response_body)}

        {:error, {:api_error, %{status: status, body: body}}} ->
          ErrorHandler.handle_provider_error(:anthropic, status, body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def stream_chat(messages, options \\ []) do
    with :ok <- MessageFormatter.validate_messages(messages),
         config_provider <- ConfigHelper.get_config_provider(options),
         config <- ConfigHelper.get_config(:anthropic, config_provider),
         api_key <- ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY"),
         {:ok, _} <- Validation.validate_api_key(api_key) do
      model =
        Keyword.get(
          options,
          :model,
          Map.get(config, :model) || ConfigHelper.ensure_default_model(:anthropic)
        )

      body =
        messages
        |> build_request_body(model, config, options)
        |> Map.put(:stream, true)

      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages"

      # Create stream with enhanced features
      chunks_ref = make_ref()
      parent = self()

      # Setup callback that sends chunks to parent
      callback = fn chunk ->
        send(parent, {chunks_ref, {:chunk, chunk}})
      end

      # Enhanced streaming options with Anthropic-specific features
      stream_options = [
        parse_chunk_fn: &parse_anthropic_chunk/1,
        provider: :anthropic,
        model: model,
        stream_recovery: Keyword.get(options, :stream_recovery, false),
        track_metrics: Keyword.get(options, :track_metrics, false),
        on_metrics: Keyword.get(options, :on_metrics),
        transform_chunk: create_anthropic_transformer(options),
        validate_chunk: create_anthropic_validator(options),
        buffer_chunks: Keyword.get(options, :buffer_chunks, 1),
        timeout: Keyword.get(options, :timeout, 300_000),
        # Enable enhanced features if requested
        enable_flow_control: Keyword.get(options, :enable_flow_control, false),
        enable_batching: Keyword.get(options, :enable_batching, false),
        track_detailed_metrics: Keyword.get(options, :track_detailed_metrics, false)
      ]

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
              5000 -> {[], state}
            end
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    end
  end

  @impl true
  def configured?(options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")
    !is_nil(api_key) && api_key != ""
  end

  @impl true
  def default_model, do: ConfigHelper.ensure_default_model(:anthropic)

  # Default model fetching moved to shared ConfigHelper module

  @impl true
  def list_models(options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)

    # Use ModelLoader with API fetching
    ExLLM.Infrastructure.Config.ModelLoader.load_models(
      :anthropic,
      Keyword.merge(options,
        api_fetcher: fn _opts -> fetch_anthropic_models(config) end,
        config_transformer: &anthropic_model_transformer/2
      )
    )
  end

  defp fetch_anthropic_models(config) do
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    case Validation.validate_api_key(api_key) do
      {:error, _} = error ->
        error

      {:ok, _} ->
        headers = build_headers(api_key)

        url = "#{get_base_url(config)}/v1/models"

        case anthropic_request(:get, url, %{}, headers, api_key) do
          {:ok, %{"data" => models}} ->
            parsed_models =
              models
              |> Enum.map(&parse_anthropic_model/1)
              |> Enum.sort_by(& &1.id)

            {:ok, parsed_models}

          {:error, reason} when is_map(reason) ->
            # Try to extract error details from response
            ErrorHandler.handle_provider_error(:anthropic, 400, reason)

          {:error, reason} ->
            {:error, "Network error: #{inspect(reason)}"}
        end
    end
  end

  defp parse_anthropic_model(model) do
    %Types.Model{
      id: model["id"],
      name: format_model_name(model["id"]),
      description: generate_anthropic_description(model["id"]),
      context_window: model["context_length"] || 200_000,
      capabilities: %{
        supports_streaming: true,
        supports_functions: model["supports_tools"] || false,
        supports_vision: model["supports_vision"] || false,
        features: build_anthropic_capabilities(model)
      }
    }
  end

  defp build_anthropic_capabilities(model) do
    capabilities = ["streaming"]

    capabilities =
      if model["supports_tools"], do: ["function_calling" | capabilities], else: capabilities

    capabilities = if model["supports_vision"], do: ["vision" | capabilities], else: capabilities

    capabilities =
      if Map.get(model, "supports_system_messages", true),
        do: ["system_messages" | capabilities],
        else: capabilities

    capabilities
  end

  # Transform config data to Anthropic model format
  defp anthropic_model_transformer(model_id, config) do
    # Use base transformer but override description
    base_model = default_model_transformer(model_id, config)

    %{
      base_model
      | description:
          Map.get(config, :description, generate_anthropic_description(to_string(model_id))),
        context_window: Map.get(config, :context_window, 200_000)
    }
  end

  defp generate_anthropic_description(model_id) do
    cond do
      String.contains?(model_id, "opus-4") -> "Claude Opus 4: Most intelligent model"
      String.contains?(model_id, "sonnet-4") -> "Claude Sonnet 4: Best value model"
      String.contains?(model_id, "opus") -> "Most capable model with advanced reasoning"
      String.contains?(model_id, "sonnet") -> "Balanced model for general tasks"
      String.contains?(model_id, "haiku") -> "Fast and efficient model for simple tasks"
      true -> "Claude model"
    end
  end

  # Streaming behavior callback
  @impl ExLLM.Providers.Shared.StreamingBehavior
  def parse_stream_chunk(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => "message_stop"}} ->
        {:ok, :done}

      {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
        chunk = StreamingBehavior.create_text_chunk(text)
        {:ok, chunk}

      {:ok, %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}}} ->
        chunk = StreamingBehavior.create_text_chunk("", finish_reason: reason)
        {:ok, chunk}

      {:ok, _} ->
        # Other event types we don't need to handle
        {:ok, StreamingBehavior.create_text_chunk("")}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  # Parse function for StreamingCoordinator (returns Types.StreamChunk directly)
  defp parse_anthropic_chunk(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => "message_stop"}} ->
        # StreamingCoordinator handles completion
        nil

      {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
        %Types.StreamChunk{
          content: text,
          finish_reason: nil
        }

      {:ok, %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}}} ->
        %Types.StreamChunk{
          content: "",
          finish_reason: reason
        }

      {:ok, _} ->
        # Other event types we don't need to handle
        nil

      {:error, _} ->
        nil
    end
  end

  # StreamingCoordinator enhancement functions

  defp create_anthropic_transformer(options) do
    # Example: Add thinking annotations for reasoning chains
    if Keyword.get(options, :annotate_reasoning, false) do
      fn chunk ->
        if chunk.content && String.contains?(chunk.content, "thinking") do
          # Add reasoning markers
          annotated_content = "[Reasoning] #{chunk.content}"
          {:ok, %{chunk | content: annotated_content}}
        else
          {:ok, chunk}
        end
      end
    end
  end

  defp create_anthropic_validator(options) do
    # Validate response quality for Claude models
    if Keyword.get(options, :validate_quality, false) do
      &validate_chunk_quality/1
    end
  end

  defp validate_chunk_quality(chunk) do
    if chunk.content do
      validate_content_quality(chunk.content)
    else
      :ok
    end
  end

  defp validate_content_quality(content) do
    if String.length(content) > 0 && not String.match?(content, ~r/^\s*$/) do
      :ok
    else
      {:error, "Low quality content detected"}
    end
  end

  # Private functions

  # API key validation moved to shared Validation module

  defp build_request_body(messages, model, config, options) do
    # Extract system message if present
    {system_content, other_messages} = MessageFormatter.extract_system_message(messages)

    # Format messages for Anthropic
    formatted_messages = format_messages_for_anthropic(other_messages)

    body = %{
      model: model,
      messages: formatted_messages,
      max_tokens: Keyword.get(options, :max_tokens, Map.get(config, :max_tokens, 4096))
    }

    # Add system message if present
    body =
      if system_content do
        Map.put(body, :system, system_content)
      else
        body
      end

    # Add temperature if specified
    case Keyword.get(options, :temperature) do
      nil -> body
      temp -> Map.put(body, :temperature, temp)
    end
  end

  defp build_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]
  end

  defp get_base_url(config) do
    Map.get(config, :base_url) || @default_base_url
  end

  defp format_messages_for_anthropic(messages) do
    # Anthropic expects alternating user/assistant messages
    # System messages should be extracted and sent separately
    messages
    |> Enum.reject(fn msg -> msg.role == "system" end)
    |> Enum.map(fn msg ->
      formatted_content = format_content_for_anthropic(msg.content)

      %{
        role: msg.role,
        content: formatted_content
      }
    end)
  end

  defp format_content_for_anthropic(content) when is_binary(content) do
    # Simple text content
    content
  end

  defp format_content_for_anthropic(content) when is_list(content) do
    # Multimodal content with text and images
    Enum.map(content, fn part ->
      case part do
        %{"type" => "text", "text" => text} ->
          %{type: "text", text: text}

        %{type: "text", text: text} ->
          %{type: "text", text: text}

        %{"type" => "image", "image" => image_data} ->
          format_image_for_anthropic(image_data)

        %{type: "image", image: image_data} ->
          format_image_for_anthropic(image_data)

        %{"type" => "image_url", "image_url" => %{"url" => _url}} ->
          # For URLs, we might need to download and convert to base64
          # For now, return an error as Anthropic prefers base64
          %{
            type: "image",
            source: %{
              type: "base64",
              media_type: "image/jpeg",
              data: "placeholder_for_url_download"
            }
          }

        _ ->
          part
      end
    end)
  end

  defp format_image_for_anthropic(%{"data" => data, "media_type" => media_type}) do
    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: media_type,
        data: data
      }
    }
  end

  defp format_image_for_anthropic(%{data: data, media_type: media_type}) do
    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: media_type,
        data: data
      }
    }
  end

  defp parse_response(response) do
    content =
      response["content"]
      |> List.first()
      |> Map.get("text", "")

    usage =
      case response["usage"] do
        nil ->
          nil

        usage_map ->
          %{
            input_tokens: Map.get(usage_map, "input_tokens", 0),
            output_tokens: Map.get(usage_map, "output_tokens", 0)
          }
      end

    # Calculate cost if we have usage data
    cost =
      if usage && response["model"] do
        ExLLM.Core.Cost.calculate("anthropic", response["model"], usage)
      else
        nil
      end

    %Types.LLMResponse{
      content: content,
      model: response["model"],
      usage: usage,
      finish_reason: response["stop_reason"],
      id: response["id"],
      cost: cost
    }
  end

  @doc """
  Generate embeddings for text (not yet supported by Anthropic).

  This function is a placeholder as Anthropic doesn't currently offer
  an embeddings API. It will return an error indicating lack of support.
  """
  @impl ExLLM.Provider
  @spec embeddings(list(String.t()), keyword()) :: {:error, term()}
  def embeddings(_inputs, _options \\ []) do
    {:error, {:embeddings_not_supported, :anthropic}}
  end

  # Files API (Beta)

  @doc """
  Upload a file to Anthropic's Files API.

  Requires the beta header: anthropic-beta: files-api-2025-04-14
  """
  def create_file(file_content, filename, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_files_headers(api_key)
      url = "#{get_base_url(config)}/v1/files"

      # Create multipart form data
      multipart = [
        {"file", {file_content, [filename: filename]}},
        {"purpose", "user_message"}
      ]

      case anthropic_request(:post_multipart, url, multipart, headers, api_key, timeout: 120_000) do
        {:ok, %{status: _status, body: response_body}} ->
          {:ok, response_body}

        {:error, {:api_error, %{status: status, body: body}}} ->
          ErrorHandler.handle_provider_error(:anthropic, status, body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List files in the workspace.
  """
  def list_files(options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_files_headers(api_key)
      url = "#{get_base_url(config)}/v1/files"

      case anthropic_request(:get, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get file metadata.
  """
  def get_file(file_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_files_headers(api_key)
      url = "#{get_base_url(config)}/v1/files/#{file_id}"

      case anthropic_request(:get, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Download file content.
  """
  def get_file_content(file_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_files_headers(api_key)
      url = "#{get_base_url(config)}/v1/files/#{file_id}/content"

      case anthropic_request(:get_binary, url, %{}, headers, api_key) do
        {:ok, content} when is_binary(content) ->
          {:ok, content}

        {:error, %{status_code: status, response: response}} ->
          ErrorHandler.handle_provider_error(:anthropic, status, response.body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Delete a file.
  """
  def delete_file(file_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_files_headers(api_key)
      url = "#{get_base_url(config)}/v1/files/#{file_id}"

      case anthropic_request(:delete, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Message Batches API

  @doc """
  Create a message batch.
  """
  def create_message_batch(requests, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key),
         {:ok, validated_requests} <- validate_batch_requests(requests) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/batches"

      body = %{
        requests: validated_requests
      }

      case anthropic_request(:post, url, body, headers, api_key, timeout: 120_000) do
        {:ok, response_body} ->
          {:ok, response_body}

        {:error, {:api_error, %{status: status, body: body}}} ->
          ErrorHandler.handle_provider_error(:anthropic, status, body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List message batches.
  """
  def list_message_batches(options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/batches"

      case anthropic_request(:get, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get message batch details.
  """
  def get_message_batch(batch_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/batches/#{batch_id}"

      case anthropic_request(:get, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get message batch results.
  """
  def get_message_batch_results(batch_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/batches/#{batch_id}/results"

      case anthropic_request(:get, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Cancel a message batch.
  """
  def cancel_message_batch(batch_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/batches/#{batch_id}/cancel"

      case anthropic_request(:post, url, %{}, headers, api_key, timeout: 60_000) do
        {:ok, response_body} ->
          {:ok, response_body}

        {:error, {:api_error, %{status: status, body: body}}} ->
          ErrorHandler.handle_provider_error(:anthropic, status, body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Delete a message batch.
  """
  def delete_message_batch(batch_id, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/batches/#{batch_id}"

      case anthropic_request(:delete, url, %{}, headers, api_key) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Token Counting API

  @doc """
  Count tokens in a message without creating it.
  """
  def count_tokens(messages, model, options \\ []) do
    config_provider = ConfigHelper.get_config_provider(options)
    config = ConfigHelper.get_config(:anthropic, config_provider)
    api_key = ConfigHelper.get_api_key(config, "ANTHROPIC_API_KEY")

    with :ok <- MessageFormatter.validate_messages(messages),
         {:ok, _} <- Validation.validate_api_key(api_key) do
      headers = build_headers(api_key)
      url = "#{get_base_url(config)}/v1/messages/count_tokens"

      # Extract system message if present
      {system_content, other_messages} = MessageFormatter.extract_system_message(messages)
      formatted_messages = format_messages_for_anthropic(other_messages)

      body = %{
        model: model,
        messages: formatted_messages
      }

      # Add system message if present
      body =
        if system_content do
          Map.put(body, :system, system_content)
        else
          body
        end

      case anthropic_request(:post, url, body, headers, api_key, timeout: 60_000) do
        {:ok, %{status: _status, body: response_body}} ->
          {:ok, response_body}

        {:error, {:api_error, %{status: status, body: body}}} ->
          ErrorHandler.handle_provider_error(:anthropic, status, body)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Private helper functions

  # HTTP client helper functions using HTTP.Core

  defp anthropic_request(method, url, body, headers, api_key, opts \\ []) do
    client = build_anthropic_client(url, api_key)
    path = get_path_from_url(url)
    timeout = Keyword.get(opts, :timeout, 60_000)

    result = execute_anthropic_request(client, method, path, body, headers, timeout)
    handle_anthropic_response(result, method)
  end

  defp build_anthropic_client(url, api_key) do
    client_opts = [
      provider: :anthropic,
      base_url: get_base_url_from_full_url(url)
    ]

    client_opts = if api_key, do: Keyword.put(client_opts, :api_key, api_key), else: client_opts
    Core.client(client_opts)
  end

  defp execute_anthropic_request(client, :get, path, _body, _headers, timeout) do
    Tesla.get(client, path, opts: [timeout: timeout])
  end

  defp execute_anthropic_request(client, :post, path, body, _headers, timeout) do
    Tesla.post(client, path, body, opts: [timeout: timeout])
  end

  defp execute_anthropic_request(client, :delete, path, _body, _headers, timeout) do
    Tesla.delete(client, path, opts: [timeout: timeout])
  end

  defp execute_anthropic_request(client, :post_multipart, path, body, headers, timeout) do
    Tesla.post(client, path, body, headers: headers, opts: [timeout: timeout])
  end

  defp execute_anthropic_request(client, :get_binary, path, _body, _headers, timeout) do
    Tesla.get(client, path, opts: [timeout: timeout])
  end

  defp handle_anthropic_response({:ok, env}, method) do
    case ExLLM.HTTP.handle_response(env) do
      {:ok, body} ->
        parsed_body = parse_anthropic_response_body(body, method)
        {:ok, parsed_body}

      {:error, _env} ->
        {status, body} = ExLLM.HTTP.get_error_info(env)
        {:error, {:api_error, %{status: status, body: body}}}
    end
  end

  defp handle_anthropic_response({:error, reason}, _method) do
    {:error, reason}
  end

  defp parse_anthropic_response_body(body, :get_binary), do: body

  defp parse_anthropic_response_body(body, _method) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      {:error, _} -> body
    end
  end

  defp parse_anthropic_response_body(body, _method), do: body

  # Helper to extract base URL from full URL
  defp get_base_url_from_full_url(url) do
    uri = URI.parse(url)

    "#{uri.scheme}://#{uri.host}#{if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""}"
  end

  # Helper to extract path from full URL  
  defp get_path_from_url(url) do
    URI.parse(url).path || "/"
  end

  defp build_files_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "files-api-2025-04-14"}
    ]
  end

  defp validate_batch_requests(requests) when is_list(requests) do
    if length(requests) > 100_000 do
      {:error, "Batch cannot contain more than 100,000 requests"}
    else
      validated =
        Enum.with_index(requests, fn request, index ->
          %{
            custom_id: Map.get(request, :custom_id, "request_#{index}"),
            params: Map.take(request, [:model, :messages, :max_tokens, :temperature, :system])
          }
        end)

      {:ok, validated}
    end
  end

  defp validate_batch_requests(_), do: {:error, "Requests must be a list"}
end
