defmodule Sprites.WebSocketIntegrationTest do
  use ExUnit.Case, async: true

  alias Sprites.{Protocol, WebSocket}

  defmodule FakeSprites do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{path_info: ["v1", "sprites", "limited", "exec"]} = conn, _opts) do
      conn
      |> put_resp_header("retry-after", "7")
      |> send_resp(429, Jason.encode!(%{error: "rate_limited", message: "slow down"}))
    end

    def call(%{path_info: ["v1", "sprites", _name, endpoint]} = conn, _opts)
        when endpoint in ["exec", "control", "proxy"] do
      params = URI.query_decoder(conn.query_string) |> Enum.to_list()
      handler = Module.concat(__MODULE__, Macro.camelize(endpoint))

      conn
      |> WebSockAdapter.upgrade(handler, params, timeout: 5_000)
      |> halt()
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defmodule Exec do
      @moduledoc false
      @behaviour WebSock

      @impl true
      def init(params) do
        case for({"cmd", arg} <- params, do: arg) do
          ["echo" | args] ->
            out = <<Protocol.stdout_id(), Enum.join(args, " ")::binary, "\n">>
            {:push, [{:binary, out}, {:binary, <<Protocol.exit_id(), 0>>}], :done}

          ["cat"] ->
            {:ok, :cat}

          ["close"] ->
            {:stop, :normal, 1000, :done}
        end
      end

      @impl true
      def handle_in({<<0, data::binary>>, opcode: :binary}, :cat) do
        {:push, {:binary, <<Protocol.stdout_id(), data::binary>>}, :cat}
      end

      def handle_in({<<4>>, opcode: :binary}, :cat) do
        {:push, {:binary, <<Protocol.exit_id(), 3>>}, :cat}
      end

      def handle_in(_frame, state), do: {:ok, state}

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end

    defmodule Control do
      @moduledoc false
      @behaviour WebSock

      @impl true
      def init(_params), do: {:ok, nil}

      @impl true
      def handle_in({"control:" <> json, opcode: :text}, state) do
        %{"type" => "op.start", "args" => %{"cmd" => [_cmd | args]}} = Jason.decode!(json)
        out = <<Protocol.stdout_id(), Enum.join(args, " ")::binary>>
        done = "control:" <> Jason.encode!(%{type: "op.complete", args: %{exitCode: 5}})
        {:push, [{:binary, out}, {:text, done}], state}
      end

      def handle_in(_frame, state), do: {:ok, state}

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end

    defmodule Proxy do
      @moduledoc false
      @behaviour WebSock

      @impl true
      def init(_params), do: {:ok, :init}

      @impl true
      def handle_in({json, opcode: :text}, :init) do
        %{"host" => "localhost", "port" => 4000} = Jason.decode!(json)
        {:push, {:text, ~s({"status":"connected"})}, :connected}
      end

      def handle_in({data, opcode: :binary}, :connected) do
        {:push, {:binary, String.upcase(data)}, :connected}
      end

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end
  end

  setup_all do
    server =
      start_supervised!({Bandit, plug: FakeSprites, ip: :loopback, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{base_url: "http://127.0.0.1:#{port}"}
  end

  defp sprite(base_url, name, opts \\ []) do
    base_url |> then(&Sprites.new("token", [base_url: &1] ++ opts)) |> Sprites.sprite(name)
  end

  test "runs a command and collects its output", %{base_url: url} do
    assert {"hello world\n", 0} = Sprites.cmd(sprite(url, "s"), "echo", ["hello", "world"])
  end

  test "streams stdin and stdin EOF", %{base_url: url} do
    {:ok, cmd} = Sprites.spawn(sprite(url, "s"), "cat", [], stdin: true)
    ref = cmd.ref

    :ok = Sprites.write(cmd, "ping")
    assert_receive {:stdout, %{ref: ^ref}, "ping"}

    Sprites.close_stdin(cmd)
    assert {:ok, 3} = Sprites.await(cmd, 1_000)
  end

  test "reports a close before exit as an error", %{base_url: url} do
    {:ok, cmd} = Sprites.spawn(sprite(url, "s"), "close")
    assert {:error, :closed_before_exit} = Sprites.await(cmd, 1_000)
  end

  test "returns a structured API error when the upgrade is rejected", %{base_url: url} do
    assert {:error, %Sprites.Error.APIError{status: 429, retry_after_header: 7}} =
             Sprites.spawn(sprite(url, "limited"), "echo")
  end

  test "runs a command over a control connection", %{base_url: url} do
    sprite = sprite(url, "control-#{System.unique_integer([:positive])}", control_mode: true)
    assert {"via control", 5} = Sprites.cmd(sprite, "echo", ["via", "control"])
    Sprites.Control.close(sprite)
  end

  test "proxies a local TCP connection over the WebSocket", %{base_url: url} do
    {:ok, session} = Sprites.proxy_port(sprite(url, "s"), 0, 4000)
    {:ok, _addr, port} = Sprites.Proxy.Session.local_addr(session)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "hello")
    assert {:ok, "HELLO"} = :gen_tcp.recv(socket, 0, 1_000)

    :gen_tcp.close(socket)
    Sprites.Proxy.Session.stop(session)
  end

  test "keeps frames that arrive in the same packet as the upgrade response" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
        [_, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, request)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        response =
          "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
            "sec-websocket-accept: #{accept}\r\n\r\n"

        # Unmasked server text frame, written together with the 101 response.
        :ok = :gen_tcp.send(socket, [response, <<0x81, 5>>, "early"])
        socket
      end)

    assert {:ok, ws, [{:text, "early"}]} = WebSocket.connect("ws://127.0.0.1:#{port}/", [])
    WebSocket.close(ws)
    :gen_tcp.close(Task.await(server))
  end
end
