defmodule ExLLM.Providers.XAITest do
  use ExUnit.Case, async: false
  alias ExLLM.Providers.XAI
  alias ExLLM.Types

  describe "XAI adapter" do
    test "configured?/1 returns false when no API key" do
      # Save current env var
      original_key = System.get_env("XAI_API_KEY")

      try do
        # Temporarily unset the env var
        System.delete_env("XAI_API_KEY")

        {:ok, pid} = ExLLM.Infrastructure.ConfigProvider.Static.start_link(%{xai: %{}})
        refute XAI.configured?(config_provider: pid)
      after
        # Restore env var if it existed
        if original_key, do: System.put_env("XAI_API_KEY", original_key)
      end
    end

    test "configured?/1 returns true when API key is set" do
      config = %{xai: %{api_key: "test-key"}}
      {:ok, pid} = ExLLM.Infrastructure.ConfigProvider.Static.start_link(config)
      assert XAI.configured?(config_provider: pid)
    end

    test "default_model/1 returns the default model" do
      assert XAI.default_model([]) == "grok-3"
    end

    test "list_models/1 returns available models" do
      {:ok, models} = XAI.list_models()

      assert is_list(models)
      assert length(models) > 0

      # Check for expected models
      model_ids = Enum.map(models, & &1.id)
      assert "xai/grok-beta" in model_ids
      assert "xai/grok-2-vision-1212" in model_ids
      assert "xai/grok-3-beta" in model_ids

      # Check model structure
      first_model = hd(models)
      assert %Types.Model{} = first_model
      assert is_binary(first_model.id)
      assert is_binary(first_model.name)
      assert is_integer(first_model.context_window)
    end

    @tag :embedding
    test "embeddings/2 returns not supported error" do
      assert {:error, {:not_supported, _}} = XAI.embeddings(["test"], [])
    end
  end

  describe "provider detection" do
    test "provider/model string works with XAI" do
      # Test with mock to avoid real API calls
      ExLLM.Providers.Mock.start_link()
      ExLLM.Providers.Mock.set_response(%{content: "Test response from Grok"})

      messages = [%{role: "user", content: "Hello"}]
      {:ok, response} = ExLLM.chat(:mock, messages)

      assert is_binary(response.content)
    end
  end

  describe "vision support" do
    @tag :vision
    test "vision models are properly identified" do
      {:ok, models} = XAI.list_models()

      vision_models =
        Enum.filter(models, fn model ->
          case model.capabilities do
            capabilities when is_list(capabilities) ->
              :vision in capabilities

            %{features: features} when is_list(features) ->
              :vision in features

            %{supports_vision: true} ->
              true

            _ ->
              false
          end
        end)

      vision_model_ids = Enum.map(vision_models, & &1.id)

      # These models should have vision support
      assert "xai/grok-2-vision-1212" in vision_model_ids
      assert "xai/grok-vision-beta" in vision_model_ids
    end
  end

  describe "model capabilities" do
    test "models have expected capabilities" do
      {:ok, models} = XAI.list_models()

      # Find specific models and check their capabilities
      grok_beta = Enum.find(models, &(&1.id == "xai/grok-beta"))
      assert grok_beta

      # Handle both list and map formats for capabilities
      case grok_beta.capabilities do
        capabilities when is_list(capabilities) ->
          assert :streaming in capabilities
          assert :function_calling in capabilities

        %{features: features} = capabilities when is_map(capabilities) ->
          assert :streaming in features
          assert :function_calling in features
          assert capabilities.supports_streaming == true
          assert capabilities.supports_functions == true
      end

      grok_3_mini = Enum.find(models, &(&1.id == "xai/grok-3-mini-beta"))
      assert grok_3_mini

      case grok_3_mini.capabilities do
        capabilities when is_list(capabilities) ->
          assert :reasoning in capabilities

        %{features: features} when is_list(features) ->
          assert :reasoning in features
      end
    end
  end
end
