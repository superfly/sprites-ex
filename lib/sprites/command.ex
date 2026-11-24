defmodule Sprites.Command do
  @moduledoc """
  Represents a running command on a sprite.

  Uses a GenServer to manage the WebSocket connection.
  Messages are sent to the owner process:

    * `{:stdout, command, data}` - stdout data received
    * `{:stderr, command, data}` - stderr data received
    * `{:exit, command, exit_code}` - command completed
    * `{:error, command, reason}` - error occurred
    * `{:session_info, %{ref: ref}, session_id}` - provider session identity
      (only when `session_info: true`; normalized to a string)

  Supports two execution modes:

    * **Direct mode** (default) — opens a new WebSocket per command to `/exec`
    * **Control mode** — multiplexes over a persistent WebSocket to `/control`
  """

  use GenServer

  alias Sprites.{Sprite, Protocol, Control, ControlConn, ClientSignals, WebSocket}

  defstruct [:ref, :pid, :sprite, :owner, :tty_mode]

  @type t :: %__MODULE__{
          ref: reference(),
          pid: pid(),
          sprite: Sprite.t(),
          owner: pid(),
          tty_mode: boolean()
        }

  # Client API

  @doc """
  Starts a command asynchronously.
  """
  @spec start(Sprite.t(), String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(sprite, command, args, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    tty_mode = Keyword.get(opts, :tty, false)

    ref = make_ref()

    init_args = %{
      sprite: sprite,
      command: command,
      args: args,
      opts: opts,
      owner: owner,
      ref: ref
    }

    case GenServer.start(__MODULE__, init_args) do
      {:ok, pid} ->
        {:ok,
         %__MODULE__{
           ref: ref,
           pid: pid,
           sprite: sprite,
           owner: owner,
           tty_mode: tty_mode
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs a command synchronously (blocking).
  Returns `{output, exit_code}`.
  """
  @spec run(Sprite.t(), String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}
  def run(sprite, command, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)

    case start(sprite, command, args, opts) do
      {:ok, cmd} ->
        collect_output(cmd, "", stderr_to_stdout, timeout)

      {:error, reason} ->
        raise "Failed to start command: #{inspect(reason)}"
    end
  end

  @doc """
  Writes to stdin.
  """
  @spec write_stdin(t(), iodata()) :: :ok | {:error, term()}
  def write_stdin(%__MODULE__{pid: pid}, data) do
    GenServer.call(pid, {:write_stdin, data})
  end

  @doc """
  Closes stdin (sends EOF).
  """
  @spec close_stdin(t()) :: :ok
  def close_stdin(%__MODULE__{pid: pid}) do
    GenServer.cast(pid, :close_stdin)
  end

  @doc """
  Waits for command completion.
  """
  @spec await(t(), timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  def await(%__MODULE__{ref: ref}, timeout \\ :infinity) do
    receive do
      {:exit, %{ref: ^ref}, exit_code} -> {:ok, exit_code}
      {:error, %{ref: ^ref}, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Resizes the TTY.
  """
  @spec resize(t(), pos_integer(), pos_integer()) :: :ok
  def resize(%__MODULE__{pid: pid}, rows, cols) do
    GenServer.cast(pid, {:resize, rows, cols})
  end

  # GenServer callbacks

  @impl true
  def init(%{sprite: sprite, command: command, args: args, opts: opts, owner: owner, ref: ref}) do
    tty_mode = Keyword.get(opts, :tty, false)
    token = Sprite.token(sprite)
    stdin = Keyword.get(opts, :stdin, false)

    base_state = %{
      owner: owner,
      ref: ref,
      tty_mode: tty_mode,
      report_session_info: Keyword.get(opts, :session_info, false) == true,
      session_id: nil,
      conn: nil,
      exit_code: nil,
      token: token,
      sprite: sprite,
      using_control: false,
      control_conn: nil
    }

    if Sprite.control_mode?(sprite) and Control.control_supported?(sprite) do
      case try_control_connect(sprite, command, args, opts, stdin, base_state) do
        {:ok, state} ->
          {:ok, state}

        {:fallback, _reason} ->
          do_direct_init(sprite, command, args, opts, token, base_state)
      end
    else
      do_direct_init(sprite, command, args, opts, token, base_state)
    end
  end

  defp try_control_connect(sprite, command, args, opts, stdin, state) do
    case Control.checkout(sprite) do
      {:ok, conn_pid} ->
        op_args = build_control_args(command, args, opts, stdin)

        case ControlConn.start_op(conn_pid, self(), "exec", op_args) do
          :ok ->
            {:ok, %{state | using_control: true, control_conn: conn_pid}}

          {:error, reason} ->
            Control.checkin(sprite, conn_pid)
            {:fallback, reason}
        end

      {:error, {:control_not_supported, _}} ->
        Control.mark_unsupported(sprite)
        {:fallback, :control_not_supported}

      {:error, reason} ->
        {:fallback, reason}
    end
  end

  defp build_control_args(command, args, opts, stdin) do
    control_args = %{"cmd" => [command | args]}

    control_args =
      case Keyword.get(opts, :dir) do
        nil -> control_args
        dir -> Map.put(control_args, "dir", dir)
      end

    control_args =
      case Keyword.get(opts, :env, []) do
        [] ->
          control_args

        env_list ->
          env_strs = Enum.map(env_list, fn {k, v} -> "#{k}=#{v}" end)
          Map.put(control_args, "env", env_strs)
      end

    control_args =
      if Keyword.get(opts, :tty, false) do
        rows = Keyword.get(opts, :tty_rows, 24)
        cols = Keyword.get(opts, :tty_cols, 80)

        control_args
        |> Map.put("tty", "true")
        |> Map.put("rows", to_string(rows))
        |> Map.put("cols", to_string(cols))
      else
        control_args
      end

    Map.put(control_args, "stdin", if(stdin, do: "true", else: "false"))
  end

  defp do_direct_init(sprite, command, args, opts, token, state) do
    url = Sprite.exec_url(sprite, command, args, opts)
    state = Map.put(state, :url, url)

    case WebSocket.connect(url, ClientSignals.auth_headers(token)) do
      {:ok, ws, []} -> {:ok, %{state | conn: ws}}
      {:ok, ws, frames} -> {:ok, %{state | conn: ws}, {:continue, {:frames, frames}}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue({:frames, frames}, state), do: handle_frames(frames, state)

  # --- Control mode handle_info clauses ---

  @impl true
  def handle_info(
        {:control_data, :binary, data},
        %{using_control: true} = state
      ) do
    handle_binary_frame(data, state)
  end

  def handle_info(
        {:control_data, :text, text},
        %{using_control: true} = state
      ) do
    handle_text_frame(text, state)
  end

  def handle_info({:control_op_complete, code}, %{using_control: true} = state)
      when not (is_integer(code) and code in 0..255) do
    protocol_error(state, :invalid_exit_code)
  end

  def handle_info(
        {:control_op_complete, exit_code},
        %{using_control: true, owner: owner, ref: ref, sprite: sprite, control_conn: conn_pid} =
          state
      ) do
    # In control mode, op.complete is the authoritative signal.
    # If we haven't already sent an exit message (from exit stream), send now.
    if state.exit_code == nil do
      send(owner, {:exit, %{ref: ref}, exit_code})
    end

    Control.checkin(sprite, conn_pid)
    {:stop, :normal, %{state | exit_code: exit_code, control_conn: nil}}
  end

  def handle_info(
        {:control_op_error, reason},
        %{using_control: true, owner: owner, ref: ref, sprite: sprite, control_conn: conn_pid} =
          state
      ) do
    send(owner, {:error, %{ref: ref}, reason})
    Control.checkin(sprite, conn_pid)
    {:stop, :normal, %{state | control_conn: nil}}
  end

  # --- Direct mode handle_info clauses ---

  def handle_info(message, %{conn: %WebSocket{} = ws} = state) do
    case WebSocket.stream(ws, message) do
      {:ok, ws, frames} ->
        handle_frames(frames, %{state | conn: ws})

      {:error, ws, reason, frames} ->
        case handle_frames(frames, %{state | conn: ws}) do
          {:noreply, state} -> connection_lost(reason, state)
          stop -> stop
        end

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @doc false
  # Handles decoded frames in order, stopping at the first terminal frame.
  def handle_frames([], state), do: {:noreply, state}

  def handle_frames([frame | rest], state) do
    case handle_frame(frame, state) do
      {:noreply, state} -> handle_frames(rest, state)
      stop -> stop
    end
  end

  defp handle_frame({:binary, data}, state), do: handle_binary_frame(data, state)
  defp handle_frame({:text, json}, state), do: handle_text_frame(json, state)
  defp handle_frame({:close, code, reason}, state), do: handle_close_frame(code, reason, state)

  defp connection_lost(reason, state) do
    if state.exit_code == nil and is_nil(Map.get(state, :terminal_error)) do
      send(state.owner, {:error, %{ref: state.ref}, reason})
    end

    {:stop, :normal, state}
  end

  # --- Write stdin ---

  @impl true
  def handle_call(
        {:write_stdin, data},
        _from,
        %{using_control: true, control_conn: conn_pid, tty_mode: tty_mode} = state
      )
      when conn_pid != nil do
    frame_data = Protocol.encode_stdin(data, tty_mode)
    ControlConn.send_data(conn_pid, frame_data)
    {:reply, :ok, state}
  end

  def handle_call({:write_stdin, data}, _from, %{conn: %WebSocket{} = ws} = state) do
    case WebSocket.send_frame(ws, {:binary, Protocol.encode_stdin(data, state.tty_mode)}) do
      {:ok, ws} -> {:reply, :ok, %{state | conn: ws}}
      {:error, ws, reason} -> {:reply, {:error, reason}, %{state | conn: ws}}
    end
  end

  def handle_call({:write_stdin, _data}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  # --- Close stdin ---

  @impl true
  def handle_cast(
        :close_stdin,
        %{using_control: true, control_conn: conn_pid, tty_mode: false} = state
      )
      when conn_pid != nil do
    frame_data = Protocol.encode_stdin_eof()
    ControlConn.send_data(conn_pid, frame_data)
    {:noreply, state}
  end

  def handle_cast(:close_stdin, %{conn: %WebSocket{}, tty_mode: false} = state) do
    send_direct(state, {:binary, Protocol.encode_stdin_eof()})
  end

  def handle_cast(:close_stdin, state), do: {:noreply, state}

  # --- Resize ---

  def handle_cast(
        {:resize, rows, cols},
        %{using_control: true, control_conn: conn_pid, tty_mode: true} = state
      )
      when conn_pid != nil do
    message = Jason.encode!(%{type: "resize", rows: rows, cols: cols})
    ControlConn.send_text(conn_pid, message)
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, %{conn: %WebSocket{}, tty_mode: true} = state) do
    send_direct(state, {:text, Jason.encode!(%{type: "resize", rows: rows, cols: cols})})
  end

  def handle_cast({:resize, _, _}, state), do: {:noreply, state}

  # --- Terminate ---

  @impl true
  def terminate(_reason, %{using_control: true, control_conn: conn_pid, sprite: sprite})
      when conn_pid != nil do
    Control.checkin(sprite, conn_pid)
    :ok
  end

  def terminate(_reason, %{conn: %WebSocket{} = ws}), do: WebSocket.close(ws)

  def terminate(_reason, _state), do: :ok

  # Private helpers

  # A failed send means the socket is gone; its close message ends the command.
  defp send_direct(state, frame) do
    case WebSocket.send_frame(state.conn, frame) do
      {:ok, ws} -> {:noreply, %{state | conn: ws}}
      {:error, ws, _reason} -> {:noreply, %{state | conn: ws}}
    end
  end

  defp handle_binary_frame(data, %{tty_mode: true, owner: owner, ref: ref} = state) do
    send(owner, {:stdout, %{ref: ref}, data})
    {:noreply, state}
  end

  defp handle_binary_frame(data, %{tty_mode: false, owner: owner, ref: ref} = state) do
    case Protocol.decode(data) do
      {:stdout, payload} ->
        send(owner, {:stdout, %{ref: ref}, payload})
        {:noreply, state}

      {:stderr, payload} ->
        send(owner, {:stderr, %{ref: ref}, payload})
        {:noreply, state}

      {:exit, code} ->
        if state.using_control do
          # In control mode, store exit code but DON'T stop.
          # Wait for op.complete to ensure proper sequencing.
          send(owner, {:exit, %{ref: ref}, code})
          {:noreply, %{state | exit_code: code}}
        else
          send(owner, {:exit, %{ref: ref}, code})
          {:stop, :normal, %{state | exit_code: code}}
        end

      {:stdin_eof, _} ->
        {:noreply, state}

      {:unknown, _} ->
        {:noreply, state}
    end
  end

  defp handle_text_frame(json, %{owner: owner, ref: ref} = state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "session_info"} = message} ->
        handle_session_info(message, state)

      {:ok, %{"type" => "port", "port" => port}} ->
        send(owner, {:port, %{ref: ref}, port})
        {:noreply, state}

      {:ok, %{"type" => "exit", "exit_code" => code}}
      when not (is_integer(code) and code in 0..255) ->
        protocol_error(state, :invalid_exit_code)

      {:ok, %{"type" => "exit"} = message} ->
        code = Map.get(message, "exit_code", 0)

        if state.using_control do
          send(owner, {:exit, %{ref: ref}, code})
          {:noreply, %{state | exit_code: code}}
        else
          send(owner, {:exit, %{ref: ref}, code})
          {:stop, :normal, %{state | exit_code: code}}
        end

      _ ->
        {:noreply, state}
    end
  end

  # Only provider control metadata establishes this identity. Never infer it
  # from stdout, process argv, or a session listing that may contain neighbors.
  defp handle_session_info(_message, %{exit_code: code} = state) when not is_nil(code),
    do: {:noreply, state}

  defp handle_session_info(message, %{report_session_info: true} = state) do
    case {normalize_session_id(message["session_id"]), state.session_id} do
      {{:ok, id}, nil} ->
        send(state.owner, {:session_info, %{ref: state.ref}, id})
        {:noreply, %{state | session_id: id}}

      {{:ok, id}, id} ->
        {:noreply, state}

      {{:ok, _other}, _original} ->
        protocol_error(state, :conflicting_session_info)

      {:error, _} ->
        protocol_error(state, :invalid_session_info)
    end
  end

  defp handle_session_info(_message, state), do: {:noreply, state}

  defp normalize_session_id(id) when is_integer(id) and id > 0,
    do: {:ok, Integer.to_string(id)}

  defp normalize_session_id(id) when is_binary(id) and byte_size(id) in 1..256 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id), do: {:ok, id}, else: :error
  end

  defp normalize_session_id(_), do: :error

  defp protocol_error(state, reason) do
    send(state.owner, {:error, %{ref: state.ref}, reason})

    # An active control operation must not be returned to the reusable pool.
    # The pool monitors this connection and removes it when it closes.
    state =
      if state.using_control and is_pid(state.control_conn) do
        ControlConn.close(state.control_conn)
        %{state | control_conn: nil}
      else
        state
      end

    {:stop, :normal, Map.put(state, :terminal_error, reason)}
  end

  defp handle_close_frame(_code, _reason, %{exit_code: nil} = state) do
    if is_nil(Map.get(state, :terminal_error)) do
      send(state.owner, {:error, %{ref: state.ref}, :closed_before_exit})
    end

    {:stop, :normal, state}
  end

  defp handle_close_frame(_code, _reason, state) do
    {:stop, :normal, state}
  end

  defp collect_output(cmd, acc, stderr_to_stdout, timeout) do
    ref = cmd.ref

    receive do
      {:stdout, %{ref: ^ref}, data} ->
        collect_output(cmd, acc <> data, stderr_to_stdout, timeout)

      {:stderr, %{ref: ^ref}, data} when stderr_to_stdout ->
        collect_output(cmd, acc <> data, stderr_to_stdout, timeout)

      {:stderr, %{ref: ^ref}, _data} ->
        collect_output(cmd, acc, stderr_to_stdout, timeout)

      {:exit, %{ref: ^ref}, code} ->
        {acc, code}

      {:error, %{ref: ^ref}, reason} ->
        raise "Command failed: #{inspect(reason)}"
    after
      timeout ->
        raise Sprites.Error.TimeoutError, timeout: timeout
    end
  end
end
