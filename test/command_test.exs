defmodule Sprites.CommandTest do
  use ExUnit.Case, async: true

  alias Sprites.{Command, ControlConn, Protocol, Sprite}

  for mode <- [:direct, :tty, :control, :op_complete],
      code <- [nil, false, true, "0", %{}, [], -1, 256, 1.0, 999_999_999_999] do
    test "#{mode} rejects invalid exit code #{inspect(code)}" do
      mode = unquote(mode)
      code = unquote(Macro.escape(code))

      state =
        command_state(%{
          tty_mode: unquote(mode == :tty),
          using_control: unquote(mode in [:control, :op_complete]),
          control_conn: if(unquote(mode in [:control, :op_complete]), do: self())
        })

      ref = state.ref

      assert {:stop, :normal, %{exit_code: nil, terminal_error: :invalid_exit_code} = stopped} =
               deliver(exit_frame(mode, code), state)

      assert_receive {:error, %{ref: ^ref}, :invalid_exit_code}
      refute_received {:exit, _, _}

      if state.using_control do
        assert stopped.control_conn == nil
        assert_receive {:"$gen_cast", :close}
      end
    end
  end

  for mode <- [:direct, :tty, :control, :op_complete], code <- [0, 255] do
    test "#{mode} accepts exit code boundary #{code}" do
      mode = unquote(mode)
      code = unquote(code)

      state =
        command_state(%{
          tty_mode: unquote(mode == :tty),
          using_control: unquote(mode in [:control, :op_complete]),
          sprite: Sprite.new(Sprites.new("test-token"), "exit-test")
        })

      ref = state.ref
      result = deliver(exit_frame(mode, code), state)
      assert elem(result, tuple_size(result) - 1).exit_code == code
      assert_receive {:exit, %{ref: ^ref}, ^code}
      refute_received {:error, _, _}
    end
  end

  test "an invalid exit followed by a close reports one error and no success" do
    state = command_state()
    ref = state.ref
    frames = [exit_frame(:direct, "0"), {:close, 1000, ""}]

    assert {:stop, :normal, %{exit_code: nil}} = Command.handle_frames(frames, state)

    assert_receive {:error, %{ref: ^ref}, :invalid_exit_code}
    refute_received {:error, _, _}
    refute_received {:exit, _, _}
  end

  defp deliver({:control_op_complete, _} = message, state),
    do: Command.handle_info(message, state)

  defp deliver({:control_data, _, _} = message, state), do: Command.handle_info(message, state)
  defp deliver(frame, state), do: Command.handle_frames([frame], state)

  defp exit_frame(:op_complete, code) do
    # Exercise the actual control JSON decoder before the command boundary.
    payload = "control:" <> Jason.encode!(%{type: "op.complete", args: %{exitCode: code}})
    state = %{conn: nil, owner: self(), op_active: true}

    assert {:noreply, %{op_active: false}} = ControlConn.handle_frames([{:text, payload}], state)

    assert_receive {:control_op_complete, ^code} = message
    message
  end

  defp exit_frame(mode, code) do
    json = Jason.encode!(%{type: "exit", exit_code: code})

    if mode == :control,
      do: {:control_data, :text, json},
      else: {:text, json}
  end

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
             Command.handle_frames([{:text, ~s({"type":"exit"})}], state)

    assert_receive {:exit, %{ref: ^ref}, 0}
  end

  test "handles a binary exit frame in direct mode" do
    state = command_state()
    ref = state.ref
    frame = <<Protocol.exit_id(), 42>>

    assert {:stop, :normal, %{exit_code: 42}} =
             Command.handle_frames([{:binary, frame}], state)

    assert_receive {:exit, %{ref: ^ref}, 42}
  end

  test "reports an error when a close frame arrives without an exit frame" do
    state = command_state()
    ref = state.ref

    assert {:stop, :normal, %{exit_code: nil}} =
             Command.handle_frames([{:close, 1000, ""}], state)

    assert_receive {:error, %{ref: ^ref}, :closed_before_exit}
    refute_receive {:exit, %{ref: ^ref}, 0}
  end

  test "an exit frame followed by a close in the same batch reports success" do
    state = command_state()
    ref = state.ref
    frames = [{:binary, <<Protocol.exit_id(), 0>>}, {:close, 1000, ""}]

    assert {:stop, :normal, %{exit_code: 0}} = Command.handle_frames(frames, state)

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
