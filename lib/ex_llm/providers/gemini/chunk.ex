defmodule ExLLM.Providers.Gemini.Chunk do
  @dialyzer :no_match

  @moduledoc """
  Chunk management for Gemini's Semantic Retrieval API.

  A Chunk is a subpart of a Document that is treated as an independent unit for 
  the purposes of vector representation and storage. A Corpus can have a maximum 
  of 1 million Chunks.

  ## Authentication

  Chunk operations require authentication. Both API key and OAuth2 are supported:

  - **API key**: Most operations work with API keys
  - **OAuth2**: Required for some operations, especially those involving user-specific data

  ## Examples

      # Create a chunk
      {:ok, chunk} = Chunk.create_chunk(
        "corpora/my-corpus/documents/my-doc",
        %{data: %{string_value: "This is chunk content."}},
        api_key: "your-api-key"
      )
      
      # List chunks with pagination
      {:ok, result} = Chunk.list_chunks(
        "corpora/my-corpus/documents/my-doc",
        page_size: 20,
        api_key: "your-api-key"
      )
      
      # Update chunk content
      {:ok, updated} = Chunk.update_chunk(
        "corpora/my-corpus/documents/my-doc/chunks/my-chunk",
        %{data: %{string_value: "Updated content"}},
        "data",
        api_key: "your-api-key"
      )
      
      # Batch create chunks
      {:ok, result} = Chunk.batch_create_chunks(
        "corpora/my-corpus/documents/my-doc",
        [
          %{chunk: %{data: %{string_value: "First chunk"}}},
          %{chunk: %{data: %{string_value: "Second chunk"}}}
        ],
        api_key: "your-api-key"
      )
      
      # Delete chunk
      :ok = Chunk.delete_chunk(
        "corpora/my-corpus/documents/my-doc/chunks/my-chunk",
        api_key: "your-api-key"
      )
  """

  alias ExLLM.Providers.Gemini.Base

  defstruct [
    :name,
    :data,
    :custom_metadata,
    :create_time,
    :update_time,
    :state
  ]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          data: __MODULE__.ChunkData.t() | nil,
          custom_metadata: [__MODULE__.CustomMetadata.t()] | nil,
          create_time: String.t() | nil,
          update_time: String.t() | nil,
          state: atom() | nil
        }

  defmodule ChunkData do
    @moduledoc """
    Extracted data that represents the Chunk content.
    """

    defstruct [:string_value]

    @type t :: %__MODULE__{
            string_value: String.t()
          }
  end

  defmodule CustomMetadata do
    @moduledoc """
    User provided metadata stored as key-value pairs.
    """

    defstruct [
      :key,
      :string_value,
      :numeric_value,
      :string_list_value
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            string_value: String.t() | nil,
            numeric_value: number() | nil,
            string_list_value: ExLLM.Providers.Gemini.Chunk.StringList.t() | nil
          }
  end

  defmodule StringList do
    @moduledoc """
    User provided string values assigned to a single metadata key.
    """

    defstruct [:values]

    @type t :: %__MODULE__{
            values: [String.t()]
          }
  end

  defmodule ListResult do
    @moduledoc """
    Response from listing chunks with pagination support.
    """

    defstruct [:chunks, :next_page_token]

    @type t :: %__MODULE__{
            chunks: [t()],
            next_page_token: String.t() | nil
          }
  end

  defmodule BatchResult do
    @moduledoc """
    Response from batch operations containing a list of chunks.
    """

    defstruct [:chunks]

    @type t :: %__MODULE__{
            chunks: [t()]
          }
  end

  @doc """
  Creates a Chunk in the specified Document.

  ## Parameters

  - `parent` - The document name in format "corpora/{corpus_id}/documents/{document_id}"
  - `params` - Chunk creation parameters
  - `opts` - Keyword list of options:
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Params

  - `:name` - Optional custom chunk name
  - `:data` - Required. The chunk content (max 2043 tokens)
  - `:custom_metadata` - List of key-value metadata (max 20 items)

  ## Examples

      # Create with auto-generated name
      {:ok, chunk} = Chunk.create_chunk(
        "corpora/my-corpus/documents/my-doc",
        %{data: %{string_value: "This is the content."}}
      )
      
      # Create with custom name and metadata
      {:ok, chunk} = Chunk.create_chunk(
        "corpora/my-corpus/documents/my-doc",
        %{
          name: "corpora/my-corpus/documents/my-doc/chunks/chapter-1",
          data: %{string_value: "Chapter 1 content."},
          custom_metadata: [
            %{key: "chapter", numeric_value: 1},
            %{key: "keywords", string_list_value: %{values: ["intro", "overview"]}}
          ]
        }
      )
  """
  @spec create_chunk(String.t(), map(), Keyword.t()) :: {:ok, t()} | {:error, map()}
  def create_chunk(parent, params, opts \\ []) do
    with :ok <- validate_document_name(parent),
         :ok <- validate_create_params(params) do
      url = "/#{parent}/chunks"
      body = build_create_request(params)

      request_opts = [
        method: :post,
        url: url,
        body: body,
        query: %{}
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, response} ->
          {:ok, parse_chunk(response)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Lists all Chunks in a Document with pagination support.

  ## Parameters

  - `parent` - The document name in format "corpora/{corpus_id}/documents/{document_id}"
  - `opts` - Keyword list of options:
    - `:page_size` - Maximum chunks per page (1-100, default 10)
    - `:page_token` - Token for pagination
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Examples

      # List all chunks
      {:ok, result} = Chunk.list_chunks("corpora/my-corpus/documents/my-doc")
      
      # List with pagination
      {:ok, result} = Chunk.list_chunks(
        "corpora/my-corpus/documents/my-doc",
        %{page_size: 50, page_token: "next-page-token"}
      )
  """
  @spec list_chunks(String.t(), Keyword.t()) :: {:ok, ListResult.t()} | {:error, map()}
  def list_chunks(parent, opts \\ []) do
    {list_opts, auth_opts} = Keyword.split(opts, [:page_size, :page_token])

    with :ok <- validate_document_name(parent),
         :ok <- validate_list_opts(list_opts) do
      query = build_list_query(list_opts)
      url = "/#{parent}/chunks"

      request_opts = [
        method: :get,
        url: url,
        body: nil,
        query: query
      ]

      request_opts = add_auth(request_opts, auth_opts)

      case Base.request(request_opts) do
        {:ok, response} ->
          {:ok, parse_list_result(response)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Gets information about a specific Chunk.

  ## Parameters

  - `name` - The chunk name in format "corpora/{corpus_id}/documents/{document_id}/chunks/{chunk_id}"
  - `opts` - Keyword list of options:
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Examples

      {:ok, chunk} = Chunk.get_chunk("corpora/my-corpus/documents/my-doc/chunks/my-chunk")
  """
  @spec get_chunk(String.t(), Keyword.t()) :: {:ok, t()} | {:error, map()}
  def get_chunk(name, opts \\ []) do
    with :ok <- validate_chunk_name(name) do
      request_opts = [
        method: :get,
        url: "/#{name}",
        body: nil,
        query: %{}
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, response} ->
          {:ok, parse_chunk(response)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Updates a Chunk.

  ## Parameters

  - `name` - The chunk name in format "corpora/{corpus_id}/documents/{document_id}/chunks/{chunk_id}"
  - `updates` - Fields to update
  - `update_mask` - Required. Fields to update ("data", "customMetadata")
  - `opts` - Authentication options

  ## Updates

  - `:data` - New chunk content
  - `:custom_metadata` - New custom metadata

  ## Examples

      # Update content
      {:ok, chunk} = Chunk.update_chunk(
        "corpora/my-corpus/documents/my-doc/chunks/my-chunk",
        %{data: %{string_value: "New content"}},
        "data"
      )
      
      # Update metadata
      {:ok, chunk} = Chunk.update_chunk(
        "corpora/my-corpus/documents/my-doc/chunks/my-chunk",
        %{custom_metadata: [%{key: "status", string_value: "reviewed"}]},
        "customMetadata"
      )
  """
  @spec update_chunk(String.t(), map(), String.t() | [String.t()], Keyword.t()) ::
          {:ok, t()} | {:error, map()}
  def update_chunk(name, updates, update_mask, opts \\ []) do
    with :ok <- validate_chunk_name(name),
         :ok <- validate_update_params(updates, update_mask) do
      query = build_update_query(update_mask)
      body = build_update_request(updates)

      request_opts = [
        method: :patch,
        url: "/#{name}",
        body: body,
        query: query
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, response} ->
          {:ok, parse_chunk(response)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Deletes a Chunk.

  ## Parameters

  - `name` - The chunk name in format "corpora/{corpus_id}/documents/{document_id}/chunks/{chunk_id}"
  - `opts` - Keyword list of options:
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Examples

      :ok = Chunk.delete_chunk("corpora/my-corpus/documents/my-doc/chunks/my-chunk")
  """
  @spec delete_chunk(String.t(), Keyword.t()) :: :ok | {:error, map()}
  def delete_chunk(name, opts \\ []) do
    with :ok <- validate_chunk_name(name) do
      request_opts = [
        method: :delete,
        url: "/#{name}",
        body: nil,
        query: %{}
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, _response} ->
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Batch create Chunks in a Document.

  ## Parameters

  - `parent` - The document name in format "corpora/{corpus_id}/documents/{document_id}"
  - `chunk_requests` - List of chunk creation requests (max 100)
  - `opts` - Keyword list of options:
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Chunk Request Format

  Each request should have:
  - `:parent` - The document name (must match parent parameter)
  - `:chunk` - The chunk data (same format as create_chunk params)

  ## Examples

      {:ok, result} = Chunk.batch_create_chunks(
        "corpora/my-corpus/documents/my-doc",
        [
          %{
            parent: "corpora/my-corpus/documents/my-doc",
            chunk: %{data: %{string_value: "First chunk content"}}
          },
          %{
            parent: "corpora/my-corpus/documents/my-doc",
            chunk: %{
              name: "corpora/my-corpus/documents/my-doc/chunks/special-chunk",
              data: %{string_value: "Second chunk with custom name"},
              custom_metadata: [%{key: "type", string_value: "important"}]
            }
          }
        ]
      )
  """
  @spec batch_create_chunks(String.t(), [map()], Keyword.t()) ::
          {:ok, BatchResult.t()} | {:error, map()}
  def batch_create_chunks(parent, chunk_requests, opts \\ []) do
    with :ok <- validate_document_name(parent),
         :ok <- validate_batch_create_params(chunk_requests) do
      url = "/#{parent}/chunks:batchCreate"
      body = build_batch_create_request(parent, chunk_requests)

      request_opts = [
        method: :post,
        url: url,
        body: body,
        query: %{}
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, response} ->
          {:ok, parse_batch_result(response)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Batch update Chunks in a Document.

  ## Parameters

  - `parent` - The document name in format "corpora/{corpus_id}/documents/{document_id}"
  - `update_requests` - List of chunk update requests (max 100)
  - `opts` - Keyword list of options:
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Update Request Format

  Each request should have:
  - `:chunk` - The chunk data with name and fields to update
  - `:update_mask` - Fields to update ("data", "customMetadata")

  ## Examples

      {:ok, result} = Chunk.batch_update_chunks(
        "corpora/my-corpus/documents/my-doc",
        [
          %{
            chunk: %{
              name: "corpora/my-corpus/documents/my-doc/chunks/chunk-1",
              data: %{string_value: "Updated content"}
            },
            update_mask: "data"
          },
          %{
            chunk: %{
              name: "corpora/my-corpus/documents/my-doc/chunks/chunk-2",
              custom_metadata: [%{key: "status", string_value: "reviewed"}]
            },
            update_mask: "customMetadata"
          }
        ]
      )
  """
  @spec batch_update_chunks(String.t(), [map()], Keyword.t()) ::
          {:ok, BatchResult.t()} | {:error, map()}
  def batch_update_chunks(parent, update_requests, opts \\ []) do
    with :ok <- validate_document_name(parent),
         :ok <- validate_batch_update_params(update_requests) do
      url = "/#{parent}/chunks:batchUpdate"
      body = build_batch_update_request(update_requests)

      request_opts = [
        method: :post,
        url: url,
        body: body,
        query: %{}
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, response} ->
          {:ok, parse_batch_result(response)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Batch delete Chunks from a Document.

  ## Parameters

  - `parent` - The document name in format "corpora/{corpus_id}/documents/{document_id}"
  - `delete_requests` - List of chunk names to delete
  - `opts` - Keyword list of options:
    - `:api_key` - API key for authentication
    - `:oauth_token` - OAuth2 token for authentication

  ## Delete Request Format

  Each request should have:
  - `:name` - The full chunk name to delete

  ## Examples

      :ok = Chunk.batch_delete_chunks(
        "corpora/my-corpus/documents/my-doc",
        [
          %{name: "corpora/my-corpus/documents/my-doc/chunks/chunk-1"},
          %{name: "corpora/my-corpus/documents/my-doc/chunks/chunk-2"}
        ]
      )
  """
  @spec batch_delete_chunks(String.t(), [map()], Keyword.t()) :: :ok | {:error, map()}
  def batch_delete_chunks(parent, delete_requests, opts \\ []) do
    with :ok <- validate_document_name(parent),
         :ok <- validate_batch_delete_params(delete_requests) do
      url = "/#{parent}/chunks:batchDelete"
      body = build_batch_delete_request(delete_requests)

      request_opts = [
        method: :post,
        url: url,
        body: body,
        query: %{}
      ]

      request_opts = add_auth(request_opts, opts)

      case Base.request(request_opts) do
        {:ok, _response} ->
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # Private functions

  @doc false
  def validate_document_name(nil) do
    {:error, %{message: "document name cannot be nil"}}
  end

  def validate_document_name(name) when is_binary(name) do
    # Document name format: corpora/{corpus_id}/documents/{document_id}
    # Both corpus and document IDs follow the same pattern:
    # up to 40 characters that are alphanumeric or dashes, but cannot start or end with a dash
    if String.match?(
         name,
         ~r/^corpora\/[a-zA-Z0-9]([a-zA-Z0-9\-]{0,38}[a-zA-Z0-9])?\/documents\/[a-zA-Z0-9]([a-zA-Z0-9\-]{0,38}[a-zA-Z0-9])?$/
       ) do
      :ok
    else
      {:error,
       %{message: "document name must be in format 'corpora/{corpus_id}/documents/{document_id}'"}}
    end
  end

  def validate_document_name(_) do
    {:error, %{message: "document name must be a string"}}
  end

  @doc false
  def validate_chunk_name(nil) do
    {:error, %{message: "chunk name cannot be nil"}}
  end

  def validate_chunk_name(name) when is_binary(name) do
    # Chunk name format: corpora/{corpus_id}/documents/{document_id}/chunks/{chunk_id}
    # All IDs follow the same pattern:
    # up to 40 characters that are alphanumeric or dashes, but cannot start or end with a dash
    if String.match?(
         name,
         ~r/^corpora\/[a-zA-Z0-9]([a-zA-Z0-9\-]{0,38}[a-zA-Z0-9])?\/documents\/[a-zA-Z0-9]([a-zA-Z0-9\-]{0,38}[a-zA-Z0-9])?\/chunks\/[a-zA-Z0-9]([a-zA-Z0-9\-]{0,38}[a-zA-Z0-9])?$/
       ) do
      :ok
    else
      {:error,
       %{
         message:
           "chunk name must be in format 'corpora/{corpus_id}/documents/{document_id}/chunks/{chunk_id}'"
       }}
    end
  end

  def validate_chunk_name(_) do
    {:error, %{message: "chunk name must be a string"}}
  end

  @doc false
  def validate_create_params(params) do
    cond do
      not Map.has_key?(params, :data) ->
        {:error, %{message: "data is required"}}

      not is_map(params[:data]) or not Map.has_key?(params[:data], :string_value) ->
        {:error, %{message: "data must contain string_value"}}

      params[:data][:string_value] == "" ->
        {:error, %{message: "string_value cannot be empty"}}

      params[:custom_metadata] && length(params[:custom_metadata]) > 20 ->
        {:error, %{message: "maximum of 20 CustomMetadata allowed"}}

      true ->
        :ok
    end
  end

  @doc false
  def validate_list_opts(opts) do
    if opts[:page_size] && opts[:page_size] > 100 do
      {:error, %{message: "maximum size limit is 100 chunks per page"}}
    else
      :ok
    end
  end

  @doc false
  def validate_update_params(updates, update_mask) do
    with :ok <- validate_update_mask(update_mask),
         :ok <- validate_update_data(updates) do
      validate_custom_metadata(updates)
    end
  end

  defp validate_update_mask(update_mask) do
    valid_fields = ["data", "customMetadata"]

    cond do
      is_update_mask_empty?(update_mask) ->
        {:error, %{message: "updateMask is required"}}

      is_binary(update_mask) && update_mask not in valid_fields ->
        {:error, %{message: "updateMask only supports updating data and customMetadata"}}

      is_list(update_mask) && not Enum.all?(update_mask, &(&1 in valid_fields)) ->
        {:error, %{message: "updateMask only supports updating data and customMetadata"}}

      true ->
        :ok
    end
  end

  defp is_update_mask_empty?(update_mask) do
    is_nil(update_mask) ||
      (is_list(update_mask) && Enum.empty?(update_mask)) ||
      (is_map(update_mask) && map_size(update_mask) == 0)
  end

  defp validate_update_data(updates) do
    if updates[:data] && updates[:data][:string_value] == "" do
      {:error, %{message: "string_value cannot be empty when updating data"}}
    else
      :ok
    end
  end

  defp validate_custom_metadata(updates) do
    if updates[:custom_metadata] && Enum.count(updates[:custom_metadata]) > 20 do
      {:error, %{message: "maximum of 20 CustomMetadata allowed"}}
    else
      :ok
    end
  end

  @doc false
  def validate_batch_create_params(chunks) do
    cond do
      chunks == [] ->
        {:error, %{message: "at least one chunk is required"}}

      Enum.count(chunks) > 100 ->
        {:error, %{message: "maximum of 100 chunks can be created in a batch"}}

      true ->
        :ok
    end
  end

  @doc false
  def validate_batch_update_params(updates) do
    cond do
      updates == [] ->
        {:error, %{message: "at least one update is required"}}

      Enum.count(updates) > 100 ->
        {:error, %{message: "maximum of 100 chunks can be updated in a batch"}}

      true ->
        :ok
    end
  end

  @doc false
  def validate_batch_delete_params(deletes) do
    cond do
      deletes == [] ->
        {:error, %{message: "at least one chunk is required"}}

      Enum.count(deletes) > 100 ->
        {:error, %{message: "maximum of 100 chunks can be deleted in a batch"}}

      true ->
        :ok
    end
  end

  defp build_list_query(opts) do
    query = %{}

    query = if opts[:page_size], do: Map.put(query, "pageSize", opts[:page_size]), else: query
    query = if opts[:page_token], do: Map.put(query, "pageToken", opts[:page_token]), else: query

    query
  end

  defp build_update_query(update_mask) do
    cond do
      is_binary(update_mask) ->
        %{"updateMask" => update_mask}

      is_list(update_mask) && not Enum.empty?(update_mask) ->
        %{"updateMask" => Enum.join(update_mask, ",")}

      true ->
        %{}
    end
  end

  @doc false
  def build_create_request(params) do
    request = %{}

    request = if params[:name], do: Map.put(request, :name, params[:name]), else: request

    request =
      if params[:data],
        do: Map.put(request, :data, format_chunk_data(params[:data])),
        else: request

    request =
      if params[:custom_metadata],
        do: Map.put(request, :customMetadata, format_metadata(params[:custom_metadata])),
        else: request

    request
  end

  @doc false
  def build_update_request(updates) do
    request = %{}

    request =
      if updates[:data],
        do: Map.put(request, :data, format_chunk_data(updates[:data])),
        else: request

    request =
      if updates[:custom_metadata],
        do: Map.put(request, :customMetadata, format_metadata(updates[:custom_metadata])),
        else: request

    request
  end

  @doc false
  def build_batch_create_request(parent, chunks) do
    requests =
      Enum.map(chunks, fn chunk_req ->
        # Handle both formats:
        # 1. Simple format: just chunk data
        # 2. Full format: {parent: ..., chunk: ...}
        if Map.has_key?(chunk_req, :parent) do
          %{
            parent: chunk_req[:parent],
            chunk: build_create_request(chunk_req[:chunk])
          }
        else
          # Simple format - chunk_req IS the chunk data, use the parent parameter
          %{
            parent: parent,
            chunk: build_create_request(chunk_req)
          }
        end
      end)

    %{requests: requests}
  end

  @doc false
  def build_batch_update_request(updates) do
    requests =
      Enum.map(updates, fn update_req ->
        chunk_data = build_update_request(update_req[:chunk])

        chunk_data =
          if update_req[:chunk][:name],
            do: Map.put(chunk_data, :name, update_req[:chunk][:name]),
            else: chunk_data

        %{
          chunk: chunk_data,
          updateMask: update_req[:update_mask]
        }
      end)

    %{requests: requests}
  end

  @doc false
  def build_batch_delete_request(deletes) do
    requests =
      Enum.map(deletes, fn delete_req ->
        # Handle both string names and map format
        name = if is_binary(delete_req), do: delete_req, else: delete_req[:name]
        %{name: name}
      end)

    %{requests: requests}
  end

  defp format_chunk_data(data) do
    %{stringValue: data[:string_value]}
  end

  defp format_metadata(metadata) do
    Enum.map(metadata, fn meta ->
      formatted = %{key: meta.key}

      cond do
        meta[:string_value] ->
          Map.put(formatted, :stringValue, meta[:string_value])

        meta[:numeric_value] ->
          Map.put(formatted, :numericValue, meta[:numeric_value])

        meta[:string_list_value] ->
          Map.put(formatted, :stringListValue, %{values: meta[:string_list_value][:values]})

        true ->
          formatted
      end
    end)
  end

  @doc false
  def parse_chunk(response) do
    # Handle different response formats from HTTP client
    actual_body =
      cond do
        # Direct response body format (expected)
        is_map(response) and Map.has_key?(response, "name") ->
          response

        # Wrapped HTTP response format (from cache or HTTP client)
        is_map(response) and Map.has_key?(response, :body) and is_map(response[:body]) ->
          response[:body]

        # String key wrapped format
        is_map(response) and Map.has_key?(response, "body") and is_map(response["body"]) ->
          response["body"]

        # Fallback to original format
        true ->
          response
      end

    %__MODULE__{
      name: actual_body["name"],
      data: parse_chunk_data(actual_body["data"]),
      custom_metadata: parse_metadata(actual_body["customMetadata"]),
      create_time: actual_body["createTime"],
      update_time: actual_body["updateTime"],
      state: parse_state(actual_body["state"])
    }
  end

  defp parse_chunk_data(nil), do: nil

  defp parse_chunk_data(data) do
    %ChunkData{
      string_value: data["stringValue"]
    }
  end

  defp parse_metadata(nil), do: nil

  defp parse_metadata(metadata) do
    Enum.map(metadata, fn meta ->
      %CustomMetadata{
        key: meta["key"],
        string_value: meta["stringValue"],
        numeric_value: meta["numericValue"],
        string_list_value: parse_string_list(meta["stringListValue"])
      }
    end)
  end

  defp parse_string_list(nil), do: nil

  defp parse_string_list(string_list) do
    %StringList{values: string_list["values"]}
  end

  defp parse_state(nil), do: nil
  defp parse_state("STATE_UNSPECIFIED"), do: :STATE_UNSPECIFIED
  defp parse_state("STATE_PENDING_PROCESSING"), do: :STATE_PENDING_PROCESSING
  defp parse_state("STATE_ACTIVE"), do: :STATE_ACTIVE
  defp parse_state("STATE_FAILED"), do: :STATE_FAILED
  defp parse_state(state), do: String.to_atom(state)

  defp parse_list_result(response) do
    %ListResult{
      chunks: Enum.map(response["chunks"] || [], &parse_chunk/1),
      next_page_token: response["nextPageToken"]
    }
  end

  defp parse_batch_result(response) do
    # Handle different response formats from HTTP client
    actual_body =
      cond do
        # Direct response body format (expected)
        is_map(response) and Map.has_key?(response, "chunks") ->
          response

        # Wrapped HTTP response format (from cache or HTTP client)
        is_map(response) and Map.has_key?(response, :body) and is_map(response[:body]) ->
          response[:body]

        # String key wrapped format
        is_map(response) and Map.has_key?(response, "body") and is_map(response["body"]) ->
          response["body"]

        # Fallback to original format
        true ->
          response
      end

    %BatchResult{
      chunks: Enum.map(actual_body["chunks"] || [], &parse_chunk/1)
    }
  end

  defp add_auth(request_opts, opts) do
    if oauth_token = opts[:oauth_token] do
      # Add oauth_token and pass through all other options
      request_opts
      |> Keyword.put(:oauth_token, oauth_token)
      |> Keyword.put(:opts, opts)
    else
      if api_key = opts[:api_key] do
        # Add api_key and pass through all other options
        request_opts
        |> Keyword.put(:api_key, api_key)
        |> Keyword.put(:opts, opts)
      else
        raise ArgumentError,
              "Authentication required. Set :oauth_token or :api_key option"
      end
    end
  end
end
