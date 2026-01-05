defmodule Sprites.Proxy do
  @moduledoc """
  Port forwarding and proxying for sprites.

  Allows forwarding local ports to remote ports on the sprite.
  """

  alias Sprites.{Client, Sprite}

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
    @moduledoc """
    Active proxy session managed by a GenServer.
    """
    use GenServer

    defstruct [:local_port, :remote_port, :remote_host, :listener, :client, :sprite_name]

    @type t :: %__MODULE__{
            local_port: non_neg_integer(),
            remote_port: non_neg_integer(),
            remote_host: String.t(),
            listener: :gen_tcp.socket() | nil,
            client: Client.t(),
            sprite_name: String.t()
          }

    @doc """
    Starts a proxy session.
    """
    @spec start_link(Client.t(), String.t(), PortMapping.t()) :: GenServer.on_start()
    def start_link(client, sprite_name, mapping) do
      GenServer.start_link(__MODULE__, {client, sprite_name, mapping})
    end

    @doc """
    Stops a proxy session.
    """
    @spec stop(pid()) :: :ok
    def stop(pid) do
      GenServer.stop(pid, :normal)
    end

    @doc """
    Gets the local address the proxy is listening on.
    """
    @spec local_addr(pid()) ::
            {:ok, :inet.socket_address(), :inet.port_number()} | {:error, term()}
    def local_addr(pid) do
      GenServer.call(pid, :local_addr)
    end

    # GenServer callbacks

    @impl true
    def init({client, sprite_name, %PortMapping{} = mapping}) do
      # Start listening on local port
      case :gen_tcp.listen(mapping.local_port, [
             :binary,
             {:packet, :raw},
             {:active, false},
             {:reuseaddr, true},
             {:ip, {127, 0, 0, 1}}
           ]) do
        {:ok, listener} ->
          state = %__MODULE__{
            local_port: mapping.local_port,
            remote_port: mapping.remote_port,
            remote_host: mapping.remote_host || "localhost",
            listener: listener,
            client: client,
            sprite_name: sprite_name
          }

          # Start acceptor process
          spawn_link(fn -> accept_loop(self(), listener) end)

          {:ok, state}

        {:error, reason} ->
          {:stop, {:listen_failed, reason}}
      end
    end

    @impl true
    def handle_call(:local_addr, _from, %{listener: listener} = state) do
      case :inet.sockname(listener) do
        {:ok, {addr, port}} -> {:reply, {:ok, addr, port}, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_cast({:new_connection, socket}, state) do
      # Handle new connection in a separate process
      spawn(fn -> handle_connection(socket, state) end)
      {:noreply, state}
    end

    @impl true
    def terminate(_reason, %{listener: listener}) do
      if listener do
        :gen_tcp.close(listener)
      end

      :ok
    end

    # Private functions

    defp accept_loop(server, listener) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          GenServer.cast(server, {:new_connection, socket})
          accept_loop(server, listener)

        {:error, :closed} ->
          :ok

        {:error, _reason} ->
          accept_loop(server, listener)
      end
    end

    defp handle_connection(local_socket, state) do
      # Build WebSocket URL
      ws_url = build_proxy_url(state)

      # Connect via gun
      {:ok, {scheme, host, port, path}} = parse_ws_url(ws_url)

      opts =
        if scheme == :wss do
          %{
            protocols: [:http],
            transport: :tls,
            tls_opts: [verify: :verify_none]
          }
        else
          %{protocols: [:http]}
        end

      case :gun.open(host, port, opts) do
        {:ok, conn} ->
          case :gun.await_up(conn, 10_000) do
            {:ok, _protocol} ->
              headers = [
                {"authorization", "Bearer #{state.client.token}"},
                {"user-agent", "sprites-elixir-sdk/1.0"}
              ]

              stream_ref = :gun.ws_upgrade(conn, path, headers, %{})

              receive do
                {:gun_upgrade, ^conn, ^stream_ref, ["websocket"], _headers} ->
                  # Send init message
                  init_msg =
                    Jason.encode!(%{
                      host: state.remote_host,
                      port: state.remote_port
                    })

                  :gun.ws_send(conn, stream_ref, {:text, init_msg})

                  # Wait for response
                  receive do
                    {:gun_ws, ^conn, ^stream_ref, {:text, response}} ->
                      case Jason.decode(response) do
                        {:ok, %{"status" => "connected"}} ->
                          # Start bidirectional proxy
                          proxy_loop(local_socket, conn, stream_ref)

                        {:ok, %{"status" => status}} ->
                          :gen_tcp.close(local_socket)
                          :gun.close(conn)
                          {:error, {:proxy_failed, status}}

                        {:error, _} ->
                          :gen_tcp.close(local_socket)
                          :gun.close(conn)
                          {:error, :invalid_response}
                      end

                    {:gun_ws, ^conn, ^stream_ref, {:close, _, _}} ->
                      :gen_tcp.close(local_socket)
                      :gun.close(conn)
                      {:error, :connection_closed}
                  after
                    10_000 ->
                      :gen_tcp.close(local_socket)
                      :gun.close(conn)
                      {:error, :timeout}
                  end

                {:gun_response, ^conn, ^stream_ref, :nofin, status, _headers} ->
                  :gen_tcp.close(local_socket)
                  :gun.close(conn)
                  {:error, {:upgrade_failed, status}}

                {:gun_error, ^conn, ^stream_ref, reason} ->
                  :gen_tcp.close(local_socket)
                  :gun.close(conn)
                  {:error, reason}
              after
                10_000 ->
                  :gen_tcp.close(local_socket)
                  :gun.close(conn)
                  {:error, :upgrade_timeout}
              end

            {:error, reason} ->
              :gen_tcp.close(local_socket)
              :gun.close(conn)
              {:error, reason}
          end

        {:error, reason} ->
          :gen_tcp.close(local_socket)
          {:error, reason}
      end
    end

    defp proxy_loop(local_socket, ws_conn, stream_ref) do
      # Set local socket to active mode
      :inet.setopts(local_socket, [{:active, true}])

      do_proxy_loop(local_socket, ws_conn, stream_ref)
    end

    defp do_proxy_loop(local_socket, ws_conn, stream_ref) do
      receive do
        # Data from local socket -> send to WebSocket
        {:tcp, ^local_socket, data} ->
          :gun.ws_send(ws_conn, stream_ref, {:binary, data})
          do_proxy_loop(local_socket, ws_conn, stream_ref)

        # Local socket closed
        {:tcp_closed, ^local_socket} ->
          :gun.close(ws_conn)
          :ok

        {:tcp_error, ^local_socket, _reason} ->
          :gun.close(ws_conn)
          :ok

        # Data from WebSocket -> send to local socket
        {:gun_ws, ^ws_conn, ^stream_ref, {:binary, data}} ->
          :gen_tcp.send(local_socket, data)
          do_proxy_loop(local_socket, ws_conn, stream_ref)

        # WebSocket closed
        {:gun_ws, ^ws_conn, ^stream_ref, {:close, _, _}} ->
          :gen_tcp.close(local_socket)
          :gun.close(ws_conn)
          :ok

        {:gun_down, ^ws_conn, _, _, _} ->
          :gen_tcp.close(local_socket)
          :ok

        {:gun_error, ^ws_conn, _, _reason} ->
          :gen_tcp.close(local_socket)
          :gun.close(ws_conn)
          :ok
      end
    end

    defp build_proxy_url(state) do
      base_url =
        state.client.base_url
        |> String.replace(~r/^http/, "ws")

      "#{base_url}/v1/sprites/#{URI.encode(state.sprite_name)}/proxy"
    end

    defp parse_ws_url(url) do
      uri = URI.parse(url)

      scheme = if uri.scheme == "wss", do: :wss, else: :ws
      host = String.to_charlist(uri.host)
      port = uri.port || if(scheme == :wss, do: 443, else: 80)
      path = String.to_charlist(uri.path || "/")

      {:ok, {scheme, host, port, path}}
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
