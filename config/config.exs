import Config

# Tesla Configuration
config :tesla, disable_deprecated_builder_warning: true

# ExLLM Configuration
config :ex_llm,
  environment: Mix.env(),
  # Caching strategy
  cache_strategy: ExLLM.Cache.Strategies.Production,
  # Global cache configuration
  cache_enabled: false,
  cache_persist_disk: false,
  cache_disk_path: "~/.cache/ex_llm_cache",
  # Debug logging configuration
  log_level: :warning,
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

# Set default logger level to warning in development
if Mix.env() == :dev do
  config :logger, level: :warning
end

if Mix.env() == :dev do
  # Enhanced logging for development
  config :ex_llm,
    log_level: :warning,
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
  # Test configuration is now centralized in ExLLM.Testing.Config
  # and applied in test_helper.exs for better maintainability
  #
  # Minimal config here to avoid duplication
  config :logger, level: :error
  config :ex_llm, startup_validation: %{enabled: false}

  # Filter out telemetry warnings in test
  config :logger,
    compile_time_purge_matching: [
      [message: "Failed to lookup telemetry handlers"]
    ]
end
