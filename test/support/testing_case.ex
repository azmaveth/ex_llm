defmodule ExLLM.Testing.Case do
  @moduledoc """
  Custom test case template for ExLLM tests.

  This module provides automatic requirement checking based on test tags,
  allowing tests to skip dynamically with meaningful messages when their
  requirements aren't met.

  ## Usage

      defmodule MyTest do
        use ExLLM.Testing.Case, async: true
        
        @tag :requires_api_key
        @tag provider: :openai
        test "calls OpenAI API" do
          # Test will automatically skip if OPENAI_API_KEY is not set
        end
      end
  """

  # Provider API key mappings from centralized config
  @provider_api_keys ExLLM.Testing.Config.provider_api_keys()

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use ExUnit.Case, unquote(opts)
      import ExLLM.Testing.Case
      import ExLLM.Testing.TestHelpers
    end
  end

  @doc """
  Check if test requirements are met. Call this at the beginning of each test.

  ## Examples

      test "my test", context do
        check_test_requirements!(context)
        # ... rest of test
      end
  """
  def check_test_requirements!(context) do
    tags = context

    cond do
      # Check API key requirements
      tags[:requires_api_key] ->
        check_api_key_requirement!(tags)

      # Check OAuth requirements
      tags[:requires_oauth] ->
        check_oauth_requirement!(tags)

      # Check service requirements
      Map.has_key?(tags, :requires_service) ->
        check_service_requirement!(tags)

      # Check resource requirements
      Map.has_key?(tags, :requires_resource) ->
        check_resource_requirement!(tags)

      # Check environment requirements
      Map.has_key?(tags, :requires_env) ->
        check_env_requirement!(tags)

      true ->
        :ok
    end
  end

  defp check_api_key_requirement!(tags) do
    provider = tags[:provider] || infer_provider_from_test(tags)

    case check_provider_api_key(provider) do
      :ok ->
        :ok

      {:skip, reason} ->
        IO.puts("\n  Skipped: #{reason}")
        flunk(reason)
    end
  end

  defp check_provider_api_key(nil) do
    {:skip, "Test requires API key but no provider specified"}
  end

  defp check_provider_api_key(provider) do
    case Map.get(@provider_api_keys, provider) do
      nil ->
        check_generic_provider_api_key(provider)

      env_vars ->
        check_known_provider_api_key(env_vars, provider)
    end
  end

  defp check_generic_provider_api_key(provider) do
    env_var = "#{String.upcase(to_string(provider))}_API_KEY"

    if System.get_env(env_var) do
      :ok
    else
      {:skip, "Test requires #{env_var} environment variable"}
    end
  end

  defp check_known_provider_api_key(env_vars, _provider) do
    if Enum.any?(env_vars, &System.get_env/1) do
      :ok
    else
      env_var_list = Enum.join(env_vars, " or ")
      {:skip, "Test requires #{env_var_list} environment variable"}
    end
  end

  defp check_oauth_requirement!(tags) do
    provider = tags[:provider] || infer_provider_from_test(tags)

    result =
      case provider do
        :gemini ->
          check_gemini_oauth()

        _ ->
          {:skip, "OAuth2 not implemented for provider: #{provider}"}
      end

    case result do
      :ok ->
        :ok

      {:skip, reason} ->
        IO.puts("\n  Skipped: #{reason}")
        flunk(reason)
    end
  end

  defp check_service_requirement!(tags) do
    service = tags[:requires_service]

    case check_service_availability(service) do
      :ok ->
        :ok

      {:skip, reason} ->
        IO.puts("\n  Skipped: #{reason}")
        flunk(reason)
    end
  end

  defp check_service_availability(service) do
    try do
      do_check_service(service)
    rescue
      _ ->
        service_name = if is_atom(service), do: service, else: inspect(service)
        {:skip, "Test requires #{service_name} service to be running (connection failed)"}
    end
  end

  defp do_check_service(:ollama) do
    case Req.get("http://localhost:11434/api/tags") do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        {:skip, "Test requires Ollama service to be running on localhost:11434"}
    end
  end

  defp do_check_service(:lmstudio) do
    case Req.get("http://localhost:1234/v1/models") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      _ ->
        {:skip, "Test requires LM Studio to be running on localhost:1234"}
    end
  end

  defp do_check_service(service) when is_atom(service) do
    {:skip, "Test requires #{service} service to be running"}
  end

  defp do_check_service(service) do
    {:skip, "Invalid service requirement: #{inspect(service)}"}
  end

  defp check_resource_requirement!(tags) do
    resource = tags[:requires_resource]

    result =
      case resource do
        :tuned_model ->
          if System.get_env("TEST_TUNED_MODEL") do
            :ok
          else
            {:skip, "Test requires a tuned model - set TEST_TUNED_MODEL env var with model ID"}
          end

        :corpus ->
          if System.get_env("TEST_CORPUS_NAME") do
            :ok
          else
            {:skip, "Test requires pre-existing corpus - set TEST_CORPUS_NAME env var"}
          end

        :document ->
          if System.get_env("TEST_DOCUMENT_NAME") do
            :ok
          else
            {:skip, "Test requires pre-existing document - set TEST_DOCUMENT_NAME env var"}
          end

        resource when is_atom(resource) ->
          {:skip, "Test requires resource: #{resource}"}

        _ ->
          {:skip, "Invalid resource requirement: #{inspect(resource)}"}
      end

    case result do
      :ok ->
        :ok

      {:skip, reason} ->
        IO.puts("\n  Skipped: #{reason}")
        flunk(reason)
    end
  end

  defp check_env_requirement!(tags) do
    env_vars =
      case tags[:requires_env] do
        var when is_binary(var) -> [var]
        vars when is_list(vars) -> vars
        _ -> []
      end

    missing = Enum.filter(env_vars, &(System.get_env(&1) == nil))

    result =
      if Enum.empty?(missing) do
        :ok
      else
        vars_str = Enum.join(missing, ", ")
        {:skip, "Test requires environment variables: #{vars_str}"}
      end

    case result do
      :ok ->
        :ok

      {:skip, reason} ->
        IO.puts("\n  Skipped: #{reason}")
        flunk(reason)
    end
  end

  defp check_gemini_oauth do
    if Code.ensure_loaded?(ExLLM.Testing.GeminiOAuth2Helper) do
      try do
        if apply(ExLLM.Testing.GeminiOAuth2Helper, :oauth_available?, []) do
          case apply(ExLLM.Testing.GeminiOAuth2Helper, :get_valid_token, []) do
            {:ok, _token} ->
              :ok

            _ ->
              {:skip, "Test requires valid OAuth2 token - run: elixir scripts/setup_oauth2.exs"}
          end
        else
          {:skip, "Test requires OAuth2 authentication - run: elixir scripts/setup_oauth2.exs"}
        end
      rescue
        _ ->
          {:skip, "OAuth2 test helper not fully loaded"}
      end
    else
      {:skip, "GeminiOAuth2Helper not available - OAuth2 tests disabled"}
    end
  end

  defp infer_provider_from_test(context) do
    module_name = to_string(context.module)

    cond do
      String.contains?(module_name, "Anthropic") -> :anthropic
      String.contains?(module_name, "OpenAI") -> :openai
      String.contains?(module_name, "Gemini") -> :gemini
      String.contains?(module_name, "Ollama") -> :ollama
      String.contains?(module_name, "OpenRouter") -> :openrouter
      String.contains?(module_name, "Mistral") -> :mistral
      String.contains?(module_name, "Perplexity") -> :perplexity
      String.contains?(module_name, "Groq") -> :groq
      String.contains?(module_name, "XAI") -> :xai
      String.contains?(module_name, "LMStudio") -> :lmstudio
      true -> nil
    end
  end

  @doc """
  Get OAuth token from context if available.

  ## Examples

      test "uses oauth", context do
        check_test_requirements!(context)
        oauth_token = get_oauth_token(context)
        # ... use token
      end
  """
  def get_oauth_token(context) do
    # This will be set by OAuth requirement check if available
    context[:oauth_token]
  end
end
