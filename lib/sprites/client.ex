defmodule Sprites.Client do
  @moduledoc """
  HTTP client for Sprites REST API operations.
  """

  @default_base_url "https://api.sprites.dev"
  @default_timeout 30_000
  @create_timeout 120_000

  defstruct [:token, :base_url, :timeout, :req, control_mode: false]

  @type t :: %__MODULE__{
          token: String.t(),
          base_url: String.t(),
          timeout: non_neg_integer(),
          req: Req.Request.t(),
          control_mode: boolean()
        }

  @doc """
  Creates a new client.

  ## Options

    * `:base_url` - API base URL (default: "https://api.sprites.dev")
    * `:timeout` - HTTP timeout in milliseconds (default: 30_000)
    * `:control_mode` - Enable control mode for multiplexed exec over a single WebSocket (default: false)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) |> normalize_url()
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    control_mode = Keyword.get(opts, :control_mode, false)

    req =
      Req.new(
        base_url: base_url,
        headers: [{"authorization", "Bearer #{token}"}],
        receive_timeout: timeout
      )

    %__MODULE__{
      token: token,
      base_url: base_url,
      timeout: timeout,
      req: req,
      control_mode: control_mode
    }
  end

  @doc """
  Creates a new sprite.

  ## Options

    * `:config` - Sprite configuration map
  """
  @spec create_sprite(t(), String.t(), keyword()) :: {:ok, Sprites.Sprite.t()} | {:error, term()}
  def create_sprite(client, name, opts \\ []) do
    body = %{name: name}
    body = if config = Keyword.get(opts, :config), do: Map.put(body, :config, config), else: body

    case Req.post(client.req, url: "/v1/sprites", json: body, receive_timeout: @create_timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Sprites.Sprite.new(client, name, body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a sprite.
  """
  @spec delete_sprite(t(), String.t()) :: :ok | {:error, term()}
  def delete_sprite(client, name) do
    case Req.delete(client.req, url: "/v1/sprites/#{URI.encode(name)}") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      # Already deleted
      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists sprites.

  ## Options

    * `:prefix` - Filter by name prefix
  """
  @spec list_sprites(t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_sprites(client, opts \\ []) do
    params = if prefix = Keyword.get(opts, :prefix), do: [prefix: prefix], else: []

    case Req.get(client.req, url: "/v1/sprites", params: params) do
      {:ok, %{status: status, body: %{"sprites" => sprites}}} when status in 200..299 ->
        {:ok, sprites}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        # Fallback for unexpected response format
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets detailed information about a sprite.
  """
  @spec get_sprite(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_sprite(client, name) do
    case Req.get(client.req, url: "/v1/sprites/#{URI.encode(name)}") do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 404, body: body}} ->
        {:error, {:not_found, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Triggers an upgrade for a sprite.
  """
  @spec upgrade_sprite(t(), String.t()) :: :ok | {:error, term()}
  def upgrade_sprite(client, name) do
    case Req.post(client.req, url: "/v1/sprites/#{URI.encode(name)}/upgrade") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates URL settings for a sprite.

  ## Options

    * `:auth` - Authentication mode for the URL (e.g., "bearer", "none")
  """
  @spec update_url_settings(t(), String.t(), map()) :: :ok | {:error, term()}
  def update_url_settings(client, name, settings) do
    body = %{url_settings: settings}

    case Req.put(client.req, url: "/v1/sprites/#{URI.encode(name)}", json: body) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_url(url) do
    String.trim_trailing(url, "/")
  end
end
