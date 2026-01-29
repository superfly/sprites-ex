# Fix TCP Proxy Socket Ownership Bug

## Problem

The TCP proxy was not forwarding connections. Connections would be accepted but data never flowed through the WebSocket tunnel to the sprite.

## Root Cause

Two bugs in `lib/sprites/proxy.ex`:

1. **Incorrect PID capture (line 94)**: `self()` was called inside `spawn_link`, capturing the spawned accept_loop's PID instead of the GenServer's PID. This caused `GenServer.cast` to send messages to the wrong process.

2. **Missing socket ownership transfer (line 131)**: When `accept_loop` accepts a socket, it becomes the controlling process. Before the GenServer can transfer ownership to the handler process, it must first own the socket itself.

## Fix

```elixir
# 1. Capture GenServer PID before spawning accept_loop
server = self()
spawn_link(fn -> accept_loop(server, listener) end)

# 2. Transfer socket ownership from accept_loop to GenServer before casting
:gen_tcp.controlling_process(socket, server)
GenServer.cast(server, {:new_connection, socket})
```

## Testing

After the fix, all proxy ports successfully forward traffic:
- Port 8081 (code-server): 302 redirect
- Port 4096 (opencode): 200 OK
- Port 7681 (gotty): 401 (auth required, as expected)
