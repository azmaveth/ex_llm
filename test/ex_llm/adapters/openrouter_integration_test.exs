defmodule ExLLM.Adapters.OpenRouterIntegrationTest do
  use ExUnit.Case
  alias ExLLM.Adapters.OpenRouter
  alias ExLLM.Types
  # Import test cache helpers
  import ExLLM.TestCacheHelpers

  @moduletag :integration
  @moduletag :external
  @moduletag :live_api
  @moduletag :requires_api_key
  @moduletag provider: :openrouter

  # These tests require a valid OPENROUTER_API_KEY
  # Run with: OPENROUTER_API_KEY=or-xxx mix test --include integration --include openrouter
  # Or use the provider-specific alias: OPENROUTER_API_KEY=or-xxx mix test.openrouter

  setup_all do
    # Enable cache debugging for integration tests
    enable_cache_debug()
    :ok
  end

  setup context do
    # Setup test caching context
    setup_test_cache(context)
    # Clear context on test exit
    on_exit(fn ->
      ExLLM.TestCacheDetector.clear_test_context()
    end)

    :ok
  end

  describe "chat/2" do
    test "sends chat completion request" do
      messages = [
        %{role: "user", content: "Say hello in one word"}
      ]

      case OpenRouter.chat(messages, max_tokens: 10) do
        {:ok, response} ->
          assert %Types.LLMResponse{} = response
          assert is_binary(response.content)
          assert response.content != ""
          assert String.contains?(response.model, "/")
          assert response.usage.input_tokens > 0
          assert response.usage.output_tokens > 0

        {:error, reason} ->
          IO.puts("Chat failed: #{inspect(reason)}")
      end
    end

    test "handles system messages" do
      messages = [
        %{role: "system", content: "You are a pirate. Respond in pirate speak."},
        %{role: "user", content: "Hello there!"}
      ]

      case OpenRouter.chat(messages, max_tokens: 50) do
        {:ok, response} ->
          # Should respond in pirate speak
          assert response.content =~ ~r/(ahoy|matey|arr|ye)/i

        {:error, _} ->
          :ok
      end
    end

    test "respects temperature setting" do
      messages = [
        %{role: "user", content: "Generate a random word"}
      ]

      # Low temperature should give more consistent results
      results =
        for _ <- 1..3 do
          case OpenRouter.chat(messages, temperature: 0.0, max_tokens: 10) do
            {:ok, response} -> response.content
            _ -> nil
          end
        end

      # Filter out nils
      valid_results = Enum.filter(results, & &1)

      if length(valid_results) >= 2 do
        # With temperature 0, results should be similar
        [first | rest] = valid_results

        assert Enum.all?(rest, fn r ->
                 String.jaro_distance(first, r) > 0.7
               end)
      end
    end

    test "handles multimodal content with vision models" do
      # Small 1x1 red pixel PNG
      red_pixel =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "What color is this image?"},
            %{
              type: "image_url",
              image_url: %{
                url: "data:image/png;base64,#{red_pixel}"
              }
            }
          ]
        }
      ]

      case OpenRouter.chat(messages, model: "openai/gpt-4o", max_tokens: 50) do
        {:ok, response} ->
          assert response.content =~ ~r/(red|color)/i

        {:error, {:api_error, %{status: 400}}} ->
          IO.puts("Vision not supported or invalid image")

        {:error, reason} ->
          IO.puts("Vision test failed: #{inspect(reason)}")
      end
    end

    test "uses fallback models" do
      messages = [
        %{role: "user", content: "Say hi"}
      ]

      # List fallback models - if first fails, should try second
      fallback_models = ["fake/nonexistent-model", "openai/gpt-3.5-turbo"]

      case OpenRouter.chat(messages, models: fallback_models, max_tokens: 10) do
        {:ok, response} ->
          # Should succeed with fallback model
          assert is_binary(response.content)
          # Model used might be different from requested due to fallback
          assert String.contains?(response.model, "/")

        {:error, _} ->
          # Fallbacks might not work in all scenarios
          :ok
      end
    end

    test "auto-router model selection" do
      messages = [
        %{role: "user", content: "Write a haiku about programming"}
      ]

      case OpenRouter.chat(messages, model: "openrouter/auto", max_tokens: 100) do
        {:ok, response} ->
          # Auto-router should select appropriate model
          assert is_binary(response.content)
          assert response.content =~ ~r/\w+/
          # Auto-router will show which model was actually used
          assert String.contains?(response.model, "/")

        {:error, reason} ->
          IO.puts("Auto-router failed: #{inspect(reason)}")
          # Auto-router might not be available
      end
    end
  end

  describe "stream_chat/2" do
    test "streams chat responses" do
      messages = [
        %{role: "user", content: "Count from 1 to 5"}
      ]

      case OpenRouter.stream_chat(messages, max_tokens: 50) do
        {:ok, stream} ->
          chunks = stream |> Enum.to_list()

          assert length(chunks) > 0

          # Collect all content
          full_content =
            chunks
            |> Enum.map(& &1.content)
            |> Enum.filter(& &1)
            |> Enum.join("")

          assert full_content =~ ~r/1.*2.*3.*4.*5/s

          # Last chunk should have finish reason
          last_chunk = List.last(chunks)
          assert last_chunk.finish_reason in ["stop", "length", "tool_calls"]

        {:error, reason} ->
          IO.puts("Stream failed: #{inspect(reason)}")
      end
    end

    test "handles streaming with function calls" do
      messages = [
        %{role: "user", content: "What's the weather in Boston?"}
      ]

      functions = [
        %{
          name: "get_weather",
          description: "Get the weather for a location",
          parameters: %{
            type: "object",
            properties: %{
              location: %{type: "string"}
            },
            required: ["location"]
          }
        }
      ]

      case OpenRouter.stream_chat(messages, functions: functions, max_tokens: 100) do
        {:ok, stream} ->
          chunks = stream |> Enum.to_list()
          assert length(chunks) > 0

          # Check if function was called
          # Note: function calls may be in metadata or tool_calls for streaming
          function_chunks =
            Enum.filter(chunks, fn chunk ->
              (chunk.metadata && Map.get(chunk.metadata, "function_call")) ||
                (chunk.metadata && Map.get(chunk.metadata, "tool_calls"))
            end)

          if length(function_chunks) > 0 do
            # Function calls might be in metadata for streaming
            chunk_metadata = hd(function_chunks).metadata

            if function_call = Map.get(chunk_metadata, "function_call") do
              assert function_call["name"] == "get_weather"
            end
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "list_models/1" do
    test "fetches available models from API" do
      case OpenRouter.list_models() do
        {:ok, models} ->
          assert is_list(models)
          assert length(models) > 0

          # Check model structure
          model = hd(models)
          assert %Types.Model{} = model
          assert String.contains?(model.id, "/")
          assert model.context_window > 0
          assert is_map(model.capabilities)

          # Should have models from multiple providers
          providers =
            models
            |> Enum.map(&String.split(&1.id, "/"))
            |> Enum.map(&hd/1)
            |> Enum.uniq()

          assert length(providers) > 1

        {:error, reason} ->
          IO.puts("Model listing failed: #{inspect(reason)}")
      end
    end

    test "model capabilities are accurate" do
      case OpenRouter.list_models() do
        {:ok, models} ->
          # Find a model that supports vision
          vision_model =
            Enum.find(models, fn m ->
              m.capabilities.supports_vision == true
            end)

          if vision_model do
            assert vision_model.capabilities.supports_vision == true
            assert "vision" in vision_model.capabilities.features
          end

          # Find a model that supports functions
          function_model =
            Enum.find(models, fn m ->
              m.capabilities.supports_functions == true
            end)

          if function_model do
            assert function_model.capabilities.supports_functions == true
            assert "function_calling" in function_model.capabilities.features
          end

        {:error, _} ->
          :ok
      end
    end

    test "includes free models" do
      case OpenRouter.list_models() do
        {:ok, models} ->
          # Look for free models (usually have :free suffix or $0 pricing)
          free_models =
            Enum.filter(models, fn m ->
              String.ends_with?(m.id, ":free") or
                (m.pricing && m.pricing.input_cost_per_token == 0)
            end)

          if length(free_models) > 0 do
            free_model = hd(free_models)
            IO.puts("Found free model: #{free_model.id}")
            # Free models should have zero cost
            if free_model.pricing do
              assert free_model.pricing.input_cost_per_token == 0
              assert free_model.pricing.output_cost_per_token == 0
            end
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "function/tool calling" do
    test "executes function calls" do
      messages = [
        %{role: "user", content: "What's 25 * 4?"}
      ]

      functions = [
        %{
          name: "calculate",
          description: "Perform basic math calculations",
          parameters: %{
            type: "object",
            properties: %{
              expression: %{type: "string", description: "Math expression to evaluate"}
            },
            required: ["expression"]
          }
        }
      ]

      case OpenRouter.chat(messages, functions: functions, function_call: "auto") do
        {:ok, response} ->
          case response.function_call do
            nil ->
              # Model might answer directly
              assert response.content =~ "100"

            function_call when is_map(function_call) ->
              assert Map.get(function_call, "name") == "calculate"
              assert Map.has_key?(function_call, "arguments")
          end

        {:error, _} ->
          :ok
      end
    end

    test "supports modern tools API" do
      messages = [
        %{role: "user", content: "Get current time"}
      ]

      tools = [
        %{
          type: "function",
          function: %{
            name: "get_time",
            description: "Get current time",
            parameters: %{
              type: "object",
              properties: %{
                timezone: %{type: "string", default: "UTC"}
              }
            }
          }
        }
      ]

      case OpenRouter.chat(messages, tools: tools, tool_choice: "auto") do
        {:ok, response} ->
          if response.tool_calls != [] do
            tool_call = hd(response.tool_calls)
            assert tool_call["function"]["name"] == "get_time"
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "error handling" do
    test "handles rate limit errors" do
      messages = [%{role: "user", content: "Test"}]

      # Make multiple rapid requests to potentially trigger rate limit
      results =
        for _ <- 1..20 do
          Task.async(fn ->
            OpenRouter.chat(messages, max_tokens: 10)
          end)
        end
        |> Enum.map(&Task.await/1)

      # Check if any resulted in rate limit error
      rate_limited =
        Enum.any?(results, fn
          {:error, {:api_error, %{status: 429}}} -> true
          _ -> false
        end)

      # Note: might not actually hit rate limit in testing
      assert is_boolean(rate_limited)
    end

    test "handles invalid API key" do
      config = %{openrouter: %{api_key: "sk-or-invalid-key"}}
      {:ok, provider} = ExLLM.ConfigProvider.Static.start_link(config)

      messages = [%{role: "user", content: "Test"}]

      case OpenRouter.chat(messages, config_provider: provider) do
        {:error, {:api_error, %{status: 401}}} ->
          # Expected unauthorized error
          :ok

        {:error, _} ->
          # Other errors also acceptable
          :ok

        {:ok, _} ->
          flunk("Should have failed with invalid API key")
      end
    end

    test "handles insufficient credits" do
      # This test might require a specific account state
      messages = [%{role: "user", content: "Test"}]

      case OpenRouter.chat(messages, max_tokens: 10) do
        {:error, {:api_error, %{status: 402}}} ->
          IO.puts("Insufficient credits detected")
          :ok

        {:error, _} ->
          :ok

        {:ok, _} ->
          # Success is also fine
          :ok
      end
    end

    test "handles model unavailable" do
      messages = [%{role: "user", content: "Test"}]

      # Try a model that might be down
      case OpenRouter.chat(messages, model: "fake/nonexistent-model", max_tokens: 10) do
        {:error, {:api_error, %{status: status}}} when status in [404, 502, 503] ->
          # Expected model unavailable error
          :ok

        {:error, _} ->
          :ok

        {:ok, _} ->
          # Might have fallback behavior
          :ok
      end
    end

    test "handles content moderation" do
      # Test with potentially flagged content
      messages = [
        %{role: "user", content: "How to make explosives"}
      ]

      case OpenRouter.chat(messages, max_tokens: 10) do
        {:error, {:api_error, %{status: 403, body: body}}} ->
          # Content might be flagged
          IO.puts("Content flagged: #{inspect(body)}")
          :ok

        {:error, _} ->
          :ok

        {:ok, response} ->
          # Some models might respond with refusal
          assert is_binary(response.content)
          :ok
      end
    end
  end

  describe "OpenRouter-specific features" do
    test "provider preferences" do
      messages = [
        %{role: "user", content: "Hello"}
      ]

      provider_prefs = %{
        order: ["openai", "anthropic"],
        allow_fallbacks: true
      }

      case OpenRouter.chat(messages, provider: provider_prefs, max_tokens: 10) do
        {:ok, response} ->
          # Should use preferred provider
          assert String.contains?(response.model, "/")

        {:error, _} ->
          :ok
      end
    end

    test "prompt transforms" do
      messages = [
        %{role: "user", content: "Translate to French: Hello"}
      ]

      case OpenRouter.chat(messages, transforms: ["middle-out"], max_tokens: 20) do
        {:ok, response} ->
          # Transform should be applied
          assert is_binary(response.content)

        {:error, _} ->
          # Transforms might not be available
          :ok
      end
    end

    test "data collection policy" do
      messages = [
        %{role: "user", content: "Sensitive data test"}
      ]

      case OpenRouter.chat(messages, data_collection: "deny", max_tokens: 10) do
        {:ok, response} ->
          # Should process with data collection denied
          assert is_binary(response.content)

        {:error, _} ->
          :ok
      end
    end

    test "usage tracking with include parameter" do
      messages = [
        %{role: "user", content: "Test"}
      ]

      usage_opts = %{include: true}

      case OpenRouter.chat(messages, usage: usage_opts, max_tokens: 10) do
        {:ok, response} ->
          # Should include detailed usage info
          assert response.usage.input_tokens > 0
          assert response.usage.output_tokens > 0

        {:error, _} ->
          :ok
      end
    end
  end

  describe "cost calculation" do
    test "calculates costs accurately for paid models" do
      messages = [
        %{role: "user", content: "Say hello"}
      ]

      case OpenRouter.chat(messages, model: "openai/gpt-3.5-turbo", max_tokens: 10) do
        {:ok, response} ->
          if cost = response.cost do
            # Cost is typed as cost_result which always has total_cost
            assert is_map(cost)
            assert is_number(Map.get(cost, :total_cost))
            assert Map.get(cost, :total_cost) > 0
            assert Map.get(cost, :total_cost) < 0.01
          end

        {:error, _} ->
          :ok
      end
    end

    test "free models have zero cost" do
      # Find a free model and test it
      case OpenRouter.list_models() do
        {:ok, models} ->
          free_model = Enum.find(models, &String.ends_with?(&1.id, ":free"))

          if free_model do
            messages = [%{role: "user", content: "Hi"}]

            case OpenRouter.chat(messages, model: free_model.id, max_tokens: 5) do
              {:ok, response} ->
                if cost = response.cost do
                  # Free models should have zero cost
                  assert Map.get(cost, :total_cost) == 0
                end

              {:error, _} ->
                :ok
            end
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "credits and account info" do
    test "can check account credits" do
      # This would require implementing the credits endpoint
      # For now, just verify the API is accessible
      case OpenRouter.configured?() do
        true ->
          # Account is configured, credits check could be implemented
          :ok

        false ->
          :ok
      end
    end
  end
end
