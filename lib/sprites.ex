defmodule Sprites do
  @moduledoc """
  Elixir SDK for Sprites - remote code container runtime.

  Mirrors Elixir's native process APIs (`System.cmd/3`, `Port` operations).

  ## Quick Start

      # Create a client
      client = Sprites.new(token, base_url: "https://api.sprites.dev")

      # Get a sprite handle
      sprite = Sprites.sprite(client, "my-sprite")

      # System.cmd-like interface (blocking)
      {output, exit_code} = Sprites.cmd(sprite, "echo", ["hello"])

      # Port-like interface (async, message-based)
      {:ok, command} = Sprites.spawn(sprite, "echo", ["hello"])

      receive do
        {:stdout, ^command, data} -> IO.write(data)
        {:exit, ^command, code} -> IO.puts("Exited with: \#{code}")
      end

  ## Creating and Destroying Sprites

      {:ok, sprite} = Sprites.create(client, "new-sprite")
      :ok = Sprites.destroy(sprite)
  """

  alias Sprites.{Client, Sprite, Command}

  @type client :: Client.t()
  @type sprite :: Sprite.t()
  @type command :: Command.t()

  @doc """
  Creates a new Sprites client.

  ## Options

    * `:base_url` - API base URL (default: "https://api.sprites.dev")
    * `:timeout` - HTTP timeout in milliseconds (default: 30_000)
    * `:control_mode` - Enable control mode for multiplexed exec over a single WebSocket per sprite (default: false)

  ## Examples

      client = Sprites.new("my-token")
      client = Sprites.new("my-token", base_url: "https://custom.api.dev")
      client = Sprites.new("my-token", control_mode: true)
  """
  @spec new(String.t(), keyword()) :: client()
  def new(token, opts \\ []) do
    Client.new(token, opts)
  end

  @doc """
  Returns a sprite handle for the given name.

  This does not create or verify the sprite exists - it just returns
  a handle that can be used for operations.

  ## Examples

      sprite = Sprites.sprite(client, "my-sprite")
  """
  @spec sprite(client(), String.t()) :: sprite()
  def sprite(client, name) do
    Sprite.new(client, name)
  end

  @doc """
  Creates a new sprite via the API.

  ## Options

    * `:config` - Sprite configuration map

  ## Examples

      {:ok, sprite} = Sprites.create(client, "my-sprite")
  """
  @spec create(client(), String.t(), keyword()) :: {:ok, sprite()} | {:error, term()}
  def create(client, name, opts \\ []) do
    Client.create_sprite(client, name, opts)
  end

  @doc """
  Destroys a sprite.

  ## Examples

      :ok = Sprites.destroy(sprite)
  """
  @spec destroy(sprite()) :: :ok | {:error, term()}
  def destroy(sprite) do
    Sprite.destroy(sprite)
  end

  @doc """
  Executes a command synchronously, similar to `System.cmd/3`.

  Returns `{output, exit_code}` where output is a binary containing
  the combined stdout (and optionally stderr).

  ## Options

    * `:env` - Environment variables as a list of `{key, value}` tuples
    * `:dir` - Working directory
    * `:timeout` - Command timeout in milliseconds
    * `:stderr_to_stdout` - Redirect stderr to stdout (default: false)
    * `:tty` - Allocate a TTY (default: false)
    * `:tty_rows` - TTY rows (default: 24)
    * `:tty_cols` - TTY columns (default: 80)

  ## Examples

      {output, 0} = Sprites.cmd(sprite, "echo", ["hello"])
      {output, code} = Sprites.cmd(sprite, "ls", ["-la"], dir: "/app")
  """
  @spec cmd(sprite(), String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}
  def cmd(sprite, command, args \\ [], opts \\ []) do
    Command.run(sprite, command, args, opts)
  end

  @doc """
  Spawns an async command, similar to `Port.open/2`.

  Returns `{:ok, command}` where command is a handle for the running process.
  Messages are sent to the calling process (or the process specified via `:owner`):

    * `{:stdout, command, data}` - stdout data
    * `{:stderr, command, data}` - stderr data
    * `{:exit, command, exit_code}` - command exited
    * `{:error, command, reason}` - error occurred

  ## Options

    * `:owner` - Process to receive messages (default: `self()`)
    * `:env` - Environment variables as a list of `{key, value}` tuples
    * `:dir` - Working directory
    * `:tty` - Allocate a TTY (default: false)
    * `:tty_rows` - TTY rows (default: 24)
    * `:tty_cols` - TTY columns (default: 80)

  ## Examples

      {:ok, cmd} = Sprites.spawn(sprite, "bash", ["-i"], tty: true)

      receive do
        {:stdout, ^cmd, data} -> IO.write(data)
        {:exit, ^cmd, code} -> IO.puts("Done: \#{code}")
      end
  """
  @spec spawn(sprite(), String.t(), [String.t()], keyword()) ::
          {:ok, command()} | {:error, term()}
  def spawn(sprite, command, args \\ [], opts \\ []) do
    Command.start(sprite, command, args, opts)
  end

  @doc """
  Writes data to stdin of a running command.

  ## Examples

      Sprites.write(command, "hello\\n")
  """
  @spec write(command(), iodata()) :: :ok | {:error, term()}
  def write(command, data) do
    Command.write_stdin(command, data)
  end

  @doc """
  Closes stdin of a running command (sends EOF).

  ## Examples

      Sprites.close_stdin(command)
  """
  @spec close_stdin(command()) :: :ok
  def close_stdin(command) do
    Command.close_stdin(command)
  end

  @doc """
  Waits for a command to complete.

  Returns `{:ok, exit_code}` when the command exits.

  ## Examples

      {:ok, 0} = Sprites.await(command)
      {:ok, code} = Sprites.await(command, 30_000)
  """
  @spec await(command(), timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  def await(command, timeout \\ :infinity) do
    Command.await(command, timeout)
  end

  @doc """
  Resizes the TTY of a running command.

  Only works if the command was started with `tty: true`.

  ## Examples

      Sprites.resize(command, 40, 120)
  """
  @spec resize(command(), pos_integer(), pos_integer()) :: :ok
  def resize(command, rows, cols) do
    Command.resize(command, rows, cols)
  end

  @doc """
  Returns a Stream that emits command output.

  Useful for processing command output lazily.

  ## Examples

      sprite
      |> Sprites.stream("tail", ["-f", "/var/log/app.log"])
      |> Stream.each(&IO.write/1)
      |> Stream.run()
  """
  @spec stream(sprite(), String.t(), [String.t()], keyword()) :: Enumerable.t()
  def stream(sprite, command, args \\ [], opts \\ []) do
    Sprites.Stream.new(sprite, command, args, opts)
  end

  # ============================================================================
  # Network Policy API
  # ============================================================================

  @doc """
  Gets the current network policy for a sprite.

  ## Examples

      {:ok, policy} = Sprites.get_network_policy(sprite)
      IO.inspect(policy.rules)
  """
  @spec get_network_policy(sprite()) :: {:ok, Sprites.Policy.t()} | {:error, term()}
  def get_network_policy(sprite) do
    Sprites.Policy.get(sprite)
  end

  @doc """
  Updates the network policy for a sprite.

  ## Examples

      policy = %Sprites.Policy{
        rules: [
          %Sprites.Policy.Rule{domain: "example.com", action: "allow"}
        ]
      }
      :ok = Sprites.update_network_policy(sprite, policy)
  """
  @spec update_network_policy(sprite(), Sprites.Policy.t()) :: :ok | {:error, term()}
  def update_network_policy(sprite, policy) do
    Sprites.Policy.update(sprite, policy)
  end

  # ============================================================================
  # Checkpoint API
  # ============================================================================

  @doc """
  Lists all checkpoints for a sprite.

  ## Options

    * `:history` - History filter string (optional)

  ## Examples

      {:ok, checkpoints} = Sprites.list_checkpoints(sprite)
  """
  @spec list_checkpoints(sprite(), keyword()) ::
          {:ok, [Sprites.Checkpoint.t()]} | {:error, term()}
  def list_checkpoints(sprite, opts \\ []) do
    Sprites.Checkpoint.list(sprite, opts)
  end

  @doc """
  Gets a specific checkpoint by ID.

  ## Examples

      {:ok, checkpoint} = Sprites.get_checkpoint(sprite, "checkpoint-id")
  """
  @spec get_checkpoint(sprite(), String.t()) :: {:ok, Sprites.Checkpoint.t()} | {:error, term()}
  def get_checkpoint(sprite, checkpoint_id) do
    Sprites.Checkpoint.get(sprite, checkpoint_id)
  end

  @doc """
  Creates a new checkpoint for a sprite.

  Returns a stream of messages. The stream should be consumed to completion.

  ## Options

    * `:comment` - Optional comment for the checkpoint

  ## Examples

      {:ok, messages} = Sprites.create_checkpoint(sprite, comment: "Before changes")
      Enum.each(messages, fn msg -> IO.inspect(msg) end)
  """
  @spec create_checkpoint(sprite(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def create_checkpoint(sprite, opts \\ []) do
    Sprites.Checkpoint.create(sprite, opts)
  end

  @doc """
  Restores a sprite from a checkpoint.

  Returns a stream of messages. The stream should be consumed to completion.

  ## Examples

      {:ok, messages} = Sprites.restore_checkpoint(sprite, "checkpoint-id")
      Enum.each(messages, fn msg -> IO.inspect(msg) end)
  """
  @spec restore_checkpoint(sprite(), String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def restore_checkpoint(sprite, checkpoint_id) do
    Sprites.Checkpoint.restore(sprite, checkpoint_id)
  end

  # ============================================================================
  # Session API
  # ============================================================================

  @doc """
  Lists all active sessions for a sprite.

  ## Examples

      {:ok, sessions} = Sprites.list_sessions(sprite)
  """
  @spec list_sessions(sprite()) :: {:ok, [Sprites.Session.t()]} | {:error, term()}
  def list_sessions(sprite) do
    Sprites.Session.list(sprite)
  end

  @doc """
  Spawns and attaches to an existing session.

  ## Examples

      {:ok, cmd} = Sprites.attach_session(sprite, "session-id")
  """
  @spec attach_session(sprite(), String.t(), keyword()) :: {:ok, command()} | {:error, term()}
  def attach_session(sprite, session_id, opts \\ []) do
    opts = Keyword.put(opts, :session_id, session_id)
    # When attaching to a session, we spawn with empty command
    # The session_id will be sent as a query param
    Command.start(sprite, "", [], opts)
  end

  # ============================================================================
  # Port Forwarding API
  # ============================================================================

  @doc """
  Creates a proxy session for a single port.

  Returns a session PID that manages the proxy. Use `Sprites.Proxy.Session.stop/1`
  to close the proxy.

  ## Examples

      {:ok, session} = Sprites.proxy_port(sprite, 3000, 3000)
      # Local port 3000 now forwards to remote port 3000
      Sprites.Proxy.Session.stop(session)
  """
  @spec proxy_port(sprite(), non_neg_integer(), non_neg_integer()) ::
          {:ok, pid()} | {:error, term()}
  def proxy_port(sprite, local_port, remote_port) do
    Sprites.Proxy.proxy_port(sprite, local_port, remote_port)
  end

  @doc """
  Creates proxy sessions for multiple port mappings.

  ## Examples

      mappings = [
        %Sprites.Proxy.PortMapping{local_port: 3000, remote_port: 3000},
        %Sprites.Proxy.PortMapping{local_port: 8080, remote_port: 80}
      ]
      {:ok, sessions} = Sprites.proxy_ports(sprite, mappings)
  """
  @spec proxy_ports(sprite(), [Sprites.Proxy.PortMapping.t()]) ::
          {:ok, [pid()]} | {:error, term()}
  def proxy_ports(sprite, mappings) do
    Sprites.Proxy.proxy_ports(sprite, mappings)
  end

  # ============================================================================
  # Filesystem API
  # ============================================================================

  @doc """
  Creates a filesystem handle for a sprite.

  The filesystem handle provides file operations similar to Elixir's `File` module.

  ## Examples

      fs = Sprites.filesystem(sprite, "/app")
      {:ok, content} = Sprites.Filesystem.read(fs, "config.json")
      :ok = Sprites.Filesystem.write(fs, "output.txt", "data")
  """
  @spec filesystem(sprite(), String.t()) :: Sprites.Filesystem.t()
  def filesystem(sprite, working_dir \\ "/") do
    Sprites.Filesystem.new(sprite, working_dir)
  end

  # ============================================================================
  # Extended Sprite Management
  # ============================================================================

  @doc """
  Gets detailed information about a sprite.

  ## Examples

      {:ok, info} = Sprites.get_sprite(client, "my-sprite")
  """
  @spec get_sprite(client(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_sprite(client, name) do
    Client.get_sprite(client, name)
  end

  @doc """
  Triggers an upgrade for a sprite.

  ## Examples

      :ok = Sprites.upgrade(sprite)
  """
  @spec upgrade(sprite()) :: :ok | {:error, term()}
  def upgrade(%Sprite{client: client, name: name}) do
    Client.upgrade_sprite(client, name)
  end

  @doc """
  Updates URL settings for a sprite.

  ## Examples

      :ok = Sprites.update_url_settings(sprite, %{auth: "bearer"})
  """
  @spec update_url_settings(sprite(), map()) :: :ok | {:error, term()}
  def update_url_settings(%Sprite{client: client, name: name}, settings) do
    Client.update_url_settings(client, name, settings)
  end

  @doc """
  Lists all sprites.

  ## Options

    * `:prefix` - Filter by name prefix

  ## Examples

      {:ok, sprites} = Sprites.list(client)
      {:ok, sprites} = Sprites.list(client, prefix: "test-")
  """
  @spec list(client(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(client, opts \\ []) do
    Client.list_sprites(client, opts)
  end
end
