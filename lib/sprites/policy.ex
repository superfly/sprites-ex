defmodule Sprites.Policy do
  @moduledoc """
  Network policy management for sprites.
  """

  alias Sprites.{Client, Sprite}

  defmodule Rule do
    @moduledoc """
    Network policy rule.

    ## Fields

      * `:domain` - Domain to match (e.g., "example.com")
      * `:action` - Action to take: "allow" or "deny"
      * `:include` - Optional include pattern for wildcard matching
    """
    @type t :: %__MODULE__{
            domain: String.t() | nil,
            action: String.t() | nil,
            include: String.t() | nil
          }

    defstruct [:domain, :action, :include]

    @doc """
    Creates a rule from a map.
    """
    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        domain: Map.get(map, "domain") || Map.get(map, :domain),
        action: Map.get(map, "action") || Map.get(map, :action),
        include: Map.get(map, "include") || Map.get(map, :include)
      }
    end

    @doc """
    Converts a rule to a map for JSON encoding.
    """
    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = rule) do
      %{}
      |> maybe_put(:domain, rule.domain)
      |> maybe_put(:action, rule.action)
      |> maybe_put(:include, rule.include)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end

  @doc """
  Network policy containing a list of rules.

  ## Fields

    * `:rules` - List of `Sprites.Policy.Rule` structs
  """
  @type t :: %__MODULE__{rules: [Rule.t()]}

  defstruct rules: []

  @doc """
  Creates a network policy from a map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    rules =
      (Map.get(map, "rules") || Map.get(map, :rules) || [])
      |> Enum.map(&Rule.from_map/1)

    %__MODULE__{rules: rules}
  end

  @doc """
  Converts a network policy to a map for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{rules: rules}) do
    %{rules: Enum.map(rules, &Rule.to_map/1)}
  end

  @doc """
  Gets the current network policy for a sprite.

  ## Examples

      {:ok, policy} = Sprites.Policy.get(sprite)
  """
  @spec get(Sprite.t()) :: {:ok, t()} | {:error, term()}
  def get(%Sprite{client: client, name: name}) do
    get_by_name(client, name)
  end

  @doc """
  Gets the current network policy for a sprite by name.
  """
  @spec get_by_name(Client.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get_by_name(%Client{} = client, name) when is_binary(name) do
    case Req.get(client.req, url: "/v1/sprites/#{URI.encode(name)}/policy/network") do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, from_map(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates the network policy for a sprite.

  ## Examples

      policy = %Sprites.Policy{
        rules: [
          %Sprites.Policy.Rule{domain: "example.com", action: "allow"},
          %Sprites.Policy.Rule{domain: "blocked.com", action: "deny"}
        ]
      }
      :ok = Sprites.Policy.update(sprite, policy)
  """
  @spec update(Sprite.t(), t()) :: :ok | {:error, term()}
  def update(%Sprite{client: client, name: name}, %__MODULE__{} = policy) do
    update_by_name(client, name, policy)
  end

  @doc """
  Updates the network policy for a sprite by name.
  """
  @spec update_by_name(Client.t(), String.t(), t()) :: :ok | {:error, term()}
  def update_by_name(%Client{} = client, name, %__MODULE__{} = policy) when is_binary(name) do
    body = to_map(policy)

    case Req.post(client.req, url: "/v1/sprites/#{URI.encode(name)}/policy/network", json: body) do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: 400, body: body}} ->
        {:error, {:invalid_policy, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
