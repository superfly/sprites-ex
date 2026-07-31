defmodule Sprites.Command do
  @moduledoc """
  Represents a running command on a sprite.

  Uses a GenServer to manage the WebSocket connection via gun.
  Messages are sent to the owner process:

    * `{:stdout, command, data}` - stdout data received
    * `{:stderr, command, data}` - stderr data received
    * `{:exit, command, exit_code}` - command completed
    * `{:error, command, reason}` - error occurred

  Supports two execution modes:

    * **Direct mode** (default) — opens a new WebSocket per command to `/exec`
    * **Control mode** — multiplexes over a persistent WebSocket to `/control`
  """

  use GenServer
  require Logger

  alias Sprites.{Sprite, Protocol, Error, Control, ControlConn}

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
      conn: nil,
      stream_ref: nil,
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

    case do_connect(url, token) do
      {:ok, conn, stream_ref} ->
        {:ok, %{state | conn: conn, stream_ref: stream_ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp do_connect(url, token) do
    uri = URI.parse(url)
    host = String.to_charlist(uri.host)
    port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)

    transport = if uri.scheme == "wss", do: :tls, else: :tcp

    gun_opts = %{
      protocols: [:http],
      transport: transport,
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, conn} ->
        case :gun.await_up(conn, 10_000) do
          {:ok, _protocol} ->
            path = "#{uri.path}?#{uri.query || ""}"
            headers = [{"authorization", "Bearer #{token}"}]
            stream_ref = :gun.ws_upgrade(conn, path, headers)

            # Wait for WebSocket upgrade
            receive do
              {:gun_upgrade, ^conn, ^stream_ref, ["websocket"], _headers} ->
                {:ok, conn, stream_ref}

              {:gun_response, ^conn, ^stream_ref, is_fin, status, headers} ->
                # Try to read the response body and parse as structured API error
                body = read_response_body(conn, stream_ref, is_fin)
                :gun.close(conn)

                case Error.parse_api_error(status, body, headers) do
                  {:ok, %Error.APIError{} = api_error} ->
                    {:error, api_error}

                  {:ok, nil} ->
                    {:error, {:upgrade_failed, status}}
                end

              {:gun_error, ^conn, ^stream_ref, reason} ->
                :gun.close(conn)
                {:error, reason}

              {:gun_error, ^conn, reason} ->
                :gun.close(conn)
                {:error, reason}
            after
              10_000 ->
                :gun.close(conn)
                {:error, :upgrade_timeout}
            end

          {:error, reason} ->
            :gun.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  def handle_info({:gun_ws, conn, _stream_ref, {:binary, data}}, %{conn: conn} = state) do
    handle_binary_frame(data, state)
  end

  def handle_info({:gun_ws, conn, _stream_ref, {:text, json}}, %{conn: conn} = state) do
    handle_text_frame(json, state)
  end

  def handle_info({:gun_ws, conn, _stream_ref, {:close, code, reason}}, %{conn: conn} = state) do
    handle_close_frame(code, reason, state)
  end

  def handle_info({:gun_down, conn, _protocol, reason, _killed_streams}, %{conn: conn} = state) do
    if state.exit_code == nil do
      # For normal closes (:closed, :normal), drain any pending WS frames
      # from the mailbox before reporting an error. The exit frame may have
      # been delivered but not yet processed.
      state = drain_pending_frames(state)

      if state.exit_code == nil do
        # Still no exit code after draining — report as error
        send(state.owner, {:error, %{ref: state.ref}, reason})
      end
    end

    {:stop, :normal, state}
  end

  def handle_info({:gun_error, conn, _stream_ref, reason}, %{conn: conn} = state) do
    send(state.owner, {:error, %{ref: state.ref}, reason})
    {:stop, :normal, state}
  end

  def handle_info({:gun_error, conn, reason}, %{conn: conn} = state) do
    send(state.owner, {:error, %{ref: state.ref}, reason})
    {:stop, :normal, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
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

  def handle_call(
        {:write_stdin, data},
        _from,
        %{conn: conn, stream_ref: stream_ref, tty_mode: tty_mode} = state
      )
      when conn != nil do
    frame_data = Protocol.encode_stdin(data, tty_mode)
    :gun.ws_send(conn, stream_ref, {:binary, frame_data})
    {:reply, :ok, state}
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

  def handle_cast(:close_stdin, %{conn: conn, stream_ref: stream_ref, tty_mode: false} = state)
      when conn != nil do
    frame_data = Protocol.encode_stdin_eof()
    :gun.ws_send(conn, stream_ref, {:binary, frame_data})
    {:noreply, state}
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

  def handle_cast(
        {:resize, rows, cols},
        %{conn: conn, stream_ref: stream_ref, tty_mode: true} = state
      )
      when conn != nil do
    message = Jason.encode!(%{type: "resize", rows: rows, cols: cols})
    :gun.ws_send(conn, stream_ref, {:text, message})
    {:noreply, state}
  end

  def handle_cast({:resize, _, _}, state), do: {:noreply, state}

  # --- Terminate ---

  @impl true
  def terminate(_reason, %{using_control: true, control_conn: conn_pid, sprite: sprite})
      when conn_pid != nil do
    Control.checkin(sprite, conn_pid)
    :ok
  end

  def terminate(_reason, %{conn: conn}) when conn != nil do
    :gun.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

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

          if state.conn do
            :gun.ws_send(state.conn, state.stream_ref, :close)
          end

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
      {:ok, %{"type" => "port", "port" => port}} ->
        send(owner, {:port, %{ref: ref}, port})
        {:noreply, state}

      {:ok, %{"type" => "exit", "code" => code}} ->
        if state.using_control do
          send(owner, {:exit, %{ref: ref}, code})
          {:noreply, %{state | exit_code: code}}
        else
          send(owner, {:exit, %{ref: ref}, code})

          if state.conn do
            :gun.ws_send(state.conn, state.stream_ref, :close)
          end

          {:stop, :normal, %{state | exit_code: code}}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_close_frame(_code, _reason, %{exit_code: nil, owner: owner, ref: ref} = state) do
    send(owner, {:exit, %{ref: ref}, 0})
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

  # Drain any pending WebSocket frames from the mailbox.
  # Called on gun_down to pick up exit frames that may have arrived
  # but not yet been processed (race between data frames and connection close).
  defp drain_pending_frames(%{conn: conn} = state) do
    receive do
      {:gun_ws, ^conn, _stream_ref, {:binary, data}} ->
        {:noreply, state} = handle_binary_frame(data, state)
        drain_pending_frames(state)

      {:gun_ws, ^conn, _stream_ref, {:text, json}} ->
        case handle_text_frame(json, state) do
          {:noreply, state} -> drain_pending_frames(state)
          {:stop, :normal, state} -> state
        end
    after
      0 -> state
    end
  end

  defp drain_pending_frames(state), do: state

  # Read the response body from a failed HTTP response
  defp read_response_body(_conn, _stream_ref, :fin), do: ""

  defp read_response_body(conn, stream_ref, :nofin) do
    receive do
      {:gun_data, ^conn, ^stream_ref, :fin, data} ->
        data

      {:gun_data, ^conn, ^stream_ref, :nofin, data} ->
        data <> read_response_body(conn, stream_ref, :nofin)
    after
      5_000 ->
        ""
    end
  end
end
