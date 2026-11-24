defmodule Sprites.TransportTest do
  use ExUnit.Case, async: true

  alias Sprites.Transport

  test "TLS options verify the server certificate against system roots" do
    opts = Transport.tls_opts()

    assert opts[:verify] == :verify_peer
    assert opts[:cacerts] != nil
    assert opts[:customize_hostname_check][:match_fun] != nil
  end
end
