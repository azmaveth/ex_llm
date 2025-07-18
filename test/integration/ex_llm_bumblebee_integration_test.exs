defmodule ExLLM.BumblebeeTopLevelIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :requires_deps

  describe "bumblebee adapter integration" do
    test "bumblebee adapter is registered" do
      providers = ExLLM.supported_providers()
      assert :bumblebee in providers
    end

    test "default model is available" do
      assert ExLLM.default_model(:bumblebee) == "HuggingFaceTB/SmolLM2-1.7B-Instruct"
    end

    test "configured? returns false without ModelLoader" do
      # Bumblebee is installed but ModelLoader isn't running, should return false
      # Note: configured? checks if ModelLoader is running, not just if Bumblebee is installed
      assert ExLLM.configured?(:bumblebee) == false
    end

    test "list_models returns static models without ModelLoader" do
      # Bumblebee now returns static model list even without ModelLoader
      assert {:ok, models} = ExLLM.list_models(:bumblebee)
      assert is_list(models)
      assert length(models) > 0
      # Verify model structure
      model = hd(models)
      assert Map.has_key?(model, :id)
      assert Map.has_key?(model, :name)
    end

    test "chat returns error without ModelLoader" do
      messages = [%{role: "user", content: "Hello"}]

      # ModelLoader is not started in test environment
      # Bumblebee adapter should handle this gracefully
      result = ExLLM.chat(:bumblebee, messages)

      assert match?({:error, _}, result),
             "Expected error without ModelLoader, got: #{inspect(result)}"

      {:error, error_data} = result
      error_string = inspect(error_data)

      assert error_string =~ "ModelLoader" or error_string =~ "not running" or
               error_string =~ "not started",
             "Expected ModelLoader error, got: #{error_string}"
    end

    @tag :streaming
    test "stream returns error without ModelLoader" do
      messages = [%{role: "user", content: "Hello"}]

      # Streaming should also handle missing ModelLoader gracefully
      result = ExLLM.stream(:bumblebee, messages, fn _chunk -> :ok end)

      case result do
        {:error, error_data} ->
          error_string = inspect(error_data)

          assert error_string =~ "ModelLoader" or error_string =~ "not running" or
                   error_string =~ "not started",
                 "Expected ModelLoader error, got: #{error_string}"

        :ok ->
          # This would mean streaming started, which shouldn't happen
          flunk("Expected error without ModelLoader, but streaming started")

        other ->
          flunk("Expected error without ModelLoader, got: #{inspect(other)}")
      end
    end
  end

  describe "context management with bumblebee models" do
    test "prepare_messages works with bumblebee provider" do
      messages = [
        %{role: "system", content: "You are a helpful assistant"},
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"},
        %{role: "user", content: "How are you?"}
      ]

      prepared =
        ExLLM.prepare_messages(messages,
          provider: "bumblebee",
          model: "HuggingFaceTB/SmolLM2-1.7B-Instruct",
          max_tokens: 1000
        )

      assert is_list(prepared)
      assert length(prepared) <= length(messages)
    end

    test "context_window_size returns correct size for bumblebee models" do
      assert ExLLM.context_window_size(:bumblebee, "HuggingFaceTB/SmolLM2-1.7B-Instruct") == 2048
      assert ExLLM.context_window_size(:bumblebee, "mistralai/Mistral-7B-v0.1") == 8192
    end
  end
end
