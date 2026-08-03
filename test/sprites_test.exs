defmodule SpritesTest do
  use ExUnit.Case, async: true
  doctest Sprites

  test "creates a client with normalized options" do
    client = Sprites.new("test-token", base_url: "https://api.example.test/", timeout: 1_000)

    assert client.token == "test-token"
    assert client.base_url == "https://api.example.test"
    assert client.timeout == 1_000
  end
end
