defmodule Sprites.ClientSignalsTest do
  use ExUnit.Case, async: false

  alias Sprites.ClientSignals, as: SpritesClientSignals

  setup do
    original = System.get_env("SPRITES_CLIENT_SIGNALS")

    on_exit(fn ->
      restore_env("SPRITES_CLIENT_SIGNALS", original)
      reset_caches()
    end)

    reset_caches()
    :ok
  end

  test "adds client signals and the SDK User-Agent to authenticated headers" do
    System.delete_env("SPRITES_CLIENT_SIGNALS")

    headers = SpritesClientSignals.auth_headers("test-token") |> Map.new()

    assert headers["authorization"] == "Bearer test-token"
    assert headers["user-agent"] =~ ~r/^sprites-ex\/\d+\.\d+\.\d+ \(interactive=/
    assert headers["fly-client-interactive"] in ["true", "false"]
    assert headers["fly-client-parent"] in ["node", "python", "shell", "other"]
  end

  test "returns a plain User-Agent without detecting signals when opted out" do
    System.put_env("SPRITES_CLIENT_SIGNALS", "false")

    headers = SpritesClientSignals.signal_headers() |> Map.new()

    assert %{"user-agent" => user_agent} = headers
    assert user_agent =~ ~r/^sprites-ex\/\d+\.\d+\.\d+$/
    refute Enum.any?(Map.keys(headers), &String.starts_with?(&1, "fly-client-"))
  end

  test "accepts common opt-out values" do
    for value <- ["0", "off", "false", "no", "disabled", "OFF", " No "] do
      reset_caches()
      System.put_env("SPRITES_CLIENT_SIGNALS", value)

      assert [{"user-agent", _user_agent}] = SpritesClientSignals.signal_headers()
    end
  end

  test "caches the opt-out setting on first use" do
    System.put_env("SPRITES_CLIENT_SIGNALS", "0")
    first = SpritesClientSignals.signal_headers()

    System.delete_env("SPRITES_CLIENT_SIGNALS")

    assert SpritesClientSignals.signal_headers() == first
  end

  test "configures the main Req client with attribution" do
    System.delete_env("SPRITES_CLIENT_SIGNALS")

    request = Sprites.Client.new("test-token").req

    assert Req.Request.get_header(request, "authorization") == ["Bearer test-token"]
    assert [user_agent] = Req.Request.get_header(request, "user-agent")
    assert user_agent =~ ~r/^sprites-ex\/\d+\.\d+\.\d+ \(interactive=/
    assert Req.Request.get_header(request, "fly-client-interactive") in [["true"], ["false"]]
  end

  defp reset_caches do
    SpritesClientSignals.reset_cached_for_test()
    ClientSignals.reset_cached_for_test()
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
