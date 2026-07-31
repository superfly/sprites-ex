defmodule Sprites.CommandTest do
  use ExUnit.Case, async: true

  alias Sprites.Command

  test "handles the exit_code field in text exit frames" do
    ref = make_ref()

    state = %{
      using_control: true,
      owner: self(),
      ref: ref,
      exit_code: nil
    }

    assert {:noreply, %{exit_code: 42}} =
             Command.handle_info(
               {:control_data, :text, ~s({"type":"exit","exit_code":42})},
               state
             )

    assert_receive {:exit, %{ref: ^ref}, 42}
  end
end
