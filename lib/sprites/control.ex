defmodule Sprites.Control do
  @moduledoc """
  Module-level pool management for control connections.

  Uses ETS tables to store per-sprite pools and control support flags.
  Pools are created lazily on first checkout and cached for reuse.
  """

  alias Sprites.{ControlPool, Sprite}

  @pools_table :sprites_control_pools
  @support_table :sprites_control_support

  @doc """
  Ensures ETS tables exist. Safe to call multiple times.
  """
  @spec ensure_tables() :: :ok
  def ensure_tables do
    if :ets.whereis(@pools_table) == :undefined or
         :ets.whereis(@support_table) == :undefined do
      # Tables must be owned by a long-lived process so they survive
      # across short-lived Command GenServers.
      ensure_table_owner()
    end

    :ok
  end

  defp ensure_table_owner do
    name = :sprites_control_table_owner

    case Process.whereis(name) do
      nil ->
        caller = self()

        pid =
          spawn(fn ->
            if :ets.whereis(@pools_table) == :undefined do
              :ets.new(@pools_table, [:named_table, :public, :set])
            end

            if :ets.whereis(@support_table) == :undefined do
              :ets.new(@support_table, [:named_table, :public, :set])
            end

            send(caller, {:tables_ready, self()})

            # Stay alive forever — tables die when their owner dies
            ref = make_ref()

            receive do
              ^ref -> :ok
            end
          end)

        try do
          Process.register(pid, name)
        rescue
          ArgumentError ->
            Process.exit(pid, :normal)
        end

        receive do
          {:tables_ready, ^pid} -> :ok
        after
          5_000 -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc """
  Checks out a control connection for the given sprite.

  Creates a pool if one doesn't exist yet.
  """
  @spec checkout(Sprite.t()) :: {:ok, pid()} | {:error, term()}
  def checkout(%Sprite{} = sprite) do
    ensure_tables()
    pool = get_or_create_pool(sprite)
    ControlPool.checkout(pool)
  end

  @doc """
  Returns a control connection to the pool for the given sprite.
  """
  @spec checkin(Sprite.t(), pid()) :: :ok
  def checkin(%Sprite{} = sprite, conn_pid) do
    ensure_tables()
    key = sprite_key(sprite)

    case :ets.lookup(@pools_table, key) do
      [{^key, pool}] ->
        ControlPool.checkin(pool, conn_pid)

      [] ->
        :ok
    end
  end

  @doc """
  Returns whether control mode is believed to be supported for the given sprite.

  Returns `true` by default (until `mark_unsupported/1` is called).
  """
  @spec control_supported?(Sprite.t()) :: boolean()
  def control_supported?(%Sprite{} = sprite) do
    ensure_tables()
    key = sprite_key(sprite)

    case :ets.lookup(@support_table, key) do
      [{^key, false}] -> false
      _ -> true
    end
  end

  @doc """
  Marks a sprite as not supporting control mode.

  Prevents future checkout attempts from trying the control endpoint.
  """
  @spec mark_unsupported(Sprite.t()) :: :ok
  def mark_unsupported(%Sprite{} = sprite) do
    ensure_tables()
    key = sprite_key(sprite)
    :ets.insert(@support_table, {key, false})
    :ok
  end

  @doc """
  Closes all control connections for the given sprite and removes the pool.
  """
  @spec close(Sprite.t()) :: :ok
  def close(%Sprite{} = sprite) do
    ensure_tables()
    key = sprite_key(sprite)

    case :ets.lookup(@pools_table, key) do
      [{^key, pool}] ->
        ControlPool.close(pool)
        :ets.delete(@pools_table, key)

      [] ->
        :ok
    end

    :ok
  end

  # Private helpers

  defp get_or_create_pool(sprite) do
    key = sprite_key(sprite)

    case :ets.lookup(@pools_table, key) do
      [{^key, pool}] ->
        if Process.alive?(pool) do
          pool
        else
          create_pool(sprite, key)
        end

      [] ->
        create_pool(sprite, key)
    end
  end

  defp create_pool(sprite, key) do
    url = Sprite.control_url(sprite)
    token = Sprite.token(sprite)

    {:ok, pool} = ControlPool.start(url: url, token: token)
    :ets.insert(@pools_table, {key, pool})
    pool
  end

  defp sprite_key(%Sprite{name: name, client: client}) do
    {client.base_url, name}
  end
end
