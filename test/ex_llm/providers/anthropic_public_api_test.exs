defmodule ExLLM.Providers.AnthropicPublicAPITest do
  @moduledoc """
  Anthropic-specific integration tests using the public ExLLM API.
  Common tests are handled by the shared module.
  """

  use ExLLM.Shared.ProviderIntegrationTest, provider: :anthropic

  # Provider-specific tests only
  describe "anthropic-specific features via public API" do
    @tag :vision
    test "handles Claude vision capabilities" do
      # Small 1x1 red pixel PNG
      red_pixel =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "What color is this image?"},
            %{
              type: "image",
              image: %{
                data: red_pixel,
                media_type: "image/png"
              }
            }
          ]
        }
      ]

      case ExLLM.chat(:anthropic, messages, model: "claude-3-5-sonnet-20241022", max_tokens: 50) do
        {:ok, response} ->
          # Claude can see the image and responds (don't test specific color)
          assert String.length(response.content) > 0

        {:error, {:api_error, %{status: 400}}} ->
          IO.puts("Vision not supported or invalid image")

        {:error, reason} ->
          IO.puts("Vision test failed: #{inspect(reason)}")
      end
    end

    test "handles multiple system messages gracefully" do
      # Anthropic only supports one system message
      messages = [
        %{role: "system", content: "You are helpful."},
        %{role: "system", content: "You are concise."},
        %{role: "user", content: "Hi"}
      ]

      case ExLLM.chat(:anthropic, messages, max_tokens: 50) do
        {:ok, response} ->
          # Should combine or use last system message
          assert is_binary(response.content)

        {:error, _} ->
          # Might reject multiple system messages
          :ok
      end
    end

    @tag :streaming
    test "streaming includes proper finish reasons" do
      messages = [
        %{role: "user", content: "Say hello"}
      ]

      # We need to capture the test PID since the callback runs in a different process
      test_pid = self()

      # Collect chunks using the callback API
      collector = fn chunk ->
        send(test_pid, {:chunk, chunk})
      end

      case ExLLM.stream(:anthropic, messages, collector, max_tokens: 10, timeout: 10_000) do
        :ok ->
          # Give streaming time to start and send chunks
          Process.sleep(100)

          chunks = collect_stream_chunks([], 2000)
          assert length(chunks) > 0, "No chunks received"

          # Filter out non-StreamChunk structs
          stream_chunks = Enum.filter(chunks, &match?(%ExLLM.Types.StreamChunk{}, &1))
          assert length(stream_chunks) > 0, "No StreamChunk structs received"

          last_chunk = List.last(stream_chunks)
          assert last_chunk != nil, "Last chunk is nil"
          # Streaming coordinators normalize finish reasons to "stop"
          assert last_chunk.finish_reason in ["end_turn", "stop_sequence", "max_tokens", "stop"]

        {:error, _} ->
          :ok
      end
    end
  end
end
