defmodule ExLLM.Providers.Gemini.RetrievalPermissionsTest do
  use ExUnit.Case, async: false

  alias ExLLM.Providers.Gemini.Permissions

  alias ExLLM.Providers.Gemini.Permissions.{
    ListPermissionsResponse,
    Permission
  }

  @api_key System.get_env("GEMINI_API_KEY") || "test-key"

  describe "corpus permissions" do
    @describetag :integration
    test "creates a corpus permission for a user" do
      permission = %{
        grantee_type: :USER,
        email_address: "user@example.com",
        role: :READER
      }

      result = Permissions.create_permission("corpora/test-corpus", permission, api_key: @api_key)

      case result do
        {:error, %{status: status}} when status in [400, 401, 403, 404] ->
          # Expected error for non-existent corpus or auth issues
          :ok

        {:error, %{reason: :network_error, message: message}} when is_binary(message) ->
          # OAuth2 authentication error is expected when using API keys
          assert String.contains?(message, "OAuth2") or
                   String.contains?(message, "CREDENTIALS_MISSING")

        other ->
          flunk("Expected error response, got: #{inspect(other)}")
      end
    end

    test "creates a corpus permission for everyone" do
      permission = %{
        grantee_type: :EVERYONE,
        role: :READER
      }

      # Using non-existent corpus - should return proper error
      result = Permissions.create_permission("corpora/test-corpus", permission, api_key: @api_key)

      case result do
        {:error, %{status: status}} when status in [400, 401, 403, 404] ->
          # Expected error for non-existent corpus or auth issues
          :ok

        {:error, %{reason: :network_error, message: message}} when is_binary(message) ->
          # OAuth2 authentication error is expected when using API keys
          assert String.contains?(message, "OAuth2") or
                   String.contains?(message, "CREDENTIALS_MISSING")

        other ->
          flunk("Expected error response, got: #{inspect(other)}")
      end
    end

    test "lists corpus permissions" do
      result = Permissions.list_permissions("corpora/test-corpus", api_key: @api_key)

      case result do
        {:ok, %ListPermissionsResponse{} = response} ->
          # Unexpected success, but acceptable
          assert is_list(response.permissions)

        {:error, %{reason: :network_error, message: message}} when is_binary(message) ->
          # OAuth2 authentication error is expected when using API keys
          assert String.contains?(message, "OAuth2") or
                   String.contains?(message, "CREDENTIALS_MISSING")

        {:error, %{status: status}} when status in [400, 401, 403, 404] ->
          # Expected error for auth or non-existent corpus
          :ok

        other ->
          flunk("Expected success or error response, got: #{inspect(other)}")
      end
    end

    test "gets specific corpus permission" do
      result =
        Permissions.get_permission("corpora/test-corpus/permissions/invalid", api_key: @api_key)

      case result do
        {:error, %{status: status}} when status in [400, 401, 403, 404] ->
          # Expected error for non-existent permission or auth issues
          :ok

        {:error, %{reason: :network_error, message: message}} when is_binary(message) ->
          # OAuth2 authentication error is expected when using API keys
          assert String.contains?(message, "OAuth2") or
                   String.contains?(message, "CREDENTIALS_MISSING")

        other ->
          flunk("Expected error response, got: #{inspect(other)}")
      end
    end

    test "updates corpus permission role" do
      update = %{role: :WRITER}

      result =
        Permissions.update_permission(
          "corpora/test-corpus/permissions/invalid",
          update,
          api_key: @api_key,
          update_mask: "role"
        )

      case result do
        {:error, %{status: status}} when status in [400, 401, 403, 404] ->
          # Expected error for non-existent permission or auth issues
          :ok

        {:error, %{reason: :network_error, message: message}} when is_binary(message) ->
          # OAuth2 authentication error is expected when using API keys
          assert String.contains?(message, "OAuth2") or
                   String.contains?(message, "CREDENTIALS_MISSING")

        other ->
          flunk("Expected error response, got: #{inspect(other)}")
      end
    end

    test "deletes corpus permission" do
      result =
        Permissions.delete_permission("corpora/test-corpus/permissions/invalid",
          api_key: @api_key
        )

      case result do
        {:error, %{status: status}} when status in [400, 401, 403, 404] ->
          # Expected error for non-existent permission or auth issues
          :ok

        {:error, %{reason: :network_error, message: message}} when is_binary(message) ->
          # OAuth2 authentication error is expected when using API keys
          assert String.contains?(message, "OAuth2") or
                   String.contains?(message, "CREDENTIALS_MISSING")

        other ->
          flunk("Expected error response, got: #{inspect(other)}")
      end
    end
  end

  describe "permission validation for corpus operations" do
    test "validates corpus parent format" do
      # Valid corpus format should pass validation
      assert :ok = Permissions.validate_parent("corpora/my-corpus")

      # Empty parent should fail
      assert {:error, _} = Permissions.validate_parent("")
    end

    test "validates permission parameters" do
      # Valid permission
      permission = %{
        grantee_type: :USER,
        email_address: "user@example.com",
        role: :READER
      }

      assert :ok = Permissions.validate_create_permission(permission)

      # Invalid role
      invalid_permission = %{
        grantee_type: :USER,
        email_address: "user@example.com",
        role: :INVALID
      }

      assert {:error, _} = Permissions.validate_create_permission(invalid_permission)

      # Missing email for USER type
      missing_email = %{
        grantee_type: :USER,
        role: :READER
      }

      assert {:error, _} = Permissions.validate_create_permission(missing_email)

      # EVERYONE type doesn't need email
      everyone_permission = %{
        grantee_type: :EVERYONE,
        role: :READER
      }

      assert :ok = Permissions.validate_create_permission(everyone_permission)
    end

    test "validates role hierarchy" do
      # All valid roles should be accepted
      for role <- [:READER, :WRITER, :OWNER] do
        permission = %{
          grantee_type: :EVERYONE,
          role: role
        }

        assert :ok = Permissions.validate_create_permission(permission)
      end
    end
  end

  describe "struct definitions and parsing" do
    test "Permission struct handles corpus permissions" do
      permission = %Permission{
        name: "corpora/test-corpus/permissions/permission-123",
        grantee_type: :USER,
        email_address: "user@example.com",
        role: :READER
      }

      assert permission.name == "corpora/test-corpus/permissions/permission-123"
      assert permission.grantee_type == :USER
      assert permission.email_address == "user@example.com"
      assert permission.role == :READER
    end

    test "Permission.from_json parses corpus permission response" do
      json = %{
        "granteeType" => "GROUP",
        "emailAddress" => "group@example.com",
        "name" => "corpora/test-corpus/permissions/permission-456",
        "role" => "WRITER"
      }

      permission = Permission.from_json(json)

      assert permission.name == "corpora/test-corpus/permissions/permission-456"
      assert permission.grantee_type == :GROUP
      assert permission.email_address == "group@example.com"
      assert permission.role == :WRITER
    end

    test "Permission.to_json creates proper request body" do
      permission = %Permission{
        grantee_type: :EVERYONE,
        role: :READER
      }

      json = Permission.to_json(permission)

      assert json["granteeType"] == "EVERYONE"
      assert json["role"] == "READER"
      refute Map.has_key?(json, "emailAddress")
    end

    test "ListPermissionsResponse handles corpus permissions" do
      json = %{
        "permissions" => [
          %{
            "granteeType" => "USER",
            "emailAddress" => "user1@example.com",
            "name" => "corpora/test-corpus/permissions/perm-1",
            "role" => "READER"
          },
          %{
            "granteeType" => "EVERYONE",
            "name" => "corpora/test-corpus/permissions/perm-2",
            "role" => "READER"
          }
        ],
        "nextPageToken" => "next-token"
      }

      response = ListPermissionsResponse.from_json(json)

      assert length(response.permissions) == 2
      assert response.next_page_token == "next-token"

      [perm1, perm2] = response.permissions
      assert perm1.grantee_type == :USER
      assert perm1.email_address == "user1@example.com"
      assert perm2.grantee_type == :EVERYONE
      assert perm2.email_address == nil
    end
  end

  describe "authentication methods" do
    @describetag :integration
    test "supports API key authentication for corpus permissions" do
      permission = %{
        grantee_type: :EVERYONE,
        role: :READER
      }

      # API key auth should fail with 401 for permissions API
      result = Permissions.create_permission("corpora/test-corpus", permission, api_key: @api_key)
      assert {:error, error} = result

      assert error.message =~ "API keys are not supported" or
               error.message =~ "CREDENTIALS_MISSING"
    end

    test "supports OAuth2 authentication for corpus permissions" do
      permission = %{
        grantee_type: :EVERYONE,
        role: :READER
      }

      # Invalid OAuth token should fail with 401
      result =
        Permissions.create_permission("corpora/test-corpus", permission,
          oauth_token: "invalid-token"
        )

      assert {:error, error} = result

      assert error.message =~ "invalid authentication credentials" or
               error.message =~ "UNAUTHENTICATED"
    end
  end
end
