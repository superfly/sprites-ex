defmodule Sprites.TransportTest do
  use ExUnit.Case, async: true

  alias Sprites.Transport

  test "wss connections verify the server certificate against system roots" do
    opts = Transport.gun_opts("wss")

    assert opts.transport == :tls
    assert opts.tls_opts[:verify] == :verify_peer
    assert opts.tls_opts[:cacerts] != nil
    assert opts.tls_opts[:customize_hostname_check][:match_fun] != nil
  end

  test "ws connections use plain tcp" do
    assert Transport.gun_opts("ws") == %{protocols: [:http], transport: :tcp}
  end
end
