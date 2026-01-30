defmodule Sprites.Sprite do
  @moduledoc """
  Represents a sprite instance.
  """

  defstruct [:name, :client, :id, :status, :config, :environment]

  @type t :: %__MODULE__{
          name: String.t(),
          client: Sprites.Client.t(),
          id: String.t() | nil,
          status: String.t() | nil,
          config: map() | nil,
          environment: map() | nil
        }

  @doc """
  Creates a new sprite handle.
  """
  @spec new(Sprites.Client.t(), String.t(), map()) :: t()
  def new(client, name, attrs \\ %{}) do
    %__MODULE__{
      name: name,
      client: client,
      id: Map.get(attrs, "id"),
      status: Map.get(attrs, "status"),
      config: Map.get(attrs, "config"),
      environment: Map.get(attrs, "environment")
    }
  end

  @doc """
  Destroys this sprite.
  """
  @spec destroy(t()) :: :ok | {:error, term()}
  def destroy(%__MODULE__{client: client, name: name}) do
    Sprites.Client.delete_sprite(client, name)
  end

  @doc """
  Builds the WebSocket URL for command execution.
  """
  @spec exec_url(t(), String.t(), [String.t()], keyword()) :: String.t()
  def exec_url(%__MODULE__{client: client, name: name}, command, args, opts) do
    base =
      client.base_url
      |> String.replace(~r/^http/, "ws")

    path = "/v1/sprites/#{URI.encode(name)}/exec"
    query_params = build_query_params(command, args, opts)

    "#{base}#{path}?#{URI.encode_query(query_params)}"
  end

  @doc """
  Returns the authorization token for this sprite's client.
  """
  @spec token(t()) :: String.t()
  def token(%__MODULE__{client: client}) do
    client.token
  end

  @doc """
  Builds a path for sprite-specific API endpoints.
  """
  @spec path(t(), String.t(), keyword()) :: String.t()
  def path(%__MODULE__{name: name}, endpoint, params \\ []) do
    query = if params == [], do: "", else: "?#{URI.encode_query(params)}"
    "/v1/sprites/#{URI.encode(name)}#{endpoint}#{query}"
  end

  defp build_query_params(command, args, opts) do
    [{"path", command} | Enum.map([command | args], &{"cmd", &1})]
    |> add_stdin_param(opts)
    |> add_dir_param(opts)
    |> add_env_params(opts)
    |> add_tty_params(opts)
    |> add_detachable_param(opts)
    |> add_session_id_param(opts)
  end

  defp add_stdin_param(params, opts) do
    stdin = if Keyword.get(opts, :stdin, false), do: "true", else: "false"
    [{"stdin", stdin} | params]
  end

  defp add_dir_param(params, opts) do
    case Keyword.get(opts, :dir) do
      nil -> params
      dir -> [{"dir", dir} | params]
    end
  end

  defp add_env_params(params, opts) do
    case Keyword.get(opts, :env, []) do
      [] -> params
      env_list -> Enum.map(env_list, fn {k, v} -> {"env", "#{k}=#{v}"} end) ++ params
    end
  end

  defp add_tty_params(params, opts) do
    if Keyword.get(opts, :tty, false) do
      rows = Keyword.get(opts, :tty_rows, 24)
      cols = Keyword.get(opts, :tty_cols, 80)
      [{"tty", "true"}, {"rows", to_string(rows)}, {"cols", to_string(cols)} | params]
    else
      params
    end
  end

  defp add_detachable_param(params, opts) do
    if Keyword.get(opts, :detachable, false) do
      [{"detachable", "true"} | params]
    else
      params
    end
  end

  defp add_session_id_param(params, opts) do
    case Keyword.get(opts, :session_id) do
      nil -> params
      session_id -> [{"session_id", session_id} | params]
    end
  end
end
