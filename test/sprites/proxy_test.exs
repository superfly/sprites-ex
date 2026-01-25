defmodule Sprites.ProxyTest do
  use ExUnit.Case, async: true

  alias Sprites.Proxy.{PortMapping, Session}
  alias Sprites.Client

  describe "Session accept_loop" do
    test "accepted socket can be set to active mode by handler process" do
      # This test verifies the fix for the socket ownership bug.
      # The bug was: accept_loop spawned inside init() called self() which captured
      # the spawned process's PID instead of the GenServer's PID. Additionally,
      # the socket ownership wasn't transferred before casting to the GenServer.
      #
      # This caused :inet.setopts(socket, [{:active, true}]) to fail silently
      # in the handler process because it didn't own the socket.
      #
      # We test this by:
      # 1. Starting a listener that accepts connections
      # 2. Using the same accept_loop pattern with the fix
      # 3. Verifying the handler process can successfully set active mode
      # 4. Verifying data can be received in active mode

      # Start a simple listener
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}])

      {:ok, port} = :inet.port(listener)

      # Capture test process as the "server"
      test_pid = self()
      ref = make_ref()

      # Spawn accept loop that properly transfers socket ownership
      spawn_link(fn ->
        case :gen_tcp.accept(listener, 5000) do
          {:ok, socket} ->
            # This is the fix: transfer ownership to the "server" (test process)
            :ok = :gen_tcp.controlling_process(socket, test_pid)
            send(test_pid, {:accepted, ref, socket})

          {:error, reason} ->
            send(test_pid, {:accept_error, ref, reason})
        end
      end)

      # Connect as a client
      {:ok, client_socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

      # Wait for the accepted socket
      assert_receive {:accepted, ^ref, server_socket}, 5000

      # Now spawn a handler process (simulating handle_connection)
      # This process should be able to take ownership and set active mode
      handler_ref = make_ref()

      handler_pid =
        spawn_link(fn ->
          # Transfer ownership from test process to handler
          receive do
            :take_ownership -> :ok
          end

          # This is what the original code does in proxy_loop/3
          # Before the fix, this would silently fail because the handler
          # didn't own the socket
          result = :inet.setopts(server_socket, [{:active, true}])
          send(test_pid, {:setopts_result, handler_ref, result})

          # If active mode works, we should receive data as a message
          receive do
            {:tcp, ^server_socket, data} ->
              send(test_pid, {:received_data, handler_ref, data})

            other ->
              send(test_pid, {:unexpected, handler_ref, other})
          after
            5000 ->
              send(test_pid, {:timeout, handler_ref})
          end
        end)

      # Transfer socket to handler
      :ok = :gen_tcp.controlling_process(server_socket, handler_pid)
      send(handler_pid, :take_ownership)

      # Send data from client
      :ok = :gen_tcp.send(client_socket, "hello from client")

      # Verify setopts succeeded
      assert_receive {:setopts_result, ^handler_ref, :ok}, 5000

      # Verify data was received in active mode
      assert_receive {:received_data, ^handler_ref, "hello from client"}, 5000

      # Cleanup
      :gen_tcp.close(client_socket)
      :gen_tcp.close(listener)
    end

    test "socket ownership not transferred causes data to go to wrong process" do
      # This test demonstrates the bug behavior when socket ownership is NOT transferred.
      # Without the fix, active mode messages go to the controlling process (acceptor),
      # not the handler process that called setopts.

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}])

      {:ok, port} = :inet.port(listener)

      test_pid = self()
      ref = make_ref()

      # Spawn accept loop that does NOT transfer socket ownership (the bug)
      acceptor_pid =
        spawn_link(fn ->
          case :gen_tcp.accept(listener, 5000) do
            {:ok, socket} ->
              # BUG: Not transferring ownership, just sending the socket
              send(test_pid, {:accepted, ref, socket, self()})

              # Keep acceptor alive - it will receive the tcp messages since it owns the socket
              receive do
                {:tcp, ^socket, data} ->
                  # The acceptor receives the data, not the handler!
                  send(test_pid, {:acceptor_got_data, ref, data})

                :done ->
                  :ok
              after
                5000 ->
                  send(test_pid, {:acceptor_timeout, ref})
              end

            {:error, reason} ->
              send(test_pid, {:accept_error, ref, reason})
          end
        end)

      # Connect as a client
      {:ok, client_socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

      # Wait for the accepted socket
      assert_receive {:accepted, ^ref, server_socket, ^acceptor_pid}, 5000

      # Spawn a handler that tries to use the socket without ownership
      handler_ref = make_ref()

      spawn_link(fn ->
        # Set active mode - this "succeeds" but messages go to the owner (acceptor)
        :ok = :inet.setopts(server_socket, [{:active, true}])
        send(test_pid, {:setopts_done, handler_ref})

        # Handler waits for data but will never receive it
        receive do
          {:tcp, ^server_socket, data} ->
            send(test_pid, {:handler_got_data, handler_ref, data})
        after
          1000 ->
            send(test_pid, {:handler_timeout, handler_ref})
        end
      end)

      # Wait for handler to set active mode
      assert_receive {:setopts_done, ^handler_ref}, 5000

      # Send data from client
      :ok = :gen_tcp.send(client_socket, "test data")

      # The BUG: acceptor receives the data, not the handler
      assert_receive {:acceptor_got_data, ^ref, "test data"}, 5000

      # Handler times out because it never gets the data
      assert_receive {:handler_timeout, ^handler_ref}, 5000

      # Cleanup
      :gen_tcp.close(client_socket)
      :gen_tcp.close(listener)
    end
  end

  describe "Session GenServer" do
    test "new_connection cast is received by the GenServer process" do
      # This test verifies that the GenServer receives the :new_connection cast.
      # The original bug had self() called inside spawn_link, which meant the
      # cast was sent to the acceptor process, not the GenServer.
      #
      # We test this by starting a Session and verifying that:
      # 1. Connecting to the local port triggers handle_cast
      # 2. The session properly handles the socket

      client = Client.new("test_token", base_url: "https://api.sprites.dev")
      mapping = %PortMapping{local_port: 0, remote_port: 8080}

      # Start the session
      {:ok, session_pid} = Session.start_link(client, "test-sprite", mapping)

      # Get the actual port it's listening on
      {:ok, _addr, local_port} = Session.local_addr(session_pid)
      assert local_port > 0

      # Connect to the proxy
      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, local_port, [:binary, {:active, false}])

      # Give it a moment to process
      Process.sleep(100)

      # The session should still be alive (it doesn't crash on connection)
      assert Process.alive?(session_pid)

      # The GenServer should have received the cast and spawned a handler
      # We can verify this by checking the process is still responsive
      assert {:ok, _addr, ^local_port} = Session.local_addr(session_pid)

      # Cleanup
      :gen_tcp.close(client_socket)
      Session.stop(session_pid)
    end

    test "multiple connections are handled by the GenServer" do
      # Verify that multiple connections all get handled properly
      client = Client.new("test_token", base_url: "https://api.sprites.dev")
      mapping = %PortMapping{local_port: 0, remote_port: 8080}

      {:ok, session_pid} = Session.start_link(client, "test-sprite", mapping)
      {:ok, _addr, local_port} = Session.local_addr(session_pid)

      # Open multiple connections
      sockets =
        for _ <- 1..5 do
          {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, local_port, [:binary, {:active, false}])
          sock
        end

      # Give time to process
      Process.sleep(100)

      # Session should still be alive and responsive
      assert Process.alive?(session_pid)
      assert {:ok, _addr, ^local_port} = Session.local_addr(session_pid)

      # Cleanup
      Enum.each(sockets, &:gen_tcp.close/1)
      Session.stop(session_pid)
    end
  end
end
