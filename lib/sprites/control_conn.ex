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
  require Logger

  @control_prefix "control:"

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

    case do_connect(url, token) do
      {:ok, conn, stream_ref} ->
        {:ok,
         %{
           conn: conn,
           stream_ref: stream_ref,
           owner: nil,
           op_active: false
         }}

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

      frame = @control_prefix <> msg
      :gun.ws_send(state.conn, state.stream_ref, {:text, frame})
      {:reply, :ok, %{state | owner: owner, op_active: true}}
    end
  end

  @impl true
  def handle_cast({:send_data, data}, %{conn: conn, stream_ref: stream_ref} = state) do
    :gun.ws_send(conn, stream_ref, {:binary, data})
    {:noreply, state}
  end

  def handle_cast({:send_text, text}, %{conn: conn, stream_ref: stream_ref} = state) do
    :gun.ws_send(conn, stream_ref, {:text, text})
    {:noreply, state}
  end

  def handle_cast(:release, state) do
    {:noreply, %{state | owner: nil, op_active: false}}
  end

  def handle_cast(:close, %{conn: conn} = state) do
    :gun.close(conn)
    {:stop, :normal, %{state | conn: nil}}
  end

  @impl true
  def handle_info({:gun_ws, conn, _stream_ref, {:binary, data}}, %{conn: conn} = state) do
    if state.owner do
      send(state.owner, {:control_data, :binary, data})
    end

    {:noreply, state}
  end

  def handle_info({:gun_ws, conn, _stream_ref, {:text, text}}, %{conn: conn} = state) do
    if String.starts_with?(text, @control_prefix) do
      payload = String.slice(text, byte_size(@control_prefix), byte_size(text))
      handle_control_message(payload, state)
    else
      if state.owner do
        send(state.owner, {:control_data, :text, text})
      end

      {:noreply, state}
    end
  end

  def handle_info({:gun_ws, conn, _stream_ref, {:close, _code, _reason}}, %{conn: conn} = state) do
    if state.owner && state.op_active do
      send(state.owner, {:control_op_error, "connection closed"})
    end

    {:stop, :normal, state}
  end

  def handle_info({:gun_down, conn, _protocol, _reason, _killed}, %{conn: conn} = state) do
    if state.owner && state.op_active do
      send(state.owner, {:control_op_error, "connection down"})
    end

    {:stop, :normal, state}
  end

  def handle_info({:gun_error, conn, _stream_ref, reason}, %{conn: conn} = state) do
    if state.owner && state.op_active do
      send(state.owner, {:control_op_error, "gun error: #{inspect(reason)}"})
    end

    {:stop, :normal, state}
  end

  def handle_info({:gun_error, conn, reason}, %{conn: conn} = state) do
    if state.owner && state.op_active do
      send(state.owner, {:control_op_error, "gun error: #{inspect(reason)}"})
    end

    {:stop, :normal, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when conn != nil do
    :gun.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

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

            receive do
              {:gun_upgrade, ^conn, ^stream_ref, ["websocket"], _headers} ->
                {:ok, conn, stream_ref}

              {:gun_response, ^conn, ^stream_ref, is_fin, status, headers} ->
                body = read_response_body(conn, stream_ref, is_fin)
                :gun.close(conn)

                case Sprites.Error.parse_api_error(status, body, headers) do
                  {:ok, %Sprites.Error.APIError{} = api_error} ->
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
