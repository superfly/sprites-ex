defmodule Sprites.Protocol do
  @moduledoc """
  Binary protocol encoding/decoding for Sprites WebSocket.

  ## Non-TTY Mode Protocol

  Each message has a stream ID as the first byte:

    * 0 - stdin (client -> server)
    * 1 - stdout (server -> client)
    * 2 - stderr (server -> client)
    * 3 - exit (server -> client, first payload byte is the exit code; defaults to 0)
    * 4 - stdin EOF (client -> server)

  ## TTY Mode Protocol

    * Binary frames are raw terminal data
    * Text frames are JSON control messages
  """

  @stdin_id 0
  @stdout_id 1
  @stderr_id 2
  @exit_id 3
  @stdin_eof_id 4

  @type stream_type :: :stdin | :stdout | :stderr | :exit | :stdin_eof | :unknown
  @type decoded :: {stream_type(), binary() | integer() | nil}

  @doc """
  Decodes a binary message from the WebSocket.

  Returns a tuple of `{stream_type, payload}` where:
    * `{:stdout, binary}` - stdout data
    * `{:stderr, binary}` - stderr data
    * `{:exit, integer}` - first payload byte as the exit code (defaults to 0 when omitted)
    * `{:stdin_eof, nil}` - stdin closed
    * `{:unknown, binary}` - unrecognized data
  """
  @spec decode(binary()) :: decoded()
  def decode(<<@stdout_id, payload::binary>>), do: {:stdout, payload}
  def decode(<<@stderr_id, payload::binary>>), do: {:stderr, payload}
  def decode(<<@exit_id, code::unsigned-8, _rest::binary>>), do: {:exit, code}
  def decode(<<@exit_id>>), do: {:exit, 0}
  def decode(<<@stdin_eof_id>>), do: {:stdin_eof, nil}
  def decode(data), do: {:unknown, data}

  @doc """
  Encodes stdin data for sending.

  In TTY mode, data is sent as raw binary.
  In non-TTY mode, data is prefixed with the stdin stream ID.
  """
  @spec encode_stdin(iodata(), boolean()) :: binary()
  def encode_stdin(data, true), do: IO.iodata_to_binary(data)
  def encode_stdin(data, false), do: <<@stdin_id, IO.iodata_to_binary(data)::binary>>

  @doc """
  Encodes the stdin EOF signal.
  """
  @spec encode_stdin_eof() :: binary()
  def encode_stdin_eof, do: <<@stdin_eof_id>>

  @doc """
  Returns the stream ID constants.
  """
  def stdin_id, do: @stdin_id
  def stdout_id, do: @stdout_id
  def stderr_id, do: @stderr_id
  def exit_id, do: @exit_id
  def stdin_eof_id, do: @stdin_eof_id
end
