# Sprites Elixir SDK

An Elixir SDK for the Sprites code container runtime - a remote code execution platform for interactive development.

## Quick Reference

### Common Commands

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test

# Format code (REQUIRED before committing)
mix format

# Generate docs
mix docs
```

### Test CLI

```bash
cd test_cli
mix deps.get
mix escript.build

# Usage
export SPRITES_TOKEN=your-token
./test-cli create my-sprite
./test-cli -sprite my-sprite -output stdout echo hello
./test-cli destroy my-sprite
```

### Integration Tests (with Go test harness)

```bash
export SPRITES_TEST_TOKEN=your-token
export SDK_TEST_COMMAND=/path/to/sprites-ex/test_cli/test-cli
# Run from the Go SDK directory
go test -v
```

## Project Structure

```
lib/sprites/
├── sprites.ex      # Main public API (entry point)
├── client.ex       # HTTP client for REST API (uses Req)
├── sprite.ex       # Sprite instance representation
├── command.ex      # Command execution via WebSocket (GenServer)
├── web_socket.ex   # Mint-based WebSocket client used by command, control, proxy
├── protocol.ex     # Binary protocol codec for WebSocket messages
├── stream.ex       # Lazy Stream interface for command output
└── errors.ex       # Custom exceptions (APIError, CommandError, etc.)
```

## Key Dependencies

- **req** - HTTP client for REST API calls
- **mint** / **mint_web_socket** - WebSocket client for command execution, control and proxy
- **jason** - JSON encoding/decoding

## Environment Variables

- `SPRITES_TOKEN` - Authentication token for Sprites API
- `SPRITES_TEST_TOKEN` - Authentication token for testing

## Version Requirements

- Elixir: 1.18.4-otp-27
- Erlang: 27.0.1

(See `.tool-versions` for asdf configuration)

## API Defaults

- Base URL: `https://api.sprites.dev`
- HTTP timeout: 30 seconds
- Create sprite timeout: 120 seconds
- WebSocket upgrade timeout: 10 seconds

## Code Style

- Always run `mix format` before committing
- All public functions should have `@doc` and `@spec`
- Follow standard Elixir conventions
