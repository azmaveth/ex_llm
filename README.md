# ExLLM

> **⚠️ DEPRECATED - NO LONGER MAINTAINED**
>
> **This library is no longer actively maintained.**
>
> **Please use [req_llm](https://github.com/agentjido/req_llm) by agentjido instead.**
>
> `req_llm` provides a modern, actively maintained alternative with similar functionality and better integration with the Elixir ecosystem.

[![Hex.pm](https://img.shields.io/hexpm/v/ex_llm.svg)](https://hex.pm/packages/ex_llm)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ex_llm/)
[![License](https://img.shields.io/hexpm/l/ex_llm.svg)](https://github.com/azmaveth/ex_llm/blob/main/LICENSE)
[![CI](https://github.com/azmaveth/ex_llm/actions/workflows/ci.yml/badge.svg)](https://github.com/azmaveth/ex_llm/actions/workflows/ci.yml)

**A unified Elixir client for interfacing with multiple Large Language Model (LLM) providers.**

`ExLLM` provides a single, consistent API to interact with a growing list of LLM providers. It abstracts away the complexities of provider-specific request formats, authentication, and error handling, allowing you to focus on building features.

## Key Features

- **Unified API:** Use a single `ExLLM.chat/2` interface for all supported providers, dramatically reducing boilerplate code
- **Broad Provider Support:** Seamlessly switch between models from 14+ major providers
- **Streaming Support:** Handle real-time responses for chat completions using Elixir's native streaming
- **Standardized Error Handling:** Get predictable `{:error, reason}` tuples for common failure modes
- **Session Management:** Built-in conversation state tracking and persistence
- **Function Calling:** Unified tool use interface across providers that support it
- **Multimodal Support:** Vision, audio, and document processing capabilities where available
- **Minimal Overhead:** Designed as a thin, efficient client layer with focus on performance
- **Extensible Architecture:** Adding new providers is straightforward through clean delegation patterns

## Feature Status

✅ **Production Ready:** Core chat, streaming, sessions, providers, function calling, cost tracking  
🚧 **Under Development:** Context management, model capabilities API, configuration validation  

See [FEATURE_STATUS.md](FEATURE_STATUS.md) for detailed testing results and API status.

## Supported Providers

ExLLM supports **14 providers** with access to hundreds of models:

- **Anthropic Claude** - Claude 4, 3.7, 3.5, and 3 series models
- **OpenAI** - GPT-4.1, o1 reasoning models, GPT-4o, and GPT-3.5 series
- **AWS Bedrock** - Multi-provider access (Anthropic, Amazon Nova, Meta Llama, etc.)
- **Google Gemini** - Gemini 2.5, 2.0, and 1.5 series with multimodal support
- **OpenRouter** - Access to hundreds of models from multiple providers
- **Groq** - Ultra-fast inference with Llama 4, DeepSeek R1, and more
- **X.AI** - Grok models with web search and reasoning capabilities
- **Mistral AI** - Mistral Large, Pixtral, and specialized code models
- **Perplexity** - Search-enhanced language models
- **Ollama** - Local model runner (any model in your installation)
- **LM Studio** - Local model server with OpenAI-compatible API
- **Bumblebee** - Local model inference with Elixir/Nx (optional dependency)
- **Mock Adapter** - For testing and development

## Installation

Add `ex_llm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_llm, "~> 1.0.0-rc1"},
    
    # Optional: For local model inference via Bumblebee
    {:bumblebee, "~> 0.6.2", optional: true},
    {:nx, "~> 0.7", optional: true},
    
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

## Configuration

You can configure providers in your `config/config.exs`:

```elixir
import Config

config :ex_llm,
  default_provider: :openai,
  providers: [
    openai: [api_key: System.get_env("OPENAI_API_KEY")],
    anthropic: [api_key: System.get_env("ANTHROPIC_API_KEY")],
    gemini: [api_key: System.get_env("GEMINI_API_KEY")]
  ]
```

## Testing

The test suite includes both unit tests and integration tests. Integration tests that make live API calls are tagged and excluded by default.

To run unit tests only:
```bash
mix test
```

To run integration tests (requires API keys):
```bash
mix test --include integration
```

To run tests with intelligent caching for faster development:
```bash
mix test.live  # Runs with test response caching enabled
```

## Architecture

ExLLM uses a clean, modular architecture that separates concerns while maintaining a unified API:

### Core Modules

- **`ExLLM`** - Main entry point with unified API
- **`ExLLM.API.Delegator`** - Central delegation engine for provider routing
- **`ExLLM.API.Capabilities`** - Provider capability registry
- **`ExLLM.Pipeline`** - Phoenix-style pipeline for request processing

### Specialized Modules

- **`ExLLM.Embeddings`** - Vector operations and similarity calculations
- **`ExLLM.Assistants`** - OpenAI Assistants API for stateful agents
- **`ExLLM.KnowledgeBase`** - Document management and semantic search
- **`ExLLM.Builder`** - Fluent interface for chat construction
- **`ExLLM.Session`** - Conversation state management

### Benefits

- **Clean Separation**: Each module has a single, focused responsibility
- **Easy Extension**: Adding providers requires changes in just 1-2 files
- **Performance**: Delegation adds minimal overhead
- **Maintainability**: Clear boundaries between components

## Documentation

📚 **[Quick Start Guide](docs/QUICKSTART.md)** - Get up and running in 5 minutes  
📖 **[User Guide](docs/USER_GUIDE.md)** - Comprehensive documentation of all features  
🏗️ **[Architecture Guide](docs/ARCHITECTURE.md)** - Clean layered architecture and namespace organization  
🔌 **[Pipeline Architecture](docs/PIPELINE_ARCHITECTURE.md)** - Phoenix-style plug system and extensibility  
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
- **Test Caching**: Intelligent response caching for faster development
- **Model Discovery**: Query available models and capabilities
- **OAuth2 Integration**: Complete OAuth2 flow for Gemini and other providers

### Additional Documentation

- 📋 **[Unified API Guide](docs/UNIFIED_API_GUIDE.md)** - Complete unified API documentation
- 🔄 **[Migration Guide](MIGRATION_GUIDE_V1.md)** - Upgrading to v1.0.0
- ✅ **[Release Checklist](RELEASE_CHECKLIST.md)** - Automated release process
- 📚 **[API Reference](https://hexdocs.pm/ex_llm)** - Detailed API documentation on HexDocs

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- 📖 **Documentation**: [User Guide](docs/USER_GUIDE.md)
- 🐛 **Issues**: [GitHub Issues](https://github.com/azmaveth/ex_llm/issues)
- 💬 **Discussions**: [GitHub Discussions](https://github.com/azmaveth/ex_llm/discussions)
