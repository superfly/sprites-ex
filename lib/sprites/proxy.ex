defmodule Sprites.Proxy do
  @moduledoc """
  Port forwarding and proxying for sprites.

  Allows forwarding local ports to remote ports on the sprite.
  """

  alias Sprites.{Client, ClientSignals, Sprite, WebSocket}

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

          spawn_link(fn -> accept_loop(listener, state) end)

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
    def terminate(_reason, %{listener: listener}) do
      if listener do
        :gen_tcp.close(listener)
      end

      :ok
    end

    # Private functions

    defp accept_loop(listener, state) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          pid =
            spawn(fn ->
              receive do
                {:socket, ^socket} -> handle_connection(socket, state)
              end
            end)

          case :gen_tcp.controlling_process(socket, pid) do
            :ok ->
              send(pid, {:socket, socket})

            {:error, _} ->
              Process.exit(pid, :kill)
              :gen_tcp.close(socket)
          end

          accept_loop(listener, state)

        {:error, :closed} ->
          :ok

        {:error, _reason} ->
          accept_loop(listener, state)
      end
    end

    defp handle_connection(local_socket, state) do
      headers = ClientSignals.auth_headers(state.client.token)
      init_msg = Jason.encode!(%{host: state.remote_host, port: state.remote_port})

      with {:ok, ws, frames} <- WebSocket.connect(build_proxy_url(state), headers),
           {:ok, ws, frames} <- send_init(ws, init_msg, frames),
           {:ok, ws, frames} <- await_connected(ws, frames, deadline(10_000)) do
        :ok = :inet.setopts(local_socket, active: true)
        relay(frames, local_socket, ws)
      else
        {:error, %WebSocket{} = ws, reason} ->
          WebSocket.close(ws)
          :gen_tcp.close(local_socket)
          {:error, reason}

        {:error, reason} ->
          :gen_tcp.close(local_socket)
          {:error, reason}
      end
    end

    defp send_init(ws, init_msg, frames) do
      case WebSocket.send_frame(ws, {:text, init_msg}) do
        {:ok, ws} -> {:ok, ws, frames}
        {:error, ws, reason} -> {:error, ws, reason}
      end
    end

    defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

    # The local socket stays passive until the remote end confirms the
    # connection, so every message here belongs to the WebSocket.
    defp await_connected(ws, [{:text, json} | rest], _deadline) do
      case Jason.decode(json) do
        {:ok, %{"status" => "connected"}} -> {:ok, ws, rest}
        {:ok, %{"status" => status}} -> {:error, ws, {:proxy_failed, status}}
        _ -> {:error, ws, :invalid_response}
      end
    end

    defp await_connected(ws, [{:close, _, _} | _], _deadline),
      do: {:error, ws, :connection_closed}

    defp await_connected(ws, [_frame | rest], deadline), do: await_connected(ws, rest, deadline)

    defp await_connected(ws, [], deadline) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        message ->
          case WebSocket.stream(ws, message) do
            {:ok, ws, frames} -> await_connected(ws, frames, deadline)
            {:error, ws, reason, _frames} -> {:error, ws, reason}
            :unknown -> await_connected(ws, [], deadline)
          end
      after
        remaining -> {:error, ws, :timeout}
      end
    end

    defp proxy_loop(local_socket, ws) do
      receive do
        {:tcp, ^local_socket, data} ->
          case WebSocket.send_frame(ws, {:binary, data}) do
            {:ok, ws} ->
              proxy_loop(local_socket, ws)

            {:error, ws, _reason} ->
              WebSocket.close(ws)
              :gen_tcp.close(local_socket)
          end

        {:tcp_closed, ^local_socket} ->
          WebSocket.close(ws)

        {:tcp_error, ^local_socket, _reason} ->
          WebSocket.close(ws)
          :gen_tcp.close(local_socket)

        message ->
          case WebSocket.stream(ws, message) do
            {:ok, ws, frames} ->
              relay(frames, local_socket, ws)

            {:error, ws, _reason, frames} ->
              forward(frames, local_socket)
              WebSocket.close(ws)
              :gen_tcp.close(local_socket)

            :unknown ->
              proxy_loop(local_socket, ws)
          end
      end
    end

    # Writes WebSocket frames to the local socket, then keeps proxying unless
    # either side closed.
    defp relay(frames, local_socket, ws) do
      case forward(frames, local_socket) do
        :ok ->
          proxy_loop(local_socket, ws)

        :closed ->
          WebSocket.close(ws)
          :gen_tcp.close(local_socket)
      end
    end

    defp forward([], _local_socket), do: :ok
    defp forward([{:close, _, _} | _], _local_socket), do: :closed

    defp forward([{:binary, data} | rest], local_socket) do
      case :gen_tcp.send(local_socket, data) do
        :ok -> forward(rest, local_socket)
        {:error, _} -> :closed
      end
    end

    defp forward([_frame | rest], local_socket), do: forward(rest, local_socket)

    defp build_proxy_url(state) do
      base_url =
        state.client.base_url
        |> String.replace(~r/^http/, "ws")

      "#{base_url}/v1/sprites/#{Sprites.Path.encode_segment(state.sprite_name)}/proxy"
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
