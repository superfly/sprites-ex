defmodule Sprites.Transport do
  @moduledoc false

  @doc """
  Options for `:gun.open/3` given a URL scheme. TLS connections verify the
  server certificate against the system root store and check the hostname.
  """
  @spec gun_opts(String.t()) :: map()
  def gun_opts("wss") do
    %{
      protocols: [:http],
      transport: :tls,
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }
  end

  def gun_opts(_scheme), do: %{protocols: [:http], transport: :tcp}
end
