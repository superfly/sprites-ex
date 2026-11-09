defmodule Sprites.CheckpointTest do
  # These tests temporarily replace the VM's trusted roots.
  use ExUnit.Case, async: false

  alias Sprites.{Checkpoint, Client, StreamMessage}

  setup %{tmp_dir: tmp_dir} do
    original_roots = :public_key.cacerts_get()
    original_path = Path.join(tmp_dir, "original-roots.pem")
    write_roots(original_path, original_roots)
    on_exit(fn -> :ok = :public_key.cacerts_load(String.to_charlist(original_path)) end)

    root =
      :public_key.pkix_test_root_cert(~c"checkpoint test root",
        key: {:rsa, 2048, 65537},
        digest: :sha256
      )

    trusted_path = Path.join(tmp_dir, "test-root.pem")
    write_roots(trusted_path, [root.cert])
    :ok = :public_key.cacerts_load(String.to_charlist(trusted_path))
    %{root: root}
  end

  for operation <- [:create, :restore] do
    @tag :tmp_dir
    test "#{operation} verifies a trusted localhost certificate and preserves the encoded request path",
         %{root: root} do
      server = tls_server(root, ~c"localhost")
      client = Client.new("test-token", base_url: server.url)
      name = "mine/../victim?x=#%"
      id = "c1/../../../victim/checkpoints/c9?x=#%"

      result =
        case unquote(operation) do
          :create -> Checkpoint.create_by_name(client, name)
          :restore -> Checkpoint.restore_by_name(client, name, id)
        end

      assert {:ok, [%StreamMessage{type: "info", data: "done"}]} = result
      assert {:request, path, headers} = Task.await(server.task)
      base = "/v1/sprites/mine%2F..%2Fvictim%3Fx%3D%23%25"

      expected =
        case unquote(operation) do
          :create ->
            base <> "/checkpoint"

          :restore ->
            base <>
              "/checkpoints/c1%2F..%2F..%2F..%2Fvictim%2Fcheckpoints%2Fc9%3Fx%3D%23%25/restore"
        end

      assert path == expected
      assert {"authorization", "Bearer test-token"} in headers
    end

    for failure <- [:untrusted, :wrong_hostname] do
      @tag :tmp_dir
      @tag capture_log: true
      test "#{operation} rejects #{failure} TLS before sending the bearer token", %{root: root} do
        {root, hostname} =
          case unquote(failure) do
            :untrusted ->
              {:public_key.pkix_test_root_cert(~c"untrusted test root",
                 key: {:rsa, 2048, 65537},
                 digest: :sha256
               ), ~c"localhost"}

            :wrong_hostname ->
              {root, ~c"wrong.example.test"}
          end

        server = tls_server(root, hostname)
        client = Client.new("must-not-be-sent", base_url: server.url)

        result =
          case unquote(operation) do
            :create -> Checkpoint.create_by_name(client, "sprite")
            :restore -> Checkpoint.restore_by_name(client, "sprite", "checkpoint")
          end

        assert {:error, {:failed_connect, details}} = result

        expected_error =
          if unquote(failure) == :untrusted, do: "unknown_ca", else: "hostname_check_failed"

        assert inspect(details) =~ expected_error
        assert {:handshake_error, _reason} = Task.await(server.task)
      end
    end
  end

  @tag :tmp_dir
  test "plain HTTP checkpoint requests still work" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        serve_request(:gen_tcp, socket)
      end)

    client = Client.new("test-token", base_url: "http://127.0.0.1:#{port}")
    assert {:ok, [%StreamMessage{data: "done"}]} = Checkpoint.create_by_name(client, "sprite")
    assert {:request, "/v1/sprites/sprite/checkpoint", _} = Task.await(server)
  end

  defp tls_server(root, hostname) do
    config =
      :public_key.pkix_test_data(%{
        root: root,
        peer: [
          key: {:rsa, 2048, 65537},
          digest: :sha256,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, hostname}]}]
        ]
      })

    {:ok, listener} =
      :ssl.listen(
        0,
        config ++ [active: false, mode: :binary, packet: :http_bin, ip: {127, 0, 0, 1}]
      )

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {_, port}} = :ssl.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)

        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} -> serve_request(:ssl, socket)
          {:error, reason} -> {:handshake_error, reason}
        end
      end)

    %{url: "https://localhost:#{port}", task: task}
  end

  defp serve_request(transport, socket) do
    {:ok, {:http_request, :POST, {:abs_path, path}, _version}} = transport.recv(socket, 0, 5_000)
    headers = read_headers(transport, socket, [])
    body = ~s({"type":"info","data":"done"}\n)

    :ok =
      transport.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
          body
      )

    transport.close(socket)
    {:request, path, headers}
  end

  defp read_headers(transport, socket, acc) do
    case transport.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(transport, socket, [{String.downcase(to_string(name)), value} | acc])

      {:ok, :http_eoh} ->
        acc
    end
  end

  defp write_roots(path, roots) do
    entries =
      Enum.map(roots, fn
        {:cert, der, _decoded} -> {:Certificate, der, :not_encrypted}
        der when is_binary(der) -> {:Certificate, der, :not_encrypted}
      end)

    File.write!(path, :public_key.pem_encode(entries))
  end
end
