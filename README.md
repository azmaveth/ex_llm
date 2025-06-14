# ExLLM

A unified Elixir client for Large Language Models with intelligent test caching, comprehensive provider support, and advanced developer tooling.

> ⚠️ **Alpha Quality Software**: This library is in early development. APIs may change without notice until version 1.0.0 is released. Use in production at your own risk.

## What's New in v0.7.0

- **🚀 Advanced Test Caching System**: 25x faster integration tests with intelligent response caching
- **🏷️ Comprehensive Test Tagging**: Semantic test organization with 138 skip tags replaced by meaningful tags
- **⚡ Mix Test Aliases**: 24 new aliases for targeted testing (provider-specific, tag-based, capability-based)
- **🤖 Smart Test Detection**: Automatic requirement checking with ExLLM.Case module
- **📊 Cache Management**: Built-in cache analytics, TTL management, and cleanup tools

## Features

### 🔗 **Core API**
- **Unified Interface**: Single API for 14+ LLM providers and 300+ models
- **Streaming Support**: Real-time streaming responses with error recovery
- **Session Management**: Built-in conversation state tracking and persistence
- **Function Calling**: Unified tool use interface across all providers
- **Multimodal Support**: Vision, audio, and document processing capabilities

### 📊 **Developer Experience**
- **Intelligent Test Caching**: 25x faster integration tests with smart response caching
- **Comprehensive Test Tagging**: Semantic organization with provider, capability, and requirement tags
- **Mix Test Aliases**: 24 targeted testing commands (e.g., `mix test.anthropic`, `mix test.streaming`)
- **Automatic Requirement Checking**: Dynamic test skipping with meaningful error messages
- **Cost Tracking**: Automatic cost calculation and token usage monitoring

### 🎯 **Advanced Features**
- **Complete Gemini API**: All 15 Gemini APIs including Live API with WebSocket support
- **OAuth2 Authentication**: Full OAuth2 support for provider APIs requiring user auth
- **Structured Outputs**: Schema validation and retries via Instructor integration
- **Model Discovery**: Query and compare capabilities across all providers
- **Response Caching**: Production-ready caching with TTL, fallback strategies, and analytics
- **Type Safety**: Comprehensive typespecs and structured data throughout

## Supported Providers

ExLLM supports **14 providers** with access to **300+ models**:

- **Anthropic Claude** - Claude 4, 3.7, 3.5, and 3 series models
- **OpenAI** - GPT-4.1, o1 reasoning models, GPT-4o, and GPT-3.5 series
- **AWS Bedrock** - Multi-provider access (Anthropic, Amazon Nova, Meta Llama, etc.)
- **Google Gemini** - Gemini 2.5, 2.0, and 1.5 series with multimodal support
- **OpenRouter** - Access to 300+ models from multiple providers
- **Groq** - Ultra-fast inference with Llama 4, DeepSeek R1, and more
- **X.AI** - Grok models with web search and reasoning capabilities
- **Mistral AI** - Mistral Large, Pixtral, and specialized code models
- **Perplexity** - Search-enhanced language models
- **Ollama** - Local model runner (any model in your installation)
- **LM Studio** - Local model server with OpenAI-compatible API
- **Bumblebee** - Local model inference with Elixir/Nx
- **Mock Adapter** - For testing and development

## Installation

Add `ex_llm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_llm, "~> 0.7.0"},
    
    # Optional hardware acceleration backends (choose one):
    {:exla, "~> 0.7", optional: true},
    
    # Optional: For Apple Silicon Metal acceleration
    {:emlx, github: "elixir-nx/emlx", branch: "main", optional: true}
  ]
end
```

## Quick Start

### 1. Configuration

Set your API keys as environment variables:

```bash
export ANTHROPIC_API_KEY="your-anthropic-key"
export OPENAI_API_KEY="your-openai-key"
export GROQ_API_KEY="your-groq-key"
# ... other provider keys as needed
```

### 2. Basic Usage

```elixir
# Single completion
{:ok, response} = ExLLM.chat(:anthropic, [
  %{role: "user", content: "Explain quantum computing in simple terms"}
])

IO.puts(response.content)
# Cost automatically tracked: response.cost

# Streaming response
ExLLM.chat_stream(:openai, [
  %{role: "user", content: "Write a short story"}
], fn chunk ->
  IO.write(chunk.delta)
end)

# With session management
{:ok, session} = ExLLM.Session.new(:groq)
{:ok, session, response} = ExLLM.Session.chat(session, "Hello!")
{:ok, session, response} = ExLLM.Session.chat(session, "How are you?")

# Multimodal with vision
{:ok, response} = ExLLM.chat(:gemini, [
  %{role: "user", content: [
    %{type: "text", text: "What's in this image?"},
    %{type: "image", image: %{data: base64_image, media_type: "image/jpeg"}}
  ]}
])
```

### 3. Testing with Caching

```elixir
# Run integration tests with automatic caching
mix test.anthropic --include live_api

# Manage test cache
mix ex_llm.cache stats
mix ex_llm.cache clean --older-than 7d
```

## Documentation

📚 **[Quick Start Guide](docs/QUICKSTART.md)** - Get up and running in 5 minutes  
📖 **[User Guide](docs/USER_GUIDE.md)** - Comprehensive documentation of all features  
🔧 **[Logger Guide](docs/LOGGER.md)** - Debug logging and troubleshooting  
⚡ **[Provider Capabilities](docs/PROVIDER_CAPABILITIES.md)** - Feature comparison across providers  
🧪 **[Testing Guide](docs/TESTING.md)** - Comprehensive testing system with semantic tagging and caching

### Key Topics Covered in the User Guide

- **Configuration**: Environment variables, config files, and provider setup
- **Chat Completions**: Messages, parameters, and response handling
- **Streaming**: Real-time responses with error recovery and coordinator
- **Session Management**: Conversation state and persistence
- **Function Calling**: Tool use and structured interactions across providers
- **Vision & Multimodal**: Image, audio, and document processing
- **Cost Tracking**: Automatic cost calculation and token estimation
- **Error Handling**: Retry logic and error recovery strategies
- **Test Caching**: Intelligent response caching with 25x speed improvements
- **Test Organization**: Semantic tagging and targeted test execution
- **Model Discovery**: Query available models and capabilities
- **OAuth2 Integration**: Complete OAuth2 flow for Gemini and other providers

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

- 📖 **Documentation**: [User Guide](docs/USER_GUIDE.md)
- 🐛 **Issues**: [GitHub Issues](https://github.com/azmaveth/ex_llm/issues)
- 💬 **Discussions**: [GitHub Discussions](https://github.com/azmaveth/ex_llm/discussions)