defmodule Sprites.Session do
  @moduledoc """
  Session management for sprites.

  Sessions represent active command executions that can be listed and attached to.
  """

  alias Sprites.{Client, Sprite}

  @doc """
  Represents an active execution session.

  ## Fields

    * `:id` - Unique session identifier
    * `:command` - The command being executed
    * `:workdir` - Working directory
    * `:created` - When the session was created (DateTime)
    * `:bytes_per_second` - Throughput rate
    * `:is_active` - Whether the session is currently active
    * `:last_activity` - Time of last activity (DateTime)
    * `:tty` - Whether TTY is enabled
  """
  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t(),
          workdir: String.t() | nil,
          created: DateTime.t() | nil,
          bytes_per_second: float(),
          is_active: boolean(),
          last_activity: DateTime.t() | nil,
          tty: boolean()
        }

  defstruct [
    :id,
    :command,
    :workdir,
    :created,
    :last_activity,
    bytes_per_second: 0.0,
    is_active: false,
    tty: false
  ]

  @doc """
  Creates a session from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    created = parse_datetime(Map.get(map, "created") || Map.get(map, :created))
    last_activity = parse_datetime(Map.get(map, "last_activity") || Map.get(map, :last_activity))

    %__MODULE__{
      id: Map.get(map, "id") || Map.get(map, :id),
      command: Map.get(map, "command") || Map.get(map, :command),
      workdir: Map.get(map, "workdir") || Map.get(map, :workdir),
      created: created,
      bytes_per_second:
        Map.get(map, "bytes_per_second") || Map.get(map, :bytes_per_second) || 0.0,
      is_active: Map.get(map, "is_active") || Map.get(map, :is_active) || false,
      last_activity: last_activity,
      tty: Map.get(map, "tty") || Map.get(map, :tty) || false
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(other), do: other

  @doc """
  Lists all active sessions for a sprite.

  ## Examples

      {:ok, sessions} = Sprites.Session.list(sprite)
  """
  @spec list(Sprite.t()) :: {:ok, [t()]} | {:error, term()}
  def list(%Sprite{client: client, name: name}) do
    list_by_name(client, name)
  end

  @doc """
  Lists all active sessions for a sprite by name.
  """
  @spec list_by_name(Client.t(), String.t()) :: {:ok, [t()]} | {:error, term()}
  def list_by_name(%Client{} = client, name) when is_binary(name) do
    case Req.get(client.req, url: "/v1/sprites/#{URI.encode(name)}/exec") do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        sessions =
          (Map.get(body, "sessions") || [])
          |> Enum.map(&from_map/1)

        {:ok, sessions}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true if the session has recent activity (within 5 minutes).
  """
  @spec is_session_active?(t()) :: boolean()
  def is_session_active?(%__MODULE__{is_active: false}), do: false
  def is_session_active?(%__MODULE__{is_active: true, last_activity: nil}), do: true

  def is_session_active?(%__MODULE__{is_active: true, last_activity: last_activity}) do
    case DateTime.diff(DateTime.utc_now(), last_activity, :second) do
      diff when diff < 300 -> true
      _ -> false
    end
  end

  @doc """
  Returns how long ago the last activity was.
  """
  @spec get_activity_age(t()) :: integer()
  def get_activity_age(%__MODULE__{last_activity: nil, created: nil}), do: 0

  def get_activity_age(%__MODULE__{last_activity: nil, created: created}) do
    DateTime.diff(DateTime.utc_now(), created, :second)
  end

  def get_activity_age(%__MODULE__{last_activity: last_activity}) do
    DateTime.diff(DateTime.utc_now(), last_activity, :second)
  end
end
