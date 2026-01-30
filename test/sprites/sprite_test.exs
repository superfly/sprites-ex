defmodule Sprites.SpriteTest do
  use ExUnit.Case, async: true

  alias Sprites.Sprite

  describe "path/3" do
    test "it builds the correct path when no param are provided" do
      client = Sprites.Client.new("test_token", base_url: "https://api.sprites.dev")
      sprite = Sprite.new(client, "my_sprite")

      url =
        Sprite.path(sprite, "/fs/list")

      assert url == "/v1/sprites/my_sprite/fs/list"
    end

    test "it builds the correct path when params are provided as a map" do
      client = Sprites.Client.new("test_token", base_url: "https://api.sprites.dev")
      sprite = Sprite.new(client, "my_sprite")

      url =
        Sprite.path(sprite, "/fs/list", %{path: "/home/user", recursive: true})

      assert url == "/v1/sprites/my_sprite/fs/list?path=%2Fhome%2Fuser&recursive=true"
    end

    test "it builds the correct path when params are provided as a keyword list" do
      client = Sprites.Client.new("test_token", base_url: "https://api.sprites.dev")
      sprite = Sprite.new(client, "my_sprite")

      url =
        Sprite.path(sprite, "/fs/list", path: "/home/user", recursive: true)

      assert url == "/v1/sprites/my_sprite/fs/list?path=%2Fhome%2Fuser&recursive=true"
    end
  end
end
