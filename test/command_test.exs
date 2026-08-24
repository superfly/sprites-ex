defmodule Sprites.CommandTest do
  use ExUnit.Case, async: true

  alias Sprites.{Command, Protocol}

  test "handles the exit_code field in control text exit frames" do
    state = command_state(%{using_control: true})
    ref = state.ref

    assert {:noreply, %{exit_code: 42}} =
             Command.handle_info(
               {:control_data, :text, ~s({"type":"exit","exit_code":42})},
               state
             )

    assert_receive {:exit, %{ref: ^ref}, 42}
  end

  test "defaults a code-less control text exit frame to zero" do
    state = command_state(%{using_control: true})
    ref = state.ref

    assert {:noreply, %{exit_code: 0}} =
             Command.handle_info(
               {:control_data, :text, ~s({"type":"exit"})},
               state
             )

    assert_receive {:exit, %{ref: ^ref}, 0}
  end

  test "handles a code-less text exit frame in direct TTY mode" do
    state = command_state(%{tty_mode: true})
    ref = state.ref

    assert {:stop, :normal, %{exit_code: 0}} =
             Command.handle_info(
               {:gun_ws, nil, make_ref(), {:text, ~s({"type":"exit"})}},
               state
             )

    assert_receive {:exit, %{ref: ^ref}, 0}
  end

  test "handles a binary exit frame in direct mode" do
    state = command_state()
    ref = state.ref
    frame = <<Protocol.exit_id(), 42>>

    assert {:stop, :normal, %{exit_code: 42}} =
             Command.handle_info({:gun_ws, nil, make_ref(), {:binary, frame}}, state)

    assert_receive {:exit, %{ref: ^ref}, 42}
  end

  test "drains a pending direct binary exit before handling gun_down" do
    state = command_state()
    ref = state.ref
    frame = <<Protocol.exit_id(), 0>>

    send(self(), {:gun_ws, nil, make_ref(), {:binary, frame}})

    assert {:stop, :normal, _state} =
             Command.handle_info({:gun_down, nil, :http, :closed, []}, state)

    assert_receive {:exit, %{ref: ^ref}, 0}
    refute_receive {:error, %{ref: ^ref}, :closed}
  end

  test "reports an error when a close frame arrives without an exit frame" do
    state = command_state()
    ref = state.ref

    assert {:stop, :normal, %{exit_code: nil}} =
             Command.handle_info({:gun_ws, nil, make_ref(), {:close, 1000, ""}}, state)

    assert_receive {:error, %{ref: ^ref}, :closed_before_exit}
    refute_receive {:exit, %{ref: ^ref}, 0}
  end

  test "drains a pending direct binary exit before handling a close frame" do
    state = command_state()
    ref = state.ref
    frame = <<Protocol.exit_id(), 0>>

    send(self(), {:gun_ws, nil, make_ref(), {:binary, frame}})

    assert {:stop, :normal, %{exit_code: 0}} =
             Command.handle_info({:gun_ws, nil, make_ref(), {:close, 1000, ""}}, state)

    assert_receive {:exit, %{ref: ^ref}, 0}
    refute_receive {:error, %{ref: ^ref}, :closed_before_exit}
  end

  defp command_state(overrides \\ %{}) do
    Map.merge(
      %{
        owner: self(),
        ref: make_ref(),
        tty_mode: false,
        conn: nil,
        stream_ref: nil,
        exit_code: nil,
        token: nil,
        sprite: nil,
        url: nil,
        using_control: false,
        control_conn: nil
      },
      overrides
    )
  end
end
