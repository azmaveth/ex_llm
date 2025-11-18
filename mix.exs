defmodule ExLLM.MixProject do
  use Mix.Project

  @version "1.0.0-rc1"
  @description "[DEPRECATED] This library is no longer maintained. Please use req_llm by agentjido instead. Unified Elixir client library for Large Language Models (LLMs)"

  def project do
    [
      app: :ex_llm,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      deps: deps(),
      docs: docs(),
      source_url: "https://github.com/azmaveth/ex_llm",
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        "test.fast": :test,
        "test.unit": :test,
        "test.integration": :test,
        "test.ci": :test,
        "test.all": :test
      ],
      aliases: aliases(),
      dialyzer: [
        plt_apps: [
          :erts,
          :kernel,
          :stdlib,
          :crypto,
          :elixir,
          :logger,
          :telemetry,
          :jason,
          :req,
          :tesla,
          :hackney,
          :gun,
          :yaml_elixir,
          :ex_llm
        ],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      # Suppress compilation warnings in dev and test
      elixirc_options: elixirc_options(Mix.env())
    ]
  end

  def application do
    [
      extra_applications:
        [
          :logger,
          :runtime_tools,
          :telemetry,
          :jason,
          :req,
          :tesla,
          :hackney,
          :gun,
          :yaml_elixir
        ] ++ optional_applications(),
      mod: {ExLLM.Application, []}
    ]
  end

  # Include optional dependencies only if they are available
  defp optional_applications do
    []
    |> maybe_add_application(:bumblebee)
    |> maybe_add_application(:nx)
  end

  defp maybe_add_application(apps, app) do
    # Check if the dependency is actually available and loaded
    case Code.ensure_loaded?(app) do
      true -> [app | apps]
      false -> apps
    end
  end

  # Compiler options to suppress warnings
  defp elixirc_options(:test), do: [warnings_as_errors: false]
  defp elixirc_options(:dev), do: [warnings_as_errors: false]
  defp elixirc_options(_), do: []

  defp package do
    [
      name: "ex_llm",
      files: ~w(lib docs .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/azmaveth/ex_llm",
        "Docs" => "https://hexdocs.pm/ex_llm"
      },
      maintainers: ["azmaveth"]
    ]
  end

  defp deps do
    [
      # HTTP client for API calls
      {:req, "~> 0.5.0"},

      # JSON encoding/decoding
      {:jason, "~> 1.4"},

      # HTTP client with middleware support
      {:tesla, "~> 1.8"},

      # Telemetry instrumentation
      {:telemetry, "~> 1.0"},

      # WebSocket client for Live API
      {:gun, "~> 2.1"},

      # HTTP client for streaming (Tesla adapter)
      {:hackney, "~> 1.20"},

      # Configuration file parsing
      {:yaml_elixir, "~> 2.9"},

      # Structured outputs
      {:instructor, "~> 0.1.0"},

      # Dependencies for local model support via Bumblebee (optional)
      {:bumblebee, "~> 0.6.2", optional: true},
      {:nx, "~> 0.7", optional: true},
      # EXLA has compilation issues on newer macOS - uncomment if needed
      # {:exla, "~> 0.7", optional: true},
      # EMLX for Apple Silicon Metal acceleration
      # Excluded from Hex package until emlx is published
      # Users should add to their mix.exs: {:emlx, github: "elixir-nx/emlx", branch: "main"}
      # {:emlx, github: "elixir-nx/emlx", branch: "main", optional: true},

      # Development and documentation
      {:ex_doc, "~> 0.38.2", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:git_hooks, "~> 0.7", only: [:dev], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},

      # HTTP testing mock server
      {:bypass, "~> 2.1", only: :test},

      # Environment variable loading
      {:dotenv, "~> 3.1", only: [:dev, :test]}
    ]
  end

  defp docs do
    [
      main: "ExLLM",
      source_ref: "v#{@version}",
      source_url: "https://github.com/azmaveth/ex_llm",
      extras: [
        "README.md",
        "docs/API_REFERENCE.md",
        "docs/QUICKSTART.md",
        "docs/USER_GUIDE.md",
        "docs/TESTING.md",
        "docs/LOGGER.md",
        "docs/PROVIDER_CAPABILITIES.md",
        "guides/internal_modules.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: [
          "docs/QUICKSTART.md",
          "docs/USER_GUIDE.md",
          "docs/TESTING.md",
          "guides/internal_modules.md"
        ],
        References: [
          "docs/API_REFERENCE.md",
          "docs/LOGGER.md",
          "docs/PROVIDER_CAPABILITIES.md"
        ]
      ]
    ]
  end

  defp aliases do
    [
      # === CORE TESTING STRATEGY ===

      # Live API tests (refreshes cache, comprehensive)
      "test.live": [
        "cmd MIX_RUN_LIVE=true mix test --include live_api --include external --include integration"
      ],

      # Fast development tests (excludes API calls and slow tests)
      "test.fast": [
        "test --exclude live_api --exclude external --exclude integration --exclude slow"
      ],

      # Unit tests only (pure logic, no external dependencies)
      "test.unit": ["test --only unit"],

      # Integration tests (requires API keys)
      "test.integration": ["test --include integration --include external"],

      # All tests including slow/comprehensive suites
      "test.all": [
        "test --include slow --include very_slow --include integration --include external"
      ],

      # === PROVIDER-SPECIFIC TESTING ===

      # Major cloud providers (covers 80% of usage)
      "test.anthropic": ["test --only provider:anthropic"],
      "test.openai": ["test --only provider:openai"],
      "test.gemini": ["test --only provider:gemini"],

      # Local providers (for offline development)
      "test.local": [
        "test --only provider:ollama --only provider:lmstudio"
      ],

      # Bumblebee tests (requires explicit opt-in due to large model downloads)
      "test.bumblebee": [
        "cmd EX_LLM_START_MODELLOADER=true mix test --only provider:bumblebee --include requires_deps"
      ],

      # Additional cloud providers
      "test.groq": ["test --only provider:groq"],
      "test.mistral": ["test --only provider:mistral"],
      "test.xai": ["test --only provider:xai"],
      "test.perplexity": ["test --only provider:perplexity"],
      "test.openrouter": ["test --only provider:openrouter"],

      # === SPECIALIZED TESTING ===

      # Mock tests (offline, no external dependencies)
      "test.mock": [
        "test --exclude live_api --exclude external --exclude requires_api_key --exclude requires_service"
      ],

      # Smoke tests (quick validation)
      "test.smoke": ["test --only unit --max-cases 10"],

      # All live API tests
      "test.live.all": ["test --only live_api --include external"],

      # OAuth2 authentication tests
      "test.oauth2": ["test --only requires_oauth"],

      # CI/CD pipeline tests
      "test.ci": [
        "test --exclude wip --exclude flaky --exclude quota_sensitive --exclude very_slow --exclude requires_api_key --exclude integration --exclude external --exclude live_api --exclude requires_service --exclude local_only --exclude oauth2 --exclude requires_oauth"
      ],

      # === CAPABILITY-SPECIFIC TESTING ===

      # Core chat functionality
      "test.capability.chat": ["test --only capability:chat"],

      # Streaming responses
      "test.capability.streaming": ["test --only capability:streaming"],

      # Model listing
      "test.capability.list_models": ["test --only capability:list_models"],

      # Function calling / Tool use
      "test.capability.function_calling": ["test --only capability:function_calling"],

      # Vision / Image understanding
      "test.capability.vision": ["test --only capability:vision"],

      # Text embeddings
      "test.capability.embeddings": ["test --only capability:embeddings"],

      # Cost tracking
      "test.capability.cost_tracking": ["test --only capability:cost_tracking"],

      # JSON mode / Structured outputs
      "test.capability.json_mode": ["test --only capability:json_mode"],

      # System prompt support
      "test.capability.system_prompt": ["test --only capability:system_prompt"],

      # Temperature control
      "test.capability.temperature": ["test --only capability:temperature"],

      # === CACHE MANAGEMENT ===

      "cache.clear": ["cmd rm -rf test/cache/*"],
      "cache.status": ["run -e ExLLM.Testing.Cache.status()"],

      # === RESPONSE CAPTURE ===

      "captures.list": ["ex_llm.captures list"],
      "captures.show": ["ex_llm.captures show"],
      "captures.clear": ["ex_llm.captures clear"],
      "captures.stats": ["ex_llm.captures stats"],

      # === TEST MATRIX ===

      # Run tests across all configured providers
      "test.matrix": ["ex_llm.test_matrix"],

      # Run tests across major providers
      "test.matrix.major": ["ex_llm.test_matrix --providers openai,anthropic,gemini,groq"],

      # Test specific capability across all providers
      "test.matrix.vision": ["ex_llm.test_matrix --capability vision"],
      "test.matrix.streaming": ["ex_llm.test_matrix --capability streaming"],
      "test.matrix.function_calling": ["ex_llm.test_matrix --capability function_calling"],

      # Run integration tests across providers
      "test.matrix.integration": ["ex_llm.test_matrix --only integration"]
    ]
  end
end
