defmodule Sprites.Command do
  @moduledoc """
  Represents a running command on a sprite.

  Uses a GenServer to manage the WebSocket connection via gun.
  Messages are sent to the owner process:

    * `{:stdout, command, data}` - stdout data received
    * `{:stderr, command, data}` - stderr data received
    * `{:exit, command, exit_code}` - command completed
    * `{:error, command, reason}` - error occurred
  """

  use GenServer
  require Logger

  alias Sprites.{Sprite, Protocol, Error}

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
    url = Sprite.exec_url(sprite, command, args, opts)
    tty_mode = Keyword.get(opts, :tty, false)
    token = Sprite.token(sprite)

    state = %{
      owner: owner,
      ref: ref,
      tty_mode: tty_mode,
      conn: nil,
      stream_ref: nil,
      exit_code: nil,
      token: token,
      url: url
    }

    # Connect asynchronously but wait for connection in init
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

  @impl true
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
      send(state.owner, {:error, %{ref: state.ref}, reason})
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

  @impl true
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

  @impl true
  def handle_cast(:close_stdin, %{conn: conn, stream_ref: stream_ref, tty_mode: false} = state)
      when conn != nil do
    frame_data = Protocol.encode_stdin_eof()
    :gun.ws_send(conn, stream_ref, {:binary, frame_data})
    {:noreply, state}
  end

  def handle_cast(:close_stdin, state), do: {:noreply, state}

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

  @impl true
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
        send(owner, {:exit, %{ref: ref}, code})
        # Send close frame and stop
        if state.conn do
          :gun.ws_send(state.conn, state.stream_ref, :close)
        end

        {:stop, :normal, %{state | exit_code: code}}

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
        send(owner, {:exit, %{ref: ref}, code})

        if state.conn do
          :gun.ws_send(state.conn, state.stream_ref, :close)
        end

        {:stop, :normal, %{state | exit_code: code}}

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
