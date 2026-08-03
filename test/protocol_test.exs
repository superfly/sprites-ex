defmodule Sprites.ProtocolTest do
  use ExUnit.Case, async: true

  alias Sprites.Protocol

  test "decodes the one-byte exit frame" do
    assert Protocol.decode(<<Protocol.exit_id(), 0>>) == {:exit, 0}
    assert Protocol.decode(<<Protocol.exit_id(), 42>>) == {:exit, 42}
    assert Protocol.decode(<<Protocol.exit_id(), 255>>) == {:exit, 255}
  end

  test "defaults a code-less exit frame to zero" do
    assert Protocol.decode(<<Protocol.exit_id()>>) == {:exit, 0}
  end

  test "uses the first exit payload byte and ignores trailing bytes" do
    assert Protocol.decode(<<Protocol.exit_id(), 42, 0, 255>>) == {:exit, 42}
  end
end
