defmodule Sprites.ExecOptionsTest do
  use Sprites.Test.ExecCase, async: true

  alias Sprites.{Client, Sprite}

  describe "Sprite.exec_url/4" do
    test "builds the spawn URL with command and default params" do
      assert exec_url("echo", ["hi"], []) ==
               "wss://api.sprites.dev/v1/sprites/my-sprite/exec?stdin=false&path=echo&cmd=echo&cmd=hi"
    end

    test "includes spawn options" do
      query =
        exec_query(
          stdin: true,
          dir: "/app",
          env: [{"FOO", "bar"}],
          tty: true,
          tty_rows: 40,
          tty_cols: 120,
          detachable: true
        )

      assert %{
               "stdin" => "true",
               "dir" => "/app",
               "env" => "FOO=bar",
               "tty" => "true",
               "rows" => "40",
               "cols" => "120",
               "detachable" => "true"
             } = query
    end

    test "builds the attach URL with only stdin/tty params" do
      url = exec_url("bash", [], session_id: "abc", dir: "/app", detachable: true, tty: true)

      assert %URI{path: "/v1/sprites/my-sprite/exec/abc", query: query} = URI.parse(url)
      assert Map.keys(URI.decode_query(query)) |> Enum.sort() == ~w(cols rows stdin tty)
    end
  end

  describe "control-mode exec args" do
    test "include cmd and stdin by default" do
      assert control_op_args("echo", ["hi"], []) == %{"cmd" => ["echo", "hi"], "stdin" => "false"}
    end

    test "include spawn options" do
      opts = [
        stdin: true,
        dir: "/app",
        env: [{"FOO", "bar"}],
        tty: true,
        tty_rows: 40,
        tty_cols: 120
      ]

      assert control_op_args("bash", [], opts) == %{
               "cmd" => ["bash"],
               "dir" => "/app",
               "env" => ["FOO=bar"],
               "tty" => "true",
               "rows" => "40",
               "cols" => "120",
               "stdin" => "true"
             }
    end
  end

  describe "direct-mode exec requests" do
    test "Sprites.spawn/4 connects to the spawn URL with its options" do
      {path, query} =
        direct_request(
          &Sprites.spawn(&1, "bash", ["-l"], dir: "/app", tty: true, detachable: true)
        )

      assert path == "/v1/sprites/SPRITE/exec"

      assert %{
               "cmd" => "-l",
               "path" => "bash",
               "dir" => "/app",
               "tty" => "true",
               "detachable" => "true",
               "stdin" => "false"
             } = query
    end

    test "Sprites.attach_session/3 connects to the attach URL without spawn options" do
      {path, query} = direct_request(&Sprites.attach_session(&1, "abc", dir: "/app", tty: true))

      assert path == "/v1/sprites/SPRITE/exec/abc"
      assert Map.keys(query) |> Enum.sort() == ~w(cols rows stdin tty)
    end

    test "Sprites.cmd/4 returns output and exit code from the exec stream" do
      sprite = fake_sprite(frames: [<<1, "hello">>, <<3, 7>>])

      assert Sprites.cmd(sprite, "echo", ["hello"], max_run_after_disconnect: "10s") ==
               {"hello", 7}

      assert_receive {:ws_request, _path, %{"max_run_after_disconnect" => "10s"}}
    end
  end

  describe "max_run_after_disconnect" do
    test "is returned when it is a string and nil when unset" do
      assert Sprite.max_run_after_disconnect(max_run_after_disconnect: "10s") == "10s"
      assert Sprite.max_run_after_disconnect([]) == nil
    end

    test "raises ArgumentError for non-string values" do
      assert_raise ArgumentError, ~r/duration string/, fn ->
        Sprite.max_run_after_disconnect(max_run_after_disconnect: 10_000)
      end
    end

    test "is sent on direct-mode spawn when set" do
      {_path, query} =
        direct_request(&Sprites.spawn(&1, "bash", [], tty: true, max_run_after_disconnect: "10s"))

      assert query["max_run_after_disconnect"] == "10s"
    end

    test "is not sent on direct-mode spawn when unset" do
      {_path, query} = direct_request(&Sprites.spawn(&1, "bash", [], tty: true))

      refute Map.has_key?(query, "max_run_after_disconnect")
    end

    test "is not sent when attaching to a session" do
      {_path, query} =
        direct_request(&Sprites.attach_session(&1, "abc", max_run_after_disconnect: "10s"))

      refute Map.has_key?(query, "max_run_after_disconnect")
    end

    test "is sent in control-mode args when set" do
      args = control_op_args("bash", [], max_run_after_disconnect: "10s")

      assert args["max_run_after_disconnect"] == "10s"
    end

    test "is not sent in control-mode args when unset" do
      refute Map.has_key?(control_op_args("bash", [], []), "max_run_after_disconnect")
    end

    test "raises in the caller for non-string values before connecting" do
      direct = Sprite.new(Client.new("test-token"), "my-sprite")

      for sprite <- [direct, fake_sprite(control: true)] do
        assert_raise ArgumentError, ~r/duration string/, fn ->
          Sprites.spawn(sprite, "bash", [], max_run_after_disconnect: 10_000)
        end
      end

      # Neither transport was contacted
      refute_receive {:ws_request, _, _}
    end
  end
end
