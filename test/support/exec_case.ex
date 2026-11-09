defmodule Sprites.Test.ExecCase do
  @moduledoc """
  Test case for exercising command execution against `Sprites.Test.FakeWsServer`.

  Provides helpers to build exec URLs and to spawn commands in direct or control
  mode, returning what the fake server received.
  """

  use ExUnit.CaseTemplate

  alias Sprites.{Client, Control, Sprite}
  alias Sprites.Test.FakeWsServer

  using do
    quote do
      import Sprites.Test.ExecCase
    end
  end

  @doc "Builds the direct-mode exec URL for a sprite on the public API host."
  @spec exec_url(String.t(), [String.t()], keyword()) :: String.t()
  def exec_url(command, args, opts) do
    client = Client.new("test-token", base_url: "https://api.sprites.dev")
    Sprite.exec_url(Sprite.new(client, "my-sprite"), command, args, opts)
  end

  @doc "Decoded query params of the exec URL for `bash` with the given options."
  @spec exec_query(keyword()) :: map()
  def exec_query(opts) do
    exec_url("bash", [], opts)
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end

  @doc """
  Starts a `FakeWsServer` under the test supervisor and returns a sprite
  pointing at it. Options: `:control` (use control mode) and `:frames`
  (binary frames the server sends once connected).
  """
  @spec fake_sprite(keyword()) :: Sprite.t()
  def fake_sprite(opts \\ []) do
    control_mode = Keyword.get(opts, :control, false)

    server =
      ExUnit.Callbacks.start_supervised!(
        {FakeWsServer, [owner: self()] ++ Keyword.take(opts, [:frames])}
      )

    client =
      Client.new("test-token", base_url: FakeWsServer.url(server), control_mode: control_mode)

    sprite = Sprite.new(client, "sprite-#{System.unique_integer([:positive])}")
    if control_mode, do: ExUnit.Callbacks.on_exit(fn -> Control.close(sprite) end)
    sprite
  end

  @doc """
  Runs `fun` with a direct-mode fake sprite and returns `{path, query}` of the
  WebSocket request it made, with the sprite name replaced by `SPRITE`.
  """
  @spec direct_request((Sprite.t() -> {:ok, term()})) :: {String.t(), map()}
  def direct_request(fun) do
    sprite = fake_sprite()
    {:ok, _cmd} = fun.(sprite)
    assert_receive {:ws_request, path, query}
    {String.replace(path, sprite.name, "SPRITE"), query}
  end

  @doc "Spawns in control mode and returns the `args` of the `op.start` message."
  @spec control_op_args(String.t(), [String.t()], keyword()) :: map()
  def control_op_args(command, args, opts) do
    {:ok, _cmd} = Sprites.spawn(fake_sprite(control: true), command, args, opts)
    assert_receive {:ws_frame, :text, "control:" <> json}
    assert %{"type" => "op.start", "op" => "exec", "args" => op_args} = Jason.decode!(json)
    op_args
  end
end
