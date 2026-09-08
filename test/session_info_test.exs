defmodule Sprites.SessionInfoTest do
  use ExUnit.Case, async: true

  alias Sprites.Command

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        owner: self(),
        ref: make_ref(),
        tty_mode: false,
        conn: nil,
        stream_ref: nil,
        exit_code: nil,
        using_control: false,
        control_conn: nil,
        report_session_info: true,
        session_id: nil
      },
      overrides
    )
  end

  defp direct(state, message) do
    Command.handle_info({:gun_ws, nil, make_ref(), {:text, Jason.encode!(message)}}, state)
  end

  for {mode, id, normalized} <- [
        {:direct, 19, "19"},
        {:direct, "abc-123", "abc-123"},
        {:tty, "42", "42"},
        {:control, 19, "19"}
      ] do
    test "#{mode} reports #{inspect(id)} with the command ref and no other metadata" do
      state = state(%{tty_mode: unquote(mode) == :tty, using_control: unquote(mode) == :control})
      ref = state.ref
      message = %{type: "session_info", session_id: unquote(id), command: "private command"}

      frame =
        if unquote(mode) == :control,
          do: {:control_data, :text, Jason.encode!(message)},
          else: {:gun_ws, nil, make_ref(), {:text, Jason.encode!(message)}}

      assert {:noreply, %{session_id: unquote(normalized)}} = Command.handle_info(frame, state)
      assert_receive {:session_info, %{ref: ^ref}, unquote(normalized)}
      refute_receive {:session_info, _, _}
    end
  end

  test "default callers receive no new messages, even for invalid metadata" do
    state = state(%{report_session_info: false})
    assert {:noreply, ^state} = direct(state, %{type: "session_info", session_id: 19})
    assert {:noreply, ^state} = direct(state, %{type: "session_info"})
    refute_receive {:session_info, _, _}
    refute_receive {:error, _, _}
  end

  test "repeated normalized identity is emitted once" do
    state = state()
    ref = state.ref
    {:noreply, state} = direct(state, %{type: "session_info", session_id: 19})
    assert_receive {:session_info, %{ref: ^ref}, "19"}
    assert {:noreply, ^state} = direct(state, %{type: "session_info", session_id: "19"})
    refute_receive {:session_info, _, _}
  end

  test "a conflicting identity fails without replacing the original" do
    state = state(%{session_id: "19"})
    ref = state.ref

    assert {:stop, :normal, %{session_id: "19", terminal_error: :conflicting_session_info}} =
             direct(state, %{type: "session_info", session_id: "20"})

    assert_receive {:error, %{ref: ^ref}, :conflicting_session_info}
    refute_receive {:session_info, _, _}
    refute_receive {:exit, _, _}
  end

  for id <- [nil, "", 0, -1, 1.5, [], %{}, "../19", "a?b", String.duplicate("x", 257)] do
    test "invalid session ID #{inspect(id, printable_limit: 16)} cannot become identity or success" do
      state = state()
      ref = state.ref

      assert {:stop, :normal, %{terminal_error: :invalid_session_info}} =
               direct(state, %{type: "session_info", session_id: unquote(Macro.escape(id))})

      assert_receive {:error, %{ref: ^ref}, :invalid_session_info}
      refute_receive {:session_info, _, _}
      refute_receive {:exit, _, _}
    end
  end

  test "invalid control metadata closes the connection instead of returning it to the pool" do
    state = state(%{using_control: true, control_conn: self()})
    ref = state.ref

    assert {:stop, :normal, %{control_conn: nil, terminal_error: :invalid_session_info}} =
             Command.handle_info({:control_data, :text, ~s({"type":"session_info"})}, state)

    assert_receive {:error, %{ref: ^ref}, :invalid_session_info}
    assert_receive {:"$gen_cast", :close}
  end

  test "metadata after an already reported control exit cannot emit another terminal frame" do
    state = state(%{using_control: true, exit_code: 7})
    assert {:noreply, ^state} = direct(state, %{type: "session_info"})
    refute_receive {:error, _, _}
    refute_receive {:session_info, _, _}
  end

  for closing <- [:close, :down] do
    test "metadata failure drained during #{closing} emits exactly one error" do
      state = state()
      ref = state.ref
      send(self(), {:gun_ws, nil, make_ref(), {:text, ~s({"type":"session_info"})}})

      frame =
        if unquote(closing) == :close,
          do: {:gun_ws, nil, make_ref(), {:close, 1000, ""}},
          else: {:gun_down, nil, :http, :closed, []}

      assert {:stop, :normal, _state} = Command.handle_info(frame, state)

      assert_receive {:error, %{ref: ^ref}, :invalid_session_info}
      refute_receive {:error, %{ref: ^ref}, _}
      refute_receive {:exit, %{ref: ^ref}, _}
    end
  end

  test "missing provider metadata and lookalike stdout never invent identity" do
    state = state()
    ref = state.ref
    text = Jason.encode!(%{type: "session_info", session_id: 19})

    assert {:noreply, ^state} =
             Command.handle_info(
               {:gun_ws, nil, make_ref(), {:binary, <<1, text::binary>>}},
               state
             )

    assert_receive {:stdout, %{ref: ^ref}, ^text}

    assert {:stop, :normal, %{session_id: nil, exit_code: 7}} =
             Command.handle_info({:gun_ws, nil, make_ref(), {:binary, <<3, 7>>}}, state)

    assert_receive {:exit, %{ref: ^ref}, 7}
    refute_receive {:session_info, _, _}
  end
end
