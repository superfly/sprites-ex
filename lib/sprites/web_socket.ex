defmodule Sprites.WebSocket do
  @moduledoc false
  # A minimal WebSocket client over Mint, shared by Command, ControlConn and
  # Proxy. `connect/3` runs the handshake in passive mode in the calling
  # process, then leaves the socket in active mode: the caller must pass socket
  # messages to `stream/2`. Pings are answered here; callers see only data and
  # close frames.

  alias Sprites.{Error, Transport}

  defstruct [:conn, :ref, :websocket]

  @opaque t :: %__MODULE__{}
  @type frame :: {:text, binary()} | {:binary, binary()} | {:close, integer() | nil, binary()}

  @default_timeout 10_000

  @doc """
  Opens a WebSocket connection. Returns any frames the server sent in the same
  packet as its upgrade response; the caller must handle them before streaming.
  """
  @spec connect(String.t(), Mint.Types.headers(), timeout()) ::
          {:ok, t(), [frame()]} | {:error, term()}
  def connect(url, headers, timeout \\ @default_timeout) do
    uri = URI.parse(url)
    {http_scheme, ws_scheme} = if uri.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    deadline = System.monotonic_time(:millisecond) + timeout

    opts = [protocols: [:http1], mode: :passive, transport_opts: transport_opts(http_scheme)]

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, port, opts),
         {:ok, conn, ref} <- upgrade(ws_scheme, conn, path, headers),
         {:ok, conn, status, resp_headers, body} <- await_response(conn, ref, deadline) do
      if status == 101 do
        finish_upgrade(conn, ref, resp_headers, body)
      else
        Mint.HTTP.close(conn)

        case Error.parse_api_error(status, body, resp_headers) do
          {:ok, %Error.APIError{} = error} -> {:error, error}
          {:ok, nil} -> {:error, {:upgrade_failed, status}}
        end
      end
    else
      {:error, reason} -> {:error, unwrap(reason)}
    end
  end

  @doc """
  Processes a message received by the connection's owner process.
  Returns `:unknown` for messages that do not belong to this connection.
  """
  @spec stream(t(), term()) ::
          {:ok, t(), [frame()]} | {:error, t(), term(), [frame()]} | :unknown
  def stream(%__MODULE__{conn: conn} = ws, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        decode_responses(%{ws | conn: conn}, responses)

      {:error, conn, reason, responses} ->
        case decode_responses(%{ws | conn: conn}, responses) do
          {:ok, ws, frames} -> {:error, ws, unwrap(reason), frames}
          error -> error
        end

      :unknown ->
        :unknown
    end
  end

  @doc """
  Sends a frame.
  """
  @spec send_frame(t(), Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()) ::
          {:ok, t()} | {:error, t(), term()}
  def send_frame(%__MODULE__{} = ws, frame) do
    case Mint.WebSocket.encode(ws.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(ws.conn, ws.ref, data) do
          {:ok, conn} ->
            {:ok, %{ws | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, %{ws | conn: conn, websocket: websocket}, unwrap(reason)}
        end

      {:error, websocket, reason} ->
        {:error, %{ws | websocket: websocket}, reason}
    end
  end

  @doc """
  Sends a close frame (best effort) and closes the socket.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = ws) do
    _ = send_frame(ws, :close)
    {:ok, _conn} = Mint.HTTP.close(ws.conn)
    :ok
  end

  defp transport_opts(:https), do: Transport.tls_opts() ++ [timeout: @default_timeout]
  defp transport_opts(:http), do: [timeout: @default_timeout]

  defp upgrade(ws_scheme, conn, path, headers) do
    case Mint.WebSocket.upgrade(ws_scheme, conn, path, headers) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  # Collects the upgrade (or error) response. For a 101, any body bytes are
  # WebSocket frames that arrived with the response.
  defp await_response(conn, ref, deadline, acc \\ {nil, [], []}) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Mint.WebSocket.recv(conn, 0, remaining) do
      {:ok, conn, responses} ->
        case Enum.reduce(responses, {:cont, acc}, &collect_response(&1, &2, ref)) do
          {:done, {status, headers, body}} ->
            {:ok, conn, status, headers, IO.iodata_to_binary(body)}

          {:cont, acc} ->
            await_response(conn, ref, deadline, acc)
        end

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)

        case reason do
          %Mint.TransportError{reason: :timeout} -> {:error, :upgrade_timeout}
          reason -> {:error, reason}
        end
    end
  end

  defp collect_response(_response, {:done, _} = done, _ref), do: done

  defp collect_response(response, {:cont, {status, headers, body} = acc}, ref) do
    case response do
      {:status, ^ref, status} -> {:cont, {status, headers, body}}
      {:headers, ^ref, more} -> {:cont, {status, headers ++ more, body}}
      {:data, ^ref, data} -> {:cont, {status, headers, [body | data]}}
      {:done, ^ref} -> {:done, acc}
      _ -> {:cont, acc}
    end
  end

  defp finish_upgrade(conn, ref, headers, body) do
    with {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, 101, headers, mode: :active),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :active),
         ws = %__MODULE__{conn: conn, ref: ref, websocket: websocket},
         {:ok, ws, frames} <- decode_responses(ws, [{:data, ref, body}]) do
      # Frames that arrived with the 101 response must not be dropped.
      {:ok, ws, frames}
    else
      {:error, %__MODULE__{} = ws, reason, _frames} ->
        Mint.HTTP.close(ws.conn)
        {:error, reason}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, unwrap(reason)}

      {:error, reason} ->
        Mint.HTTP.close(conn)
        {:error, unwrap(reason)}
    end
  end

  # Decodes `{:data, ref, binary}` responses into frames, answering pings.
  # On error, returns the frames decoded before the failure.
  defp decode_responses(ws, responses, acc \\ [])

  defp decode_responses(ws, [], acc), do: {:ok, ws, Enum.reverse(acc)}

  defp decode_responses(%{ref: ref} = ws, [{:data, ref, data} | rest], acc) do
    case Mint.WebSocket.decode(ws.websocket, data) do
      {:ok, websocket, frames} ->
        case handle_frames(%{ws | websocket: websocket}, frames, acc) do
          {:ok, ws, acc} -> decode_responses(ws, rest, acc)
          {:error, ws, reason, acc} -> {:error, ws, reason, Enum.reverse(acc)}
        end

      {:error, websocket, reason} ->
        {:error, %{ws | websocket: websocket}, reason, Enum.reverse(acc)}
    end
  end

  defp decode_responses(ws, [_other | rest], acc), do: decode_responses(ws, rest, acc)

  defp handle_frames(ws, [], acc), do: {:ok, ws, acc}

  defp handle_frames(ws, [{:ping, payload} | rest], acc) do
    case send_frame(ws, {:pong, payload}) do
      {:ok, ws} -> handle_frames(ws, rest, acc)
      {:error, ws, reason} -> {:error, ws, reason, acc}
    end
  end

  defp handle_frames(ws, [{:pong, _} | rest], acc), do: handle_frames(ws, rest, acc)
  defp handle_frames(ws, [{:error, reason} | _], acc), do: {:error, ws, reason, acc}
  defp handle_frames(ws, [frame | rest], acc), do: handle_frames(ws, rest, [frame | acc])

  defp unwrap(%Mint.TransportError{reason: reason}), do: reason
  defp unwrap(%Mint.HTTPError{reason: reason}), do: reason
  defp unwrap(reason), do: reason
end
