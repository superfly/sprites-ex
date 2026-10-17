defmodule Sprites.PolicyTest do
  use ExUnit.Case, async: true

  alias Sprites.Policy
  alias Sprites.Policy.Rule

  @policy %Policy{rules: [%Rule{domain: "example.com", action: "allow"}]}

  setup do
    client = Sprites.new("test-token", base_url: "https://api.example.test")
    %{client: %{client | req: Req.merge(client.req, plug: {Req.Test, __MODULE__})}}
  end

  describe "update_by_name/3" do
    test "returns :ok on a 200 response", %{client: client} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/sprites/my-sprite/policy/network"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"rules" => [%{"domain" => "example.com", "action" => "allow"}]})
      end)

      assert :ok = Policy.update_by_name(client, "my-sprite", @policy)
    end

    test "returns :ok on a 204 response", %{client: client} do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 204, ""))

      assert :ok = Policy.update_by_name(client, "my-sprite", @policy)
    end

    test "returns an invalid_policy error on a 400 response", %{client: client} do
      body = %{"error" => "invalid domain"}

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(body)
      end)

      assert {:error, {:invalid_policy, ^body}} =
               Policy.update_by_name(client, "my-sprite", @policy)
    end
  end
end
