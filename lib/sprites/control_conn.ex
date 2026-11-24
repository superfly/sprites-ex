defmodule Sprites.ControlConn do
  @moduledoc """
  A persistent WebSocket connection to a sprite's control endpoint.

  Multiplexes exec operations over a single connection at `/v1/sprites/{name}/control`.
  Each connection handles one operation at a time — the pool manages concurrency.

  Messages sent to the owner process during an active operation:

    * `{:control_data, :binary, data}` — binary frame (stdout/stderr/exit in protocol encoding)
    * `{:control_data, :text, text}` — text frame (JSON messages like port, resize)
    * `{:control_op_complete, exit_code}` — operation completed
    * `{:control_op_error, message}` — operation errored
  """

  use GenServer
  @control_prefix "control:"

  alias Sprites.{ClientSignals, WebSocket}

  # Client API

  @doc """
  Starts a control connection to the given sprite.

  Returns `{:error, {:control_not_supported, status}}` if the server returns 404.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a control connection (unlinked) to the given sprite.

  Returns `{:error, {:control_not_supported, status}}` if the server returns 404.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Starts an operation on this control connection.

  Sends an `op.start` control message. The owner process will receive
  data frames and completion messages.
  """
  @spec start_op(pid(), pid(), String.t(), map()) :: :ok | {:error, term()}
  def start_op(pid, owner, op, args) do
    GenServer.call(pid, {:start_op, owner, op, args})
  end

  @doc """
  Sends binary data (stdin) through the control connection.
  """
  @spec send_data(pid(), binary()) :: :ok
  def send_data(pid, data) do
    GenServer.cast(pid, {:send_data, data})
  end

  @doc """
  Sends a text frame through the control connection.
  """
  @spec send_text(pid(), String.t()) :: :ok
  def send_text(pid, text) do
    GenServer.cast(pid, {:send_text, text})
  end

  @doc """
  Releases the connection, clearing the current owner.
  """
  @spec release(pid()) :: :ok
  def release(pid) do
    GenServer.cast(pid, :release)
  end

  @doc """
  Closes the control connection.
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    token = Keyword.fetch!(opts, :token)

    case WebSocket.connect(url, ClientSignals.auth_headers(token)) do
      {:ok, ws, frames} ->
        state = %{conn: ws, owner: nil, op_active: false}

        if frames == [],
          do: {:ok, state},
          else: {:ok, state, {:continue, {:frames, frames}}}

      {:error, {:upgrade_failed, 404}} ->
        {:stop, {:control_not_supported, 404}}

      {:error, %Sprites.Error.APIError{status: 404}} ->
        {:stop, {:control_not_supported, 404}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:start_op, owner, op, args}, _from, state) do
    if state.op_active do
      {:reply, {:error, :operation_in_progress}, state}
    else
      msg =
        Jason.encode!(%{
          type: "op.start",
          op: op,
          args: args
        })

      case WebSocket.send_frame(state.conn, {:text, @control_prefix <> msg}) do
        {:ok, ws} -> {:reply, :ok, %{state | conn: ws, owner: owner, op_active: true}}
        {:error, ws, reason} -> {:reply, {:error, reason}, %{state | conn: ws}}
      end
    end
  end

  @impl true
  def handle_cast({:send_data, data}, state), do: send_frame(state, {:binary, data})
  def handle_cast({:send_text, text}, state), do: send_frame(state, {:text, text})

  def handle_cast(:release, state) do
    {:noreply, %{state | owner: nil, op_active: false}}
  end

  def handle_cast(:close, state), do: {:stop, :normal, state}

  @impl true
  def handle_continue({:frames, frames}, state), do: handle_frames(frames, state)

  @impl true
  def handle_info(message, %{conn: %WebSocket{} = ws} = state) do
    case WebSocket.stream(ws, message) do
      {:ok, ws, frames} ->
        handle_frames(frames, %{state | conn: ws})

      {:error, ws, reason, frames} ->
        case handle_frames(frames, %{state | conn: ws}) do
          {:noreply, state} -> connection_lost("connection error: #{inspect(reason)}", state)
          stop -> stop
        end

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: %WebSocket{} = ws}), do: WebSocket.close(ws)
  def terminate(_reason, _state), do: :ok

  @doc false
  # Handles decoded frames in order, stopping at the first terminal frame.
  def handle_frames([], state), do: {:noreply, state}

  def handle_frames([frame | rest], state) do
    case handle_frame(frame, state) do
      {:noreply, state} -> handle_frames(rest, state)
      stop -> stop
    end
  end

  # Private helpers

  defp handle_frame({:binary, data}, state) do
    if state.owner do
      send(state.owner, {:control_data, :binary, data})
    end

    {:noreply, state}
  end

  defp handle_frame({:text, @control_prefix <> payload}, state) do
    handle_control_message(payload, state)
  end

  defp handle_frame({:text, text}, state) do
    if state.owner do
      send(state.owner, {:control_data, :text, text})
    end

    {:noreply, state}
  end

  defp handle_frame({:close, _code, _reason}, state) do
    connection_lost("connection closed", state)
  end

  defp connection_lost(message, state) do
    if state.owner && state.op_active do
      send(state.owner, {:control_op_error, message})
    end

    {:stop, :normal, state}
  end

  # A failed send means the socket is gone; its close message stops this process.
  defp send_frame(state, frame) do
    case WebSocket.send_frame(state.conn, frame) do
      {:ok, ws} -> {:noreply, %{state | conn: ws}}
      {:error, ws, _reason} -> {:noreply, %{state | conn: ws}}
    end
  end

  defp handle_control_message(payload, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "op.complete", "args" => %{"exitCode" => exit_code}}} ->
        if state.owner do
          send(state.owner, {:control_op_complete, exit_code})
        end

        {:noreply, %{state | op_active: false}}

      {:ok, %{"type" => "op.complete"}} ->
        if state.owner do
          send(state.owner, {:control_op_complete, 0})
        end

        {:noreply, %{state | op_active: false}}

      {:ok, %{"type" => "op.error", "args" => %{"error" => error}}} ->
        if state.owner do
          send(state.owner, {:control_op_error, error})
        end

        {:noreply, %{state | op_active: false}}

      {:ok, %{"type" => "op.error"}} ->
        if state.owner do
          send(state.owner, {:control_op_error, "unknown error"})
        end

        {:noreply, %{state | op_active: false}}

      _ ->
        {:noreply, state}
    end
  end
end
