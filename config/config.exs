import Config

# ExLLM Configuration
config :ex_llm,
  # Global cache configuration
  cache_enabled: false,
  cache_persist_disk: false,
  cache_disk_path: "~/.cache/ex_llm_cache",
  # Debug logging configuration
  log_level: :info,
  log_components: %{
    requests: true,
    responses: true,
    streaming: false,
    retries: true,
    cache: false,
    models: true
  },
  log_redaction: %{
    api_keys: true,
    content: false
  }

# Logger Configuration
config :logger, :console,
  metadata: [
    :request_id,
    :provider,
    :model,
    :cost,
    # Additional metadata for adapters and retry logic
    :attempts,
    :reason,
    :error,
    :duration_ms,
    :status,
    :body
  ]

if Mix.env() == :dev do
  # Enhanced logging for development
  config :ex_llm,
    log_level: :debug,
    log_components: %{
      requests: true,
      responses: true,
      streaming: true,
      retries: true,
      cache: true,
      models: true
    },
    log_redaction: %{
      api_keys: true,
      content: false
    }

  config :git_hooks,
    auto_install: true,
    verbose: true,
    hooks: [
      pre_commit: [
        tasks: [
          {:cmd, "mix format"},
          {:cmd, "mix compile --warnings-as-errors"}
        ]
      ],
      pre_push: [
        tasks: [
          {:cmd, "mix format --check-formatted"},
          {:cmd, "mix credo --config-file .credo.exs --only warning"},
          # {:cmd, "mix dialyzer"}, # Temporarily disabled - PLT issues
          {:cmd, "mix test --exclude integration"},
          {:cmd, "mix sobelow --skip"}
        ]
      ]
    ]
end

if Mix.env() == :test do
  # Reduce log noise during tests
  config :logger, level: :warning

  # Test-specific configuration
  config :ex_llm,
    cache_enabled: true,
    cache_persist_disk: false,
    # Minimal logging during tests
    log_level: :error,
    log_components: %{
      requests: false,
      responses: false,
      streaming: false,
      retries: false,
      cache: false,
      models: false
    }
end
