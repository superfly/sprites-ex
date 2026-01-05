defmodule Sprites.Checkpoint do
  @moduledoc """
  Checkpoint management for sprites.

  Checkpoints allow you to save and restore the state of a sprite.
  """

  alias Sprites.{Client, Sprite}

  @doc """
  Represents a checkpoint.

  ## Fields

    * `:id` - Unique checkpoint identifier
    * `:create_time` - When the checkpoint was created (DateTime)
    * `:history` - List of parent checkpoint IDs
    * `:comment` - Optional user-provided comment
  """
  @type t :: %__MODULE__{
          id: String.t(),
          create_time: DateTime.t() | nil,
          history: [String.t()],
          comment: String.t() | nil
        }

  defstruct [:id, :create_time, :comment, history: []]

  @doc """
  Creates a checkpoint from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    create_time =
      case Map.get(map, "create_time") || Map.get(map, :create_time) do
        nil -> nil
        ts when is_binary(ts) -> parse_datetime(ts)
        ts -> ts
      end

    %__MODULE__{
      id: Map.get(map, "id") || Map.get(map, :id),
      create_time: create_time,
      history: Map.get(map, "history") || Map.get(map, :history) || [],
      comment: Map.get(map, "comment") || Map.get(map, :comment)
    }
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  @doc """
  Lists all checkpoints for a sprite.

  ## Options

    * `:history` - History filter string (optional)

  ## Examples

      {:ok, checkpoints} = Sprites.Checkpoint.list(sprite)
  """
  @spec list(Sprite.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(%Sprite{client: client, name: name}, opts \\ []) do
    list_by_name(client, name, opts)
  end

  @doc """
  Lists all checkpoints for a sprite by name.
  """
  @spec list_by_name(Client.t(), String.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list_by_name(%Client{} = client, name, opts \\ []) when is_binary(name) do
    params =
      case Keyword.get(opts, :history) do
        nil -> []
        filter -> [history: filter]
      end

    case Req.get(client.req, url: "/v1/sprites/#{URI.encode(name)}/checkpoints", params: params) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        {:ok, Enum.map(body, &from_map/1)}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        # Text response (history filter) - not supported in SDK
        {:error, {:text_response_not_supported, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a specific checkpoint by ID.

  ## Examples

      {:ok, checkpoint} = Sprites.Checkpoint.get(sprite, "checkpoint-id")
  """
  @spec get(Sprite.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Sprite{client: client, name: name}, checkpoint_id) do
    get_by_name(client, name, checkpoint_id)
  end

  @doc """
  Gets a specific checkpoint by sprite name and checkpoint ID.
  """
  @spec get_by_name(Client.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get_by_name(%Client{} = client, name, checkpoint_id) when is_binary(name) do
    url = "/v1/sprites/#{URI.encode(name)}/checkpoints/#{URI.encode(checkpoint_id)}"

    case Req.get(client.req, url: url) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, from_map(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a new checkpoint for a sprite.

  Returns a stream of messages. The stream should be consumed to completion.

  ## Options

    * `:comment` - Optional comment for the checkpoint

  ## Examples

      {:ok, stream} = Sprites.Checkpoint.create(sprite, comment: "Before changes")
      Enum.each(stream, fn msg -> IO.inspect(msg) end)
  """
  @spec create(Sprite.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def create(%Sprite{client: client, name: name}, opts \\ []) do
    create_by_name(client, name, opts)
  end

  @doc """
  Creates a new checkpoint for a sprite by name.
  """
  @spec create_by_name(Client.t(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def create_by_name(%Client{} = client, name, opts \\ []) when is_binary(name) do
    url = "#{client.base_url}/v1/sprites/#{URI.encode(name)}/checkpoint"
    comment = Keyword.get(opts, :comment, "")

    body = if comment != "", do: Jason.encode!(%{comment: comment}), else: "{}"

    headers = [
      {"authorization", "Bearer #{client.token}"},
      {"content-type", "application/json"}
    ]

    start_ndjson_stream(url, :post, headers, body)
  end

  @doc """
  Restores a sprite from a checkpoint.

  Returns a stream of messages. The stream should be consumed to completion.

  ## Examples

      {:ok, stream} = Sprites.Checkpoint.restore(sprite, "checkpoint-id")
      Enum.each(stream, fn msg -> IO.inspect(msg) end)
  """
  @spec restore(Sprite.t(), String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def restore(%Sprite{client: client, name: name}, checkpoint_id) do
    restore_by_name(client, name, checkpoint_id)
  end

  @doc """
  Restores a sprite from a checkpoint by name.
  """
  @spec restore_by_name(Client.t(), String.t(), String.t()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def restore_by_name(%Client{} = client, name, checkpoint_id) when is_binary(name) do
    url =
      "#{client.base_url}/v1/sprites/#{URI.encode(name)}/checkpoints/#{URI.encode(checkpoint_id)}/restore"

    headers = [
      {"authorization", "Bearer #{client.token}"}
    ]

    start_ndjson_stream(url, :post, headers, nil)
  end

  # Start a streaming NDJSON request and return a lazy enumerable
  defp start_ndjson_stream(url, method, headers, body) do
    # Use :httpc for streaming support
    # POST requests require a 4-tuple (url, headers, content_type, body)
    charlist_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request =
      case {method, body} do
        {:post, nil} ->
          # POST with no body still needs 4-tuple format
          {String.to_charlist(url), charlist_headers, ~c"application/json", ""}

        {:post, body} ->
          {String.to_charlist(url), charlist_headers, ~c"application/json", body}

        {_get, _} ->
          {String.to_charlist(url), charlist_headers}
      end

    http_method = method

    case :httpc.request(http_method, request, [{:timeout, :infinity}], [
           {:body_format, :binary},
           {:sync, true}
         ]) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        # Parse NDJSON response
        messages =
          response_body
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_stream_message/1)
          |> Enum.reject(&is_nil/1)

        {:ok, messages}

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_stream_message(""), do: nil

  defp parse_stream_message(line) do
    case Jason.decode(line) do
      {:ok, map} -> Sprites.StreamMessage.from_map(map)
      {:error, _} -> nil
    end
  end
end

defmodule Sprites.StreamMessage do
  @moduledoc """
  A message from a streaming operation (checkpoint create/restore).

  ## Fields

    * `:type` - Message type: "info", "stdout", "stderr", or "error"
    * `:data` - Message data (for info/stdout/stderr)
    * `:error` - Error message (for error type)
  """
  @type t :: %__MODULE__{
          type: String.t(),
          data: String.t() | nil,
          error: String.t() | nil
        }

  defstruct [:type, :data, :error]

  @doc """
  Creates a stream message from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      type: Map.get(map, "type") || Map.get(map, :type),
      data: Map.get(map, "data") || Map.get(map, :data),
      error: Map.get(map, "error") || Map.get(map, :error)
    }
  end

  @doc """
  Converts a stream message to a map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{}
    |> maybe_put(:type, msg.type)
    |> maybe_put(:data, msg.data)
    |> maybe_put(:error, msg.error)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
