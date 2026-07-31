defmodule Sprites.ControlPool do
  @moduledoc """
  Pool of `Sprites.ControlConn` processes for a single sprite.

  Manages connection lifecycle with checkout/checkin semantics and
  automatic draining when the pool grows too large.
  """

  use GenServer
  require Logger

  alias Sprites.ControlConn

  @max_pool_size 100
  @drain_threshold 20
  @drain_target 10

  # Client API

  @doc """
  Starts a control pool for the given sprite.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a control pool (unlinked) for the given sprite.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Checks out a control connection from the pool.

  Returns an idle connection or creates a new one.
  Returns `{:error, {:control_not_supported, 404}}` if the server doesn't support control mode.
  """
  @spec checkout(pid()) :: {:ok, pid()} | {:error, term()}
  def checkout(pid) do
    GenServer.call(pid, :checkout, 30_000)
  end

  @doc """
  Returns a connection to the pool.
  """
  @spec checkin(pid(), pid()) :: :ok
  def checkin(pid, conn_pid) do
    GenServer.cast(pid, {:checkin, conn_pid})
  end

  @doc """
  Closes all connections in the pool and stops the GenServer.
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    {:ok,
     %{
       url: Keyword.fetch!(opts, :url),
       token: Keyword.fetch!(opts, :token),
       conns: %{}
     }}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    # Try to find an idle connection
    case find_idle(state.conns) do
      {:ok, conn_pid} ->
        {_status, ref} = Map.get(state.conns, conn_pid)
        conns = Map.put(state.conns, conn_pid, {:busy, ref})
        {:reply, {:ok, conn_pid}, %{state | conns: conns}}

      :none ->
        if map_size(state.conns) >= @max_pool_size do
          {:reply, {:error, :pool_full}, state}
        else
          case create_conn(state.url, state.token) do
            {:ok, conn_pid} ->
              ref = Process.monitor(conn_pid)
              conns = Map.put(state.conns, conn_pid, {:busy, ref})
              {:reply, {:ok, conn_pid}, %{state | conns: conns}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
    end
  end

  @impl true
  def handle_cast({:checkin, conn_pid}, state) do
    case Map.get(state.conns, conn_pid) do
      nil ->
        {:noreply, state}

      {_status, ref} ->
        ControlConn.release(conn_pid)
        conns = Map.put(state.conns, conn_pid, {:idle, ref})
        state = %{state | conns: conns}
        {:noreply, maybe_drain(state)}
    end
  end

  def handle_cast(:close, state) do
    Enum.each(state.conns, fn {conn_pid, _status} ->
      ControlConn.close(conn_pid)
    end)

    {:stop, :normal, %{state | conns: %{}}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, conn_pid, _reason}, state) do
    conns = Map.delete(state.conns, conn_pid)
    {:noreply, %{state | conns: conns}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # Private helpers

  defp find_idle(conns) do
    case Enum.find(conns, fn {_pid, status} -> match?({:idle, _}, status) end) do
      {pid, _} -> {:ok, pid}
      nil -> :none
    end
  end

  defp create_conn(url, token) do
    case ControlConn.start(url: url, token: token) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_drain(state) do
    if map_size(state.conns) > @drain_threshold do
      do_drain(state)
    else
      state
    end
  end

  defp do_drain(state) do
    to_close = map_size(state.conns) - @drain_target

    if to_close > 0 do
      idle_pids =
        state.conns
        |> Enum.filter(fn {_pid, status} -> match?({:idle, _}, status) end)
        |> Enum.map(fn {pid, _} -> pid end)
        |> Enum.take(to_close)

      Enum.each(idle_pids, &ControlConn.close/1)

      conns = Map.drop(state.conns, idle_pids)
      %{state | conns: conns}
    else
      state
    end
  end
end
