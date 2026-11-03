defmodule Sprites.ProxyTest do
  use ExUnit.Case, async: false

  alias Sprites.Proxy.Session
  import ExUnit.CaptureLog

  @token "synthetic-sprites-token"

  test "relays HTTP in both directions without forwarding the platform token" do
    {port, server} =
      server(fn socket, owner ->
        {headers, socket} = upgrade(socket)
        assert headers =~ "authorization: Bearer #{@token}"
        assert {:text, init} = frame(socket)
        assert Jason.decode!(init) == %{"host" => "localhost", "port" => 8642}
        send_frame(socket, {:text, ~s({"status":"connected"})})
        assert {:binary, request} = frame(socket)
        assert request =~ "authorization: Bearer hermes-key"
        refute request =~ @token
        send_frame(socket, {:binary, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"})
        send(owner, :relayed)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    session = start_proxy(port)
    {:ok, {127, 0, 0, 1}, local_port} = Session.local_addr(session)

    assert {:ok, %{status: 200, body: "ok"}} =
             Req.get("http://127.0.0.1:#{local_port}",
               auth: {:bearer, "hermes-key"},
               receive_timeout: 1_000,
               retry: false,
               finch: [pool_timeout: 1_000]
             )

    assert_receive :relayed
    Session.stop(session)
    assert_receive {:DOWN, _, :process, ^server, :normal}
  end

  test "stop closes a pending handshake and its local socket" do
    {port, server} =
      server(fn socket, owner ->
        assert {:ok, _headers} = :gen_tcp.recv(socket, 0, 1_000)
        send(owner, :handshake_pending)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    session = start_proxy(port)
    socket = connect(session)
    assert_receive :handshake_pending, 1_000
    Session.stop(session)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    assert_receive {:DOWN, _, :process, ^server, :normal}
  end

  test "parent death closes an active tunnel" do
    {port, server} =
      server(fn socket, owner ->
        upgrade(socket)
        assert {:text, _init} = frame(socket)
        send_frame(socket, {:text, ~s({"status":"connected"})})
        send(owner, :connected)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    test = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           client = Sprites.new(@token, base_url: "http://127.0.0.1:#{port}")
           {:ok, session} = Sprites.proxy_port(Sprites.sprite(client, "test"), 0, 8642)
           send(test, {:session, session})
           receive do: (:stop -> :ok)
         end}
      )

    assert_receive {:session, session}
    monitor = Process.monitor(session)
    socket = connect(session)
    assert_receive :connected, 1_000

    log =
      capture_log(fn ->
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, 1_000
      end)

    assert log =~ "redacted"
    refute log =~ @token
    refute log =~ "Bearer"
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    assert_receive {:DOWN, _, :process, ^server, :normal}
  end

  test "state inspection does not expose the platform credential" do
    session = start_proxy(1)
    refute inspect(:sys.get_state(session)) =~ @token
    refute inspect(:sys.get_status(session)) =~ @token
  end

  test "a paused consumer bounds incoming frames and resumes delivery" do
    {port, server} =
      server(fn socket, owner ->
        upgrade(socket)
        frame(socket)
        send_frame(socket, {:text, ~s({"status":"connected"})})
        assert {:binary, "ready"} = frame(socket)
        send(owner, :ready)
        receive do: (:first -> send_frame(socket, {:binary, "a"}))

        receive do
          :remaining ->
            Enum.each(1..100, fn _ -> send_frame(socket, {:binary, "b"}) end)
            send(owner, :sent)
        end

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    session = start_proxy(port)
    socket = connect(session)
    :ok = :gen_tcp.send(socket, "ready")
    assert_receive :ready, 1_000
    [conn] = Map.keys(:sys.get_state(session).connections)
    :erlang.trace(conn, true, [:send])
    :sys.suspend(session)

    try do
      send(server, :first)
      assert_receive {:trace, ^conn, :send, {:gun_ws, ^conn, _, {:binary, "a"}}, ^session}, 1_000
      send(server, :remaining)
      assert_receive :sent, 1_000
      :gun.info(conn)
      {:messages, messages} = Process.info(session, :messages)
      assert Enum.count(messages, &match?({:gun_ws, _, _, {:binary, _}}, &1)) == 1
    after
      :erlang.trace(conn, false, [:send])
      :sys.resume(session)
    end

    assert {:ok, payload} = :gen_tcp.recv(socket, 101, 1_000)
    assert payload == "a" <> String.duplicate("b", 100)
    monitor = Process.monitor(conn)
    Session.stop(session)
    assert_receive {:DOWN, ^monitor, :process, ^conn, _reason}
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    assert_receive {:DOWN, _, :process, ^server, :normal}
  end

  for failure <- [:upgrade, :init, :timeout] do
    @tag failure: failure
    test "#{failure} failure closes both sockets without logging remote secrets", %{
      failure: failure
    } do
      remote_secret = "remote-body-secret"

      {port, server} =
        server(fn socket, owner ->
          if failure == :init do
            upgrade(socket)
            frame(socket)
          else
            assert {:ok, _headers} = :gen_tcp.recv(socket, 0, 1000)
          end

          send(owner, :pending)

          receive do
            :reject -> :ok
          end

          case failure do
            :upgrade ->
              :gen_tcp.send(
                socket,
                "HTTP/1.1 403 Forbidden\r\ncontent-length: 18\r\n\r\n" <> remote_secret
              )

            :init ->
              send_frame(socket, {:text, remote_secret})

            :timeout ->
              :ok
          end

          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
        end)

      session = start_proxy(port)
      socket = connect(session)
      assert_receive :pending, 1000
      [conn] = Map.keys(:sys.get_state(session).connections)
      monitor = Process.monitor(conn)

      log =
        capture_log(fn ->
          send(server, :reject)

          if failure == :timeout do
            send(session, {:connect_timeout, conn})
          end

          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
          assert_receive {:DOWN, ^monitor, :process, ^conn, _reason}
          assert_receive {:DOWN, _, :process, ^server, :normal}
        end)

      refute log =~ remote_secret
      refute log =~ @token
      assert {:ok, {127, 0, 0, 1}, _port} = Session.local_addr(session)
    end
  end

  test "normal parent exit closes the session and listener" do
    test = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           client = Sprites.new(@token, base_url: "http://127.0.0.1:1")
           {:ok, session} = Sprites.proxy_port(Sprites.sprite(client, "test"), 0, 8642)
           send(test, {:session, session})

           receive do
             :stop -> :ok
           end
         end}
      )

    assert_receive {:session, session}
    {:ok, address, port} = Session.local_addr(session)
    monitor = Process.monitor(session)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    assert {:error, :econnrefused} = :gen_tcp.connect(address, port, [:binary, active: false])
  end

  defp start_proxy(port) do
    client = Sprites.new(@token, base_url: "http://127.0.0.1:#{port}")
    mapping = %Sprites.Proxy.PortMapping{local_port: 0, remote_port: 8642}

    start_supervised!(%{
      id: Session,
      restart: :temporary,
      start: {Session, :start_link, [client, "test", mapping]}
    })
  end

  defp connect(session) do
    {:ok, {127, 0, 0, 1}, port} = Session.local_addr(session)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  defp server(operation) do
    test = self()

    pid =
      start_supervised!(%{
        id: :server,
        restart: :temporary,
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
               {:ok, {_, port}} = :inet.sockname(listener)
               send(test, {:server_port, port})
               {:ok, socket} = :gen_tcp.accept(listener)
               operation.(socket, test)
             end
           ]}
      })

    Process.monitor(pid)
    assert_receive {:server_port, port}
    {port, pid}
  end

  defp upgrade(socket) do
    {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n"
      )

    {request, socket}
  end

  defp send_frame(socket, frame), do: :gen_tcp.send(socket, :cow_ws.frame(frame, %{}))

  defp frame(socket, buffer \\ <<>>) do
    case :cow_ws.parse_header(buffer, %{}, :undefined) do
      :more ->
        {:ok, byte} = :gen_tcp.recv(socket, 1, 1_000)
        frame(socket, buffer <> byte)

      {type, frag, rsv, len, mask, rest} ->
        {:ok, payload} = :gen_tcp.recv(socket, len - byte_size(rest), 1_000)

        {:ok, decoded, _utf8, <<>>} =
          :cow_ws.parse_payload(rest <> payload, mask, 0, 0, type, len, frag, %{}, rsv)

        {type, decoded}
    end
  end
end
