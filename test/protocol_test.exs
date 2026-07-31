defmodule Sprites.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sprites.Protocol

  test "decodes the one-byte exit frame" do
    assert Protocol.decode(<<Protocol.exit_id(), 0>>) == {:exit, 0}
    assert Protocol.decode(<<Protocol.exit_id(), 42>>) == {:exit, 42}
    assert Protocol.decode(<<Protocol.exit_id(), 255>>) == {:exit, 255}
  end
end
