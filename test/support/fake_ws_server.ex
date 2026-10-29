defmodule Sprites.Test.FakeWsServer do
  @moduledoc """
  Minimal WebSocket server standing in for the Sprites exec and control
  endpoints, for use in tests.

  Accepts a single connection, completes the WebSocket upgrade, and sends the
  `:owner` process (default: the caller of `start_link/1`):

    * `{:ws_request, path, query}` — the upgrade request's path and decoded query
    * `{:ws_frame, :text | :binary, payload}` — each client frame, unmasked

  Options:

    * `:owner` — process to notify (pass `self()` when using `start_supervised!`)
    * `:frames` — binary frames to send to the client once connected

  Use `url/1` for the server's base URL (`http://127.0.0.1:PORT`).
  """

  use GenServer

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))
  end

  @doc "Base URL for pointing a `Sprites.Client` at this server."
  @spec url(pid()) :: String.t()
  def url(pid), do: "http://127.0.0.1:#{GenServer.call(pid, :port)}"

  @impl true
  def init(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    # Hand the listen socket to a helper so accept/2 doesn't block this server
    server = self()
    spawn_link(fn -> accept(listen, server) end)

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       port: port,
       socket: nil,
       buffer: "",
       frames: Keyword.get(opts, :frames, [])
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:accepted, socket}, state) do
    :ok = :inet.setopts(socket, active: true)
    {:noreply, %{state | socket: socket}}
  end

  # HTTP upgrade request (before the handshake completes)
  def handle_info({:tcp, socket, data}, %{socket: socket, upgraded: _} = state) do
    {:noreply, handle_frames(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    buffer = state.buffer <> data

    if String.contains?(buffer, "\r\n\r\n") do
      [headers, rest] = String.split(buffer, "\r\n\r\n", parts: 2)
      upgrade(socket, headers, state.owner)

      for frame <- state.frames,
          do: :ok = :gen_tcp.send(socket, [<<0x82>>, encode_length(byte_size(frame)), frame])

      {:noreply, handle_frames(Map.put(%{state | buffer: rest}, :upgraded, true))}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:noreply, %{state | socket: nil}}
  def handle_info(_message, state), do: {:noreply, state}

  defp accept(listen, server) do
    {:ok, socket} = :gen_tcp.accept(listen)
    :ok = :gen_tcp.controlling_process(socket, server)
    send(server, {:accepted, socket})
  end

  defp upgrade(socket, headers, owner) do
    [_, target] = Regex.run(~r/^GET (\S+) HTTP/, headers)
    %URI{path: path, query: query} = URI.parse(target)
    send(owner, {:ws_request, path, URI.decode_query(query || "")})

    [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, headers)
    accept_key = Base.encode64(:crypto.hash(:sha, key <> @ws_guid))

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "upgrade: websocket\r\nconnection: Upgrade\r\n",
        "sec-websocket-accept: #{accept_key}\r\n\r\n"
      ])
  end

  # Decode every complete client frame in the buffer; keep any partial tail.
  defp handle_frames(state) do
    case decode_frame(state.buffer) do
      {:ok, opcode, payload, rest} ->
        send(state.owner, {:ws_frame, opcode, payload})
        handle_frames(%{state | buffer: rest})

      :incomplete ->
        state
    end
  end

  defp decode_frame(<<_fin::1, _rsv::3, opcode::4, 1::1, len::7, rest::binary>>) do
    with {:ok, len, rest} <- payload_length(len, rest),
         <<mask::binary-size(4), payload::binary-size(^len), rest::binary>> <- rest do
      {:ok, opcode_name(opcode), unmask(payload, mask), rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_frame(_), do: :incomplete

  defp payload_length(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp payload_length(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp payload_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp payload_length(_, _), do: :incomplete

  # Server frames are unmasked; lengths use the short/16-bit/64-bit forms.
  defp encode_length(len) when len < 126, do: <<0::1, len::7>>
  defp encode_length(len) when len < 65_536, do: <<0::1, 126::7, len::16>>
  defp encode_length(len), do: <<0::1, 127::7, len::64>>

  defp opcode_name(1), do: :text
  defp opcode_name(2), do: :binary
  defp opcode_name(8), do: :close
  defp opcode_name(_), do: :other

  defp unmask(payload, mask) do
    for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
      <<Bitwise.bxor(byte, :binary.at(mask, rem(i, 4)))>>
    end
  end
end
