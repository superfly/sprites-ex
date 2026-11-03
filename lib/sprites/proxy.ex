defmodule Sprites.Proxy do
  @moduledoc """
  Port forwarding and proxying for sprites.

  Allows forwarding local ports to remote ports on the sprite.
  """

  alias Sprites.{Client, ClientSignals, Sprite}

  defmodule PortMapping do
    @moduledoc """
    Port mapping configuration.

    ## Fields

      * `:local_port` - Local port to listen on
      * `:remote_port` - Remote port on the sprite
      * `:remote_host` - Remote host (default: "localhost")
    """
    @type t :: %__MODULE__{
            local_port: non_neg_integer(),
            remote_port: non_neg_integer(),
            remote_host: String.t()
          }

    defstruct [:local_port, :remote_port, remote_host: "localhost"]
  end

  defmodule Session do
    @moduledoc "An owned, local TCP listener for Sprite proxy connections."
    use GenServer
    @connect_timeout 10_000
    @derive {Inspect, except: [:client]}
    defstruct [
      :local_port,
      :remote_port,
      :remote_host,
      :listener,
      :client,
      :sprite_name,
      :acceptor,
      connections: %{},
      sockets: %{}
    ]

    @type t :: %__MODULE__{}
    @spec start_link(Client.t(), String.t(), PortMapping.t()) :: GenServer.on_start()
    def start_link(client, sprite_name, mapping) do
      GenServer.start_link(__MODULE__, {client, sprite_name, mapping})
    end

    @spec stop(pid()) :: :ok
    def stop(pid) do
      GenServer.stop(pid, :normal)
    end

    @spec local_addr(pid()) ::
            {:ok, :inet.socket_address(), :inet.port_number()} | {:error, term()}
    def local_addr(pid) do
      GenServer.call(pid, :local_addr)
    end

    def init({client, sprite_name, %PortMapping{} = mapping}) do
      Process.flag(:trap_exit, true)

      case :gen_tcp.listen(mapping.local_port, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             ip: {127, 0, 0, 1},
             send_timeout: 5_000,
             send_timeout_close: true
           ]) do
        {:ok, listener} ->
          server = self()
          acceptor = spawn_link(fn -> accept_loop(server, listener) end)

          {:ok,
           %__MODULE__{
             local_port: mapping.local_port,
             remote_port: mapping.remote_port,
             remote_host: mapping.remote_host || "localhost",
             listener: listener,
             client: client,
             sprite_name: sprite_name,
             acceptor: acceptor
           }}

        {:error, reason} ->
          {:stop, {:listen_failed, reason}}
      end
    end

    def handle_call(:local_addr, _from, state) do
      reply =
        case :inet.sockname(state.listener) do
          {:ok, {addr, port}} -> {:ok, addr, port}
          {:error, reason} -> {:error, reason}
        end

      {:reply, reply, state}
    end

    def handle_cast({:new_connection, socket}, state) do
      case open_connection(state) do
        {:ok, conn} ->
          connection = %{
            socket: socket,
            stream: nil,
            phase: :connecting,
            monitor: Process.monitor(conn),
            timer: Process.send_after(self(), {:connect_timeout, conn}, @connect_timeout)
          }

          state = %{
            state
            | connections: Map.put(state.connections, conn, connection),
              sockets: Map.put(state.sockets, socket, conn)
          }

          {:noreply, state}

        {:error, _reason} ->
          :gen_tcp.close(socket)
          {:noreply, state}
      end
    end

    def handle_info({:gun_up, conn, _protocol}, state) do
      case Map.fetch(state.connections, conn) do
        {:ok, %{phase: :connecting} = connection} ->
          path = "/v1/sprites/#{URI.encode(state.sprite_name, &URI.char_unreserved?/1)}/proxy"

          stream =
            :gun.ws_upgrade(conn, path, ClientSignals.auth_headers(state.client.token), %{flow: 1})

          {:noreply, put_connection(state, conn, %{connection | stream: stream, phase: :upgrade})}

        _other ->
          {:noreply, state}
      end
    end

    def handle_info({:gun_upgrade, conn, stream, ["websocket"], _headers}, state) do
      case Map.fetch(state.connections, conn) do
        {:ok, %{stream: ^stream, phase: :upgrade} = connection} ->
          :gun.ws_send(
            conn,
            stream,
            {:text, Jason.encode!(%{host: state.remote_host, port: state.remote_port})}
          )

          {:noreply, put_connection(state, conn, %{connection | phase: :initializing})}

        _other ->
          {:noreply, close_connection(state, conn)}
      end
    end

    def handle_info({:gun_ws, conn, stream, {:text, response}}, state) do
      case Map.fetch(state.connections, conn) do
        {:ok, %{stream: ^stream, phase: :initializing} = connection} ->
          case Jason.decode(response) do
            {:ok, %{"status" => "connected"}} ->
              Process.cancel_timer(connection.timer)

              case :inet.setopts(connection.socket, active: :once) do
                :ok ->
                  :gun.update_flow(conn, stream, 1)

                  {:noreply,
                   put_connection(state, conn, %{connection | phase: :ready, timer: nil})}

                {:error, _reason} ->
                  {:noreply, close_connection(state, conn)}
              end

            _other ->
              {:noreply, close_connection(state, conn)}
          end

        _other ->
          {:noreply, close_connection(state, conn)}
      end
    end

    def handle_info({:gun_ws, conn, stream, {:binary, data}}, state) do
      case Map.fetch(state.connections, conn) do
        {:ok, %{stream: ^stream, phase: :ready} = connection} ->
          case :gen_tcp.send(connection.socket, data) do
            :ok ->
              :gun.update_flow(conn, stream, 1)
              {:noreply, state}

            {:error, _reason} ->
              {:noreply, close_connection(state, conn)}
          end

        _other ->
          {:noreply, close_connection(state, conn)}
      end
    end

    def handle_info({:tcp, socket, data}, state) do
      with {:ok, conn} <- Map.fetch(state.sockets, socket),
           %{stream: stream, phase: :ready} <- Map.fetch!(state.connections, conn),
           :ok <- send_frame(conn, stream, data),
           :ok <- :inet.setopts(socket, active: :once) do
        {:noreply, state}
      else
        _other -> {:noreply, close_socket(state, socket)}
      end
    end

    def handle_info({:tcp_closed, socket}, state) do
      {:noreply, close_socket(state, socket)}
    end

    def handle_info({:tcp_error, socket, _reason}, state) do
      {:noreply, close_socket(state, socket)}
    end

    def handle_info({:gun_ws, conn, _stream, _frame}, state) do
      {:noreply, close_connection(state, conn)}
    end

    def handle_info({:gun_response, conn, _stream, _fin, _status, _headers}, state) do
      {:noreply, close_connection(state, conn)}
    end

    def handle_info({:gun_error, conn, _stream, _reason}, state) do
      {:noreply, close_connection(state, conn)}
    end

    def handle_info({:gun_error, conn, _reason}, state) do
      {:noreply, close_connection(state, conn)}
    end

    def handle_info({:gun_down, conn, _protocol, _reason, _streams}, state) do
      {:noreply, close_connection(state, conn)}
    end

    def handle_info({:DOWN, _ref, :process, conn, _reason}, state) do
      {:noreply, close_connection(state, conn)}
    end

    def handle_info({:connect_timeout, conn}, state) do
      case Map.fetch(state.connections, conn) do
        {:ok, %{phase: :ready}} -> {:noreply, state}
        _other -> {:noreply, close_connection(state, conn)}
      end
    end

    def handle_info({:EXIT, acceptor, _reason}, %{acceptor: acceptor} = state) do
      {:stop, :acceptor_closed, state}
    end

    def handle_info(_message, state) do
      {:noreply, state}
    end

    def terminate(_reason, state) do
      :gen_tcp.close(state.listener)
      Enum.each(Map.keys(state.connections), &close_connection(state, &1))
      :ok
    end

    def format_status(status) do
      # OTP 25+ uses this callback, including Elixir 1.15 applications.
      Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
    end

    defp accept_loop(server, listener) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          case :gen_tcp.controlling_process(socket, server) do
            :ok -> GenServer.cast(server, {:new_connection, socket})
            {:error, _reason} -> :gen_tcp.close(socket)
          end

          accept_loop(server, listener)

        {:error, _reason} ->
          :ok
      end
    end

    defp open_connection(state) do
      uri = URI.parse(state.client.base_url)

      scheme =
        if uri.scheme == "https" do
          "wss"
        else
          "ws"
        end

      opts = Sprites.Transport.gun_opts(scheme) |> Map.put(:retry, 0)
      :gun.open(String.to_charlist(uri.host), uri.port, opts)
    rescue
      _error -> {:error, :connection_failed}
    catch
      :exit, _reason -> {:error, :connection_failed}
    end

    defp send_frame(conn, stream, data) do
      :gun.ws_send(conn, stream, {:binary, data})
      # Wait until Gun handles the send before accepting another TCP message.
      :gun.info(conn)
      :ok
    catch
      :exit, _reason -> {:error, :connection_closed}
    end

    defp put_connection(state, conn, connection) do
      %{state | connections: Map.put(state.connections, conn, connection)}
    end

    defp close_socket(state, socket) do
      case Map.fetch(state.sockets, socket) do
        {:ok, conn} -> close_connection(state, conn)
        :error -> state
      end
    end

    defp close_connection(state, conn) do
      case Map.pop(state.connections, conn) do
        {nil, _connections} ->
          state

        {connection, connections} ->
          if connection.timer do
            Process.cancel_timer(connection.timer)
          end

          Process.demonitor(connection.monitor, [:flush])
          :gen_tcp.close(connection.socket)
          :gun.close(conn)

          %{
            state
            | connections: connections,
              sockets: Map.delete(state.sockets, connection.socket)
          }
      end
    end
  end

  @doc """
  Creates a proxy session for a single port.

  ## Examples

      {:ok, session} = Sprites.Proxy.proxy_port(sprite, 3000, 3000)
  """
  @spec proxy_port(Sprite.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, pid()} | {:error, term()}
  def proxy_port(%Sprite{client: client, name: name}, local_port, remote_port) do
    mapping = %PortMapping{local_port: local_port, remote_port: remote_port}
    Session.start_link(client, name, mapping)
  end

  @doc """
  Creates proxy sessions for multiple port mappings.

  ## Examples

      mappings = [
        %Sprites.Proxy.PortMapping{local_port: 3000, remote_port: 3000},
        %Sprites.Proxy.PortMapping{local_port: 8080, remote_port: 80}
      ]
      {:ok, sessions} = Sprites.Proxy.proxy_ports(sprite, mappings)
  """
  @spec proxy_ports(Sprite.t(), [PortMapping.t()]) :: {:ok, [pid()]} | {:error, term()}
  def proxy_ports(%Sprite{client: client, name: name}, mappings) do
    results =
      Enum.map(mappings, fn mapping ->
        Session.start_link(client, name, mapping)
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      nil ->
        sessions = Enum.map(results, fn {:ok, pid} -> pid end)
        {:ok, sessions}

      {:error, reason} ->
        # Clean up any successful sessions
        Enum.each(results, fn
          {:ok, pid} -> Session.stop(pid)
          _ -> :ok
        end)

        {:error, reason}
    end
  end
end
