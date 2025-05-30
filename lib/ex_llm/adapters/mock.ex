defmodule ExLLM.Adapters.Mock do
  @moduledoc """
  Mock adapter for testing ExLLM integrations.

  This adapter provides predictable responses for testing without making actual API calls.
  It supports all ExLLM features including streaming, function calling, and error simulation.

  ## Configuration

  The mock adapter can be configured with predefined responses or response generators:

      # Static response
      ExLLM.Adapters.Mock.set_response(%{
        content: "Mock response",
        model: "mock-model",
        usage: %{input_tokens: 10, output_tokens: 20}
      })
      
      # Dynamic response based on input
      ExLLM.Adapters.Mock.set_response_handler(fn messages, options ->
        %{content: "You said: \#{List.last(messages).content}"}
      end)
      
      # Simulate errors
      ExLLM.Adapters.Mock.set_error({:api_error, %{status: 500, body: "Server error"}})

  ## Testing Features

  - Capture and inspect requests
  - Simulate various response types
  - Test error handling
  - Validate function calling
  - Test streaming behavior
  """

  @behaviour ExLLM.Adapter

  alias ExLLM.Types
  use Agent

  defmodule State do
    @moduledoc false
    defstruct [
      # :static | :handler | :error
      :response_mode,
      :static_response,
      :response_handler,
      :error_response,
      :requests,
      :stream_chunks,
      :function_call_response
    ]
  end

  @doc """
  Starts the mock adapter agent.
  """
  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %State{
          response_mode: :static,
          static_response: default_response(),
          requests: [],
          stream_chunks: default_stream_chunks()
        }
      end,
      name: __MODULE__
    )
  end

  @doc """
  Sets a static response for all requests.
  """
  def set_response(response) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      %{state | response_mode: :static, static_response: normalize_response(response)}
    end)
  end

  @doc """
  Sets a dynamic response handler.
  """
  def set_response_handler(handler) when is_function(handler, 2) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      %{state | response_mode: :handler, response_handler: handler}
    end)
  end

  @doc """
  Sets an error response.
  """
  def set_error(error) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      %{state | response_mode: :error, error_response: error}
    end)
  end

  @doc """
  Sets stream chunks for streaming responses.
  """
  def set_stream_chunks(chunks) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      %{state | stream_chunks: chunks}
    end)
  end

  @doc """
  Sets a function call response.
  """
  def set_function_call_response(function_call) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      %{state | function_call_response: function_call}
    end)
  end

  @doc """
  Gets all captured requests.
  """
  def get_requests do
    ensure_started()
    Agent.get(__MODULE__, & &1.requests)
  end

  @doc """
  Gets the last captured request.
  """
  def get_last_request do
    ensure_started()

    Agent.get(__MODULE__, fn state ->
      List.last(state.requests)
    end)
  end

  @doc """
  Clears all captured requests and resets to defaults.
  """
  def reset do
    ensure_started()

    Agent.update(__MODULE__, fn _state ->
      %State{
        response_mode: :static,
        static_response: default_response(),
        requests: [],
        stream_chunks: default_stream_chunks()
      }
    end)
  end

  # Adapter implementation

  @impl true
  def chat(messages, options \\ []) do
    ensure_started()

    # Capture request
    capture_request(:chat, messages, options)

    # Check for mock response in Application env first
    case Application.get_env(:ex_llm, :mock_responses, %{})[:chat] do
      nil ->
        # Get response based on mode
        Agent.get(__MODULE__, fn state ->
          case state.response_mode do
            :static ->
              response = build_response(state.static_response, messages, options)
              {:ok, response}

            :handler ->
              case state.response_handler.(messages, options) do
                {:ok, _} = result -> result
                {:error, _} = error -> error
                response -> {:ok, normalize_response(response)}
              end

            :error ->
              {:error, state.error_response}
          end
        end)

      {:error, _} = error ->
        error

      response when is_function(response, 2) ->
        case response.(messages, options) do
          {:ok, _} = result -> result
          {:error, _} = error -> error
          response -> {:ok, normalize_response(response)}
        end

      responses when is_list(responses) ->
        # Cycle through list of responses
        Agent.get_and_update(__MODULE__, fn state ->
          index = Map.get(state, :response_index, 0)
          response = Enum.at(responses, rem(index, length(responses)))
          new_state = Map.put(state, :response_index, index + 1)
          {response, new_state}
        end)
        |> then(fn response -> {:ok, normalize_response(response)} end)

      response ->
        {:ok, normalize_response(response)}
    end
  end

  @impl true
  def stream_chat(messages, options \\ []) do
    ensure_started()

    # Capture request
    capture_request(:stream_chat, messages, options)

    # Check for mock response in Application env first
    case Application.get_env(:ex_llm, :mock_responses, %{})[:stream] do
      nil ->
        # Return stream based on mode
        Agent.get(__MODULE__, fn state ->
      case state.response_mode do
        :error ->
          {:error, state.error_response}

        _ ->
          chunks =
            if state.function_call_response do
              # Include function call in stream
              state.stream_chunks ++
                [
                  %Types.StreamChunk{
                    content: nil,
                    finish_reason: "function_call"
                  }
                ]
            else
              state.stream_chunks
            end

          stream =
            Stream.map(chunks, fn chunk ->
              # Add small delay to simulate real streaming
              Process.sleep(10)
              chunk
            end)

          {:ok, stream}
      end
    end)

      {:error, _} = error ->
        error

      chunks when is_list(chunks) ->
        {:ok, Stream.map(chunks, fn 
          {:error, reason} -> raise "Stream error: #{inspect(reason)}"
          chunk -> chunk
        end)}

      response when is_function(response, 2) ->
        case response.(messages, options) do
          {:ok, stream} -> {:ok, stream}
          {:error, _} = error -> error
          stream -> {:ok, stream}
        end

      _ ->
        {:error, :invalid_stream_response}
    end
  end

  @impl true
  def list_models(_options \\ []) do
    ensure_started()

    {:ok,
     [
       %Types.Model{
         id: "mock-model-small",
         name: "Mock Model Small",
         context_window: 4_096
       },
       %Types.Model{
         id: "mock-model-large",
         name: "Mock Model Large",
         context_window: 32_768
       }
     ]}
  end

  @impl true
  def configured?(_options \\ []) do
    true
  end

  @impl true
  def embeddings(inputs, options \\ []) do
    ensure_started()
    
    # Normalize inputs to list
    inputs = if is_binary(inputs), do: [inputs], else: inputs

    # Check for mock response in Application env first
    case Application.get_env(:ex_llm, :mock_responses, %{})[:embeddings] do
      nil ->
        # Check for mock configuration in options
        cond do
          # Static mock response
          mock_response = Keyword.get(options, :mock_response) ->
            result = handle_embeddings_response(mock_response, inputs, options)
            capture_if_enabled(:embeddings, inputs, options, result)
            result

          # Error simulation
          mock_error = Keyword.get(options, :mock_error) ->
            {:error, mock_error}

          # Default mock embeddings
          true ->
            # Generate random embeddings
            embeddings =
              Enum.map(inputs, fn _ ->
                Enum.map(1..384, fn _ -> :rand.uniform() * 2 - 1 end)
              end)

            response = %Types.EmbeddingResponse{
              embeddings: embeddings,
              model: Keyword.get(options, :model, "mock-embedding-model"),
              usage: %{
                input_tokens: estimate_tokens(inputs),
                output_tokens: 0
              }
            }

            # Add cost if tracking
            response =
              if Keyword.get(options, :track_cost, true) do
                %{
                  response
                  | cost: %{
                      total_cost: 0.0,
                      input_cost: 0.0,
                      output_cost: 0.0,
                      currency: "USD"
                    }
                }
              else
                response
              end

            result = {:ok, response}
            capture_if_enabled(:embeddings, inputs, options, result)
            result
        end

      {:error, _} = error ->
        error

      response when is_function(response, 2) ->
        case response.(inputs, options) do
          {:ok, _} = result -> result
          {:error, _} = error -> error
          response -> {:ok, response}
        end

      response ->
        {:ok, response}
    end
  end

  @impl true
  def list_embedding_models(_options \\ []) do
    # Check for mock response in Application env first
    case Application.get_env(:ex_llm, :mock_responses, %{})[:list_embedding_models] do
      nil ->
        # Default models
        models = [
          %Types.EmbeddingModel{
            name: "mock-embedding-small",
            dimensions: 384,
            max_inputs: 100,
            provider: :mock,
            description: "Small mock embedding model",
            pricing: %{
              input_cost_per_token: 0.0,
              output_cost_per_token: 0.0,
              currency: "USD"
            }
          },
          %Types.EmbeddingModel{
            name: "mock-embedding-large",
            dimensions: 1536,
            max_inputs: 100,
            provider: :mock,
            description: "Large mock embedding model",
            pricing: %{
              input_cost_per_token: 0.0,
              output_cost_per_token: 0.0,
              currency: "USD"
            }
          }
        ]
        
        {:ok, models}
        
      models when is_list(models) ->
        {:ok, models}
        
      {:error, _} = error ->
        error
    end
  end

  @impl true
  def default_model do
    "mock-model"
  end

  # Private functions

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end

  defp capture_request(type, messages, options) do
    Agent.update(__MODULE__, fn state ->
      request = %{
        type: type,
        messages: messages,
        options: options,
        timestamp: DateTime.utc_now()
      }

      %{state | requests: state.requests ++ [request]}
    end)
  end

  defp normalize_response(%Types.LLMResponse{} = response), do: response
  
  defp normalize_response(response) when is_map(response) do
    %Types.LLMResponse{
      content: Map.get(response, :content) || Map.get(response, "content") || "Mock response",
      model: Map.get(response, :model) || Map.get(response, "model") || "mock-model",
      usage: normalize_usage(Map.get(response, :usage) || Map.get(response, "usage")),
      finish_reason: Map.get(response, :finish_reason) || Map.get(response, "finish_reason") || "stop",
      id: Map.get(response, :id) || Map.get(response, "id") || generate_id(),
      function_call: Map.get(response, :function_call) || Map.get(response, "function_call"),
      tool_calls: Map.get(response, :tool_calls) || Map.get(response, "tool_calls"),
      cost: Map.get(response, :cost) || Map.get(response, "cost")
    }
  end

  defp normalize_response(content) when is_binary(content) do
    %Types.LLMResponse{
      content: content,
      model: "mock-model",
      usage: %{input_tokens: 10, output_tokens: 20},
      finish_reason: "stop",
      id: generate_id()
    }
  end

  defp normalize_usage(nil), do: %{input_tokens: 10, output_tokens: 20}

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"] || 10,
      output_tokens: usage[:output_tokens] || usage["output_tokens"] || 20
    }
  end

  defp build_response(base_response, _messages, options) do
    response = base_response

    # Add function calling if requested
    if _functions = options[:functions] do
      if base_response.function_call || Agent.get(__MODULE__, & &1.function_call_response) do
        response
      else
        response
      end
    else
      response
    end
  end

  defp default_response do
    %Types.LLMResponse{
      content: "This is a mock response",
      model: "mock-model",
      usage: %{input_tokens: 10, output_tokens: 20},
      finish_reason: "stop",
      id: generate_id()
    }
  end

  defp default_stream_chunks do
    [
      %Types.StreamChunk{content: "This ", finish_reason: nil},
      %Types.StreamChunk{content: "is ", finish_reason: nil},
      %Types.StreamChunk{content: "a ", finish_reason: nil},
      %Types.StreamChunk{content: "mock ", finish_reason: nil},
      %Types.StreamChunk{content: "stream ", finish_reason: nil},
      %Types.StreamChunk{content: "response", finish_reason: nil},
      %Types.StreamChunk{content: "", finish_reason: "stop"}
    ]
  end

  defp generate_id do
    ("mock-" <> :crypto.strong_rand_bytes(8)) |> Base.encode16(case: :lower)
  end

  defp handle_embeddings_response(mock_response, _inputs, _options) when is_map(mock_response) do
    response = struct(Types.EmbeddingResponse, mock_response)
    {:ok, response}
  end

  defp handle_embeddings_response(embeddings, inputs, options) when is_list(embeddings) do
    response = %Types.EmbeddingResponse{
      embeddings: embeddings,
      model: Keyword.get(options, :model, "mock-embedding-model"),
      usage: %{
        input_tokens: estimate_tokens(inputs),
        output_tokens: 0
      }
    }

    {:ok, response}
  end

  defp estimate_tokens(inputs) when is_list(inputs) do
    # Simple estimation: ~4 characters per token
    Enum.reduce(inputs, 0, fn input, acc ->
      acc + div(String.length(input), 4)
    end)
  end

  defp capture_if_enabled(type, input, options, _result) do
    if Keyword.get(options, :capture_requests, false) do
      capture_request(type, input, options)
    end
  end
end
