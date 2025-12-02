defmodule ExLLM.ResponseCapture do
  @moduledoc """
  Captures API responses for debugging and development purposes.

  This module extends the test caching infrastructure to capture
  and optionally display API responses during development.
  """

  alias ExLLM.Testing.LiveApiCacheStorage

  def enabled? do
    System.get_env("EX_LLM_CAPTURE_RESPONSES") == "true"
  end

  def display_enabled? do
    System.get_env("EX_LLM_SHOW_CAPTURED") == "true"
  end

  @doc """
  Capture a response from an API call.
  """
  def capture_response(provider, endpoint, request, response, metadata \\ %{}) do
    if enabled?() do
      # Generate a simpler cache key for captures
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      cache_key = "#{provider}/#{endpoint}/#{timestamp}"

      # Enhance metadata - use string keys for consistency with cache storage
      enhanced_metadata =
        Map.merge(metadata, %{
          "provider" => provider,
          "endpoint" => endpoint,
          "captured_at" => timestamp,
          "environment" => Application.get_env(:ex_llm, :environment, :prod),
          "request_summary" => summarize_request(request)
        })

      # Store using existing infrastructure
      case LiveApiCacheStorage.store(
             cache_key,
             response,
             enhanced_metadata
           ) do
        {:ok, _filename} ->
          # Display if enabled
          if display_enabled?() do
            display_capture(response, enhanced_metadata)
          end

          :ok

        :ok ->
          # Display if enabled
          if display_enabled?() do
            display_capture(response, enhanced_metadata)
          end

          :ok

        error ->
          error
      end
    else
      :ok
    end
  end

  defp summarize_request(request) when is_map(request) do
    %{
      messages_count: length(Map.get(request, :messages, [])),
      model: Map.get(request, :model),
      temperature: Map.get(request, :temperature),
      max_tokens: Map.get(request, :max_tokens)
    }
  end

  defp summarize_request(_), do: %{}

  defp display_capture(response, metadata) do
    IO.puts(format_capture(response, metadata))
  end

  defp format_capture(response, metadata) do
    """

    #{IO.ANSI.cyan()}━━━━━ CAPTURED RESPONSE ━━━━━#{IO.ANSI.reset()}
    #{IO.ANSI.yellow()}Provider:#{IO.ANSI.reset()} #{metadata["provider"]}
    #{IO.ANSI.yellow()}Endpoint:#{IO.ANSI.reset()} #{metadata["endpoint"]}
    #{IO.ANSI.yellow()}Time:#{IO.ANSI.reset()} #{metadata["captured_at"]}
    #{IO.ANSI.yellow()}Duration:#{IO.ANSI.reset()} #{metadata["response_time_ms"] || "N/A"}ms

    #{format_usage(response)}
    #{format_cost(metadata)}

    #{IO.ANSI.green()}Response:#{IO.ANSI.reset()}
    #{format_response_content(response)}
    #{IO.ANSI.cyan()}━━━━━━━━━━━━━━━━━━━━━━━━━━━#{IO.ANSI.reset()}
    """
  end

  defp format_usage(response) do
    case extract_usage(response) do
      nil ->
        ""

      usage ->
        """
        #{IO.ANSI.yellow()}Tokens:#{IO.ANSI.reset()} #{usage.input_tokens} in / #{usage.output_tokens} out / #{usage.total_tokens} total
        """
    end
  end

  defp format_cost(metadata) do
    case Map.get(metadata, "cost") do
      nil ->
        ""

      cost ->
        """
        #{IO.ANSI.yellow()}Cost:#{IO.ANSI.reset()} $#{Float.round(cost, 4)}
        """
    end
  end

  defp format_response_content(response) when is_map(response) do
    case extract_content(response) do
      nil -> Jason.encode!(response, pretty: true)
      content -> content
    end
  end

  defp format_response_content(response), do: inspect(response, pretty: true)

  defp extract_usage(response) when is_map(response) do
    # Try different response formats
    cond do
      # OpenAI format
      usage = Map.get(response, "usage") ->
        %{
          input_tokens: Map.get(usage, "prompt_tokens", 0),
          output_tokens: Map.get(usage, "completion_tokens", 0),
          total_tokens: Map.get(usage, "total_tokens", 0)
        }

      # Anthropic format
      usage = Map.get(response, "usage") ->
        %{
          input_tokens: Map.get(usage, "input_tokens", 0),
          output_tokens: Map.get(usage, "output_tokens", 0),
          total_tokens: Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
        }

      true ->
        nil
    end
  end

  defp extract_usage(_), do: nil

  defp extract_content(response) when is_map(response) do
    # Try to extract the actual message content
    cond do
      # OpenAI format
      choices = Map.get(response, "choices", []) ->
        case List.first(choices) do
          %{"message" => %{"content" => content}} -> content
          _ -> nil
        end

      # Anthropic format
      content = Map.get(response, "content", []) ->
        case List.first(content) do
          %{"text" => text} -> text
          _ -> nil
        end

      # Direct content
      content = Map.get(response, "content") ->
        content

      true ->
        nil
    end
  end

  defp extract_content(_), do: nil
end
