defmodule Sprites.Transport do
  @moduledoc false

  @doc """
  TLS options that verify the server certificate against the system root
  store and check the hostname.
  """
  @spec tls_opts() :: keyword()
  def tls_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
