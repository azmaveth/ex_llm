defmodule ExLLM.Plugs.Providers.LMStudioParseStreamResponse do
  @moduledoc """
  Parses streaming responses from LM Studio API.

  This plug sets up chunk parsing for Server-Sent Events (SSE) format
  used by LM Studio's OpenAI-compatible API. It replaces the legacy
  StreamParseResponse module with the modern HTTP.Core-based approach.
  """

  use ExLLM.Plug
  alias ExLLM.Plugs.Providers.OpenAIParseStreamResponse

  @impl true
  def call(request, opts) do
    # LM Studio uses OpenAI-compatible format, so delegate to OpenAI parser
    OpenAIParseStreamResponse.call(request, opts)
  end
end
