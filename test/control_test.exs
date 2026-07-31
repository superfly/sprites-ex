defmodule Sprites.ControlTest do
  use ExUnit.Case, async: true

  alias Sprites.{Client, Sprite, Control}

  describe "Client control_mode" do
    test "defaults to false" do
      client = Client.new("test-token")
      assert client.control_mode == false
    end

    test "can be set to true" do
      client = Client.new("test-token", control_mode: true)
      assert client.control_mode == true
    end

    test "can be explicitly set to false" do
      client = Client.new("test-token", control_mode: false)
      assert client.control_mode == false
    end
  end

  describe "Sprite.control_mode?/1" do
    test "reflects client control_mode setting" do
      client = Client.new("test-token", control_mode: true)
      sprite = Sprite.new(client, "my-sprite")
      assert Sprite.control_mode?(sprite) == true
    end

    test "returns false when client has control_mode disabled" do
      client = Client.new("test-token")
      sprite = Sprite.new(client, "my-sprite")
      assert Sprite.control_mode?(sprite) == false
    end
  end

  describe "Sprite.control_url/1" do
    test "builds correct URL with https base" do
      client = Client.new("test-token", base_url: "https://api.sprites.dev")
      sprite = Sprite.new(client, "my-sprite")
      assert Sprite.control_url(sprite) == "wss://api.sprites.dev/v1/sprites/my-sprite/control"
    end

    test "builds correct URL with http base" do
      client = Client.new("test-token", base_url: "http://localhost:8080")
      sprite = Sprite.new(client, "my-sprite")
      assert Sprite.control_url(sprite) == "ws://localhost:8080/v1/sprites/my-sprite/control"
    end

    test "encodes sprite name in URL" do
      client = Client.new("test-token", base_url: "https://api.sprites.dev")
      sprite = Sprite.new(client, "my sprite")

      assert Sprite.control_url(sprite) ==
               "wss://api.sprites.dev/v1/sprites/my%20sprite/control"
    end
  end

  describe "Control.control_supported?/1" do
    test "returns true by default for new sprites" do
      client = Client.new("test-token")
      sprite = Sprite.new(client, "supported-sprite-#{System.unique_integer([:positive])}")
      assert Control.control_supported?(sprite) == true
    end

    test "returns false after mark_unsupported" do
      client = Client.new("test-token")
      sprite = Sprite.new(client, "unsupported-sprite-#{System.unique_integer([:positive])}")

      Control.mark_unsupported(sprite)
      assert Control.control_supported?(sprite) == false
    end
  end

  describe "Sprites.new/2" do
    test "passes control_mode to client" do
      client = Sprites.new("test-token", control_mode: true)
      assert client.control_mode == true
    end
  end
end
