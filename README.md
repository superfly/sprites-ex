# Sprites Elixir SDK

Elixir SDK for Sprites - a code container runtime for interactive development.

## Installation

Add `sprites` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sprites, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a client
client = Sprites.new(token, base_url: "https://api.sprites.dev")

# Get a sprite handle
sprite = Sprites.sprite(client, "my-sprite")

# Execute a command synchronously (like System.cmd/3)
{output, exit_code} = Sprites.cmd(sprite, "echo", ["hello"])
IO.puts(output)  # => "hello\n"

# Execute a command asynchronously (like Port message passing)
{:ok, command} = Sprites.spawn(sprite, "ls", ["-la"])

receive do
  {:stdout, ^command, data} -> IO.write(data)
  {:stderr, ^command, data} -> IO.write(:stderr, data)
  {:exit, ^command, code} -> IO.puts("Exited with: #{code}")
end
```

## API Reference

### Client Management

```elixir
# Create a client
client = Sprites.new(token, base_url: "https://api.sprites.dev")

# Get a sprite handle (doesn't create the sprite)
sprite = Sprites.sprite(client, "my-sprite")

# Create a new sprite
{:ok, sprite} = Sprites.create(client, "new-sprite")

# Destroy a sprite
:ok = Sprites.destroy(sprite)
```

### Command Execution

#### Synchronous (System.cmd-like)

```elixir
# Basic execution
{output, exit_code} = Sprites.cmd(sprite, "echo", ["hello"])

# With options
{output, code} = Sprites.cmd(sprite, "ls", ["-la"],
  dir: "/app",
  env: [{"FOO", "bar"}],
  timeout: 30_000,
  stderr_to_stdout: true
)

# With TTY
{output, code} = Sprites.cmd(sprite, "bash", ["-c", "tty"],
  tty: true,
  tty_rows: 24,
  tty_cols: 80
)
```

#### Asynchronous (Port-like)

```elixir
# Start a command
{:ok, command} = Sprites.spawn(sprite, "bash", ["-i"], tty: true)

# Messages are sent to the calling process:
# - {:stdout, command, data}
# - {:stderr, command, data}
# - {:exit, command, exit_code}
# - {:error, command, reason}

# Write to stdin
Sprites.write(command, "ls\n")

# Close stdin (send EOF)
Sprites.close_stdin(command)

# Wait for completion
{:ok, exit_code} = Sprites.await(command)

# Resize TTY
Sprites.resize(command, 40, 120)
```

#### Streaming

```elixir
# Stream command output
sprite
|> Sprites.stream("tail", ["-f", "/var/log/app.log"])
|> Stream.filter(&String.contains?(&1, "ERROR"))
|> Stream.each(&Logger.error/1)
|> Stream.run()
```

## Test CLI

The SDK includes a test CLI for integration testing with the shared test harness:

```bash
cd test_cli
mix deps.get
mix escript.build

# Set auth token
export SPRITES_TOKEN=your-token

# Create a sprite
./test-cli create my-sprite

# Run a command
./test-cli -sprite my-sprite -output stdout echo hello

# Interactive TTY
./test-cli -sprite my-sprite -tty bash

# Destroy the sprite
./test-cli destroy my-sprite
```

### CLI Flags

| Flag | Description |
|------|-------------|
| `-base-url <url>` | API base URL (default: https://api.sprites.dev) |
| `-sprite <name>` | Sprite name (required for exec) |
| `-output <mode>` | Output mode: stdout, combined, exit-code, default |
| `-tty` | Enable TTY mode |
| `-tty-rows <n>` | TTY rows (default: 24) |
| `-tty-cols <n>` | TTY columns (default: 80) |
| `-timeout <dur>` | Command timeout (e.g., 10s, 5m) |
| `-dir <path>` | Working directory |
| `-env key=val` | Environment variables |
| `-log-target <path>` | JSON event log file |

## Running SDK Tests

The Elixir SDK is compatible with the shared test harness:

```bash
cd /path/to/sprite-env/sdks/test
export SPRITES_TEST_TOKEN=your-token
export SDK_TEST_COMMAND=/path/to/sprites-ex/test_cli/test-cli
make test-all
```

## Client signals

Requests and WebSocket handshakes carry coarse, privacy-safe
[`client-signals`](https://github.com/superfly/client-signals) attribution in
`Fly-Client-*` headers and a `sprites-ex/<version>` User-Agent suffix. These
signals help Fly.io estimate how much API traffic is human- or agent-driven;
they are advisory only and are not used for gating or rate-limiting.

Set `SPRITES_CLIENT_SIGNALS=0` to opt out. The values `off`, `false`, `no`, and
`disabled` are also accepted. When disabled, the SDK still sends its plain
User-Agent but does not detect or send client signals.

Signals and the opt-out setting are read once, on first SDK use, and cached for
the lifetime of the BEAM instance.

## License

MIT
