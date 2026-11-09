defmodule Sprites.PathTest do
  use ExUnit.Case, async: true

  alias Sprites.{Checkpoint, Client, Filesystem, Policy, Session, Sprite}

  @name "mine/../victim?x=#fragment%2F ü"
  @encoded "mine%2F..%2Fvictim%3Fx%3D%23fragment%252F%20%C3%BC"
  @checkpoint "c1/../../../victim/checkpoints/c9?x=#"
  @encoded_checkpoint "c1%2F..%2F..%2F..%2Fvictim%2Fcheckpoints%2Fc9%3Fx%3D%23"

  test "encodes all reserved characters, percent signs, whitespace and UTF-8" do
    assert Sprites.Path.encode_segment(@name) == @encoded

    assert Sprites.Path.encode_segment(":/?#[]@!$&'()*+,;=") ==
             "%3A%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D"

    assert Sprites.Path.encode_segment("abc-123_~.txt") == "abc-123_~.txt"
  end

  for {label, method, suffix, module, function, extra} <- [
        {:delete, :delete, "", Client, :delete_sprite, []},
        {:get, :get, "", Client, :get_sprite, []},
        {:upgrade, :post, "/upgrade", Client, :upgrade_sprite, []},
        {:url_settings, :put, "", Client, :update_url_settings, [%{auth: "none"}]},
        {:checkpoint_list, :get, "/checkpoints", Checkpoint, :list_by_name, []},
        {:checkpoint_get, :get, "/checkpoints/" <> @encoded_checkpoint, Checkpoint, :get_by_name,
         [@checkpoint]},
        {:policy_get, :get, "/policy/network", Policy, :get_by_name, []},
        {:policy_update, :post, "/policy/network", Policy, :update_by_name, [%Policy{}]},
        {:sessions, :get, "/exec", Session, :list_by_name, []},
        {:filesystem, :get, "/fs/read", Filesystem, :read, []}
      ] do
    test "#{label} keeps identifiers inside their path segments" do
      client = Client.new("test-token", base_url: "https://example.test")
      expected_path = "/v1/sprites/" <> @encoded <> unquote(suffix)

      adapter = fn request ->
        assert request.method == unquote(method)
        assert request.url.host == "example.test"
        assert request.url.path == expected_path
        assert request.url.fragment == nil

        case unquote(label) do
          :filesystem -> assert URI.decode_query(request.url.query)["path"] == "/file?x=#"
          _ -> assert request.url.query in [nil, ""]
        end

        send(self(), :request_checked)
        {request, Req.Response.new(status: 404, body: %{})}
      end

      req =
        client.req
        |> Req.merge(adapter: __MODULE__)
        |> Req.Request.put_private(:assert_request, adapter)

      client = %{client | req: req}

      if unquote(module) == Filesystem do
        Filesystem.read(Filesystem.new(Sprite.new(client, @name)), "/file?x=#")
      else
        apply(unquote(module), unquote(function), [client, @name] ++ unquote(Macro.escape(extra)))
      end

      assert_received :request_checked
    end
  end

  test "exec, attach and control URLs encode sprite and session identifiers" do
    sprite = Sprite.new(Client.new("test-token"), @name)
    base_path = "/v1/sprites/" <> @encoded
    exec = URI.parse(Sprite.exec_url(sprite, "echo", ["hello?"], []))
    attach = URI.parse(Sprite.exec_url(sprite, "", [], session_id: @checkpoint))
    control = URI.parse(Sprite.control_url(sprite))

    assert exec.path == base_path <> "/exec"
    assert URI.decode_query(exec.query)["cmd"] == "hello?"
    assert attach.path == base_path <> "/exec/" <> @encoded_checkpoint
    assert control.path == base_path <> "/control"
    assert control.query == nil
    assert Enum.all?([exec, attach, control], &is_nil(&1.fragment))
  end

  def run(request), do: request.private.assert_request.(request)

  for invalid <- ["", ".", ".."] do
    test "rejects ambiguous identifier #{inspect(invalid)} before a request" do
      client = Client.new("test-token", base_url: "http://127.0.0.1:1")
      invalid = unquote(invalid)
      sprite = Sprite.new(client, "valid")

      for operation <- [
            fn -> Sprites.Path.encode_segment(invalid) end,
            fn -> Client.delete_sprite(client, invalid) end,
            fn -> Checkpoint.create_by_name(client, invalid) end,
            fn -> Checkpoint.restore_by_name(client, "valid", invalid) end,
            fn -> Sprite.exec_url(sprite, "", [], session_id: invalid) end,
            fn -> Sprite.control_url(Sprite.new(client, invalid)) end
          ] do
        assert_raise ArgumentError, ~r/path identifier/, operation
      end
    end
  end
end
