defmodule Sprites.ClientSignals do
  @moduledoc false

  @cache_key {__MODULE__, :headers}
  @disable_values ~w(0 off false no disabled)
  @version Mix.Project.config()[:version]
  @user_agent "sprites-ex/#{@version}"

  @doc false
  @spec signal_headers() :: [{String.t(), String.t()}]
  def signal_headers do
    case :persistent_term.get(@cache_key, :unset) do
      :unset ->
        headers = compute_headers()
        :persistent_term.put(@cache_key, headers)
        headers

      headers ->
        headers
    end
  end

  @doc false
  @spec auth_headers(String.t(), [{String.t(), String.t()}]) ::
          [{String.t(), String.t()}]
  def auth_headers(token, extra_headers \\ []) do
    signal_headers() ++ [{"authorization", "Bearer #{token}"} | extra_headers]
  end

  @doc false
  @spec reset_cached_for_test() :: :ok
  def reset_cached_for_test do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp compute_headers do
    if disabled?() do
      [{"user-agent", @user_agent}]
    else
      signals = ClientSignals.detect_once()

      signal_headers =
        signals
        |> ClientSignals.headers_for()
        |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)

      [
        {"user-agent", "#{@user_agent} #{ClientSignals.user_agent_suffix(signals)}"}
        | signal_headers
      ]
    end
  end

  defp disabled? do
    System.get_env("SPRITES_CLIENT_SIGNALS", "")
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in @disable_values))
  end
end
