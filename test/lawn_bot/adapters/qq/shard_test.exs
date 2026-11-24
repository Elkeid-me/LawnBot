defmodule LawnBot.Adapters.QQ.ShardTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.QQ.Shard
  alias LawnBot.Adapters.QQ.Utils
  alias LawnBot.TokenStore

  @moduletag capture_log: true

  @bot :ShardTestBot
  @token "QQBot access-token"
  @persistent_keys [:max_concurrency, :workers, :permissions, :os, :browser, :device]

  setup do
    ensure_token_store()
    TokenStore.put(@bot, @token)
    :persistent_term.put(@bot, fn _event -> %LawnBot.Response{action: :ignore} end)

    persistent_values = [
      max_concurrency: 1,
      workers: 2,
      permissions: 33_554_433,
      os: "test",
      browser: "test",
      device: "test"
    ]

    Enum.each(persistent_values, fn {key, value} ->
      :persistent_term.put({@bot, key}, value)
    end)

    on_exit(fn ->
      Enum.each(@persistent_keys, fn key -> :persistent_term.erase({@bot, key}) end)
      :persistent_term.erase(@bot)
    end)

    :ok
  end

  defp ensure_token_store do
    case :ets.whereis(:auth_tokens) do
      :undefined -> TokenStore.new()
      _table -> :ok
    end
  end

  defp state(overrides \\ []) do
    struct!(%Shard{name: @bot, shard_id: 0}, overrides)
  end

  defp cancel_timers(shard_state) do
    Enum.each([shard_state.heartbeat_ref, shard_state.auth_ref], fn
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _other -> :ok
    end)
  end

  test "creates a child spec keyed by shard id" do
    shard_state = state()

    assert %{id: {Shard, 0}, start: {Shard, :start_link, [^shard_state]}} =
             Shard.child_spec(shard_state)
  end

  describe "handle_frame/2" do
    test "stores session data and sequence from READY" do
      payload = ~s({"op":0,"t":"READY","s":7,"d":{"session_id":"session-1"}})

      assert {:ok, updated} = Shard.handle_frame({:text, payload}, state())
      assert updated.session_id == "session-1"
      assert updated.seq == 7
    end

    test "keeps the highest sequence number" do
      assert {:ok, %Shard{seq: 10}} =
               Shard.handle_frame({:text, ~s({"op":0,"t":"RESUMED","s":9})}, state(seq: 10))

      assert {:ok, %Shard{seq: 11}} =
               Shard.handle_frame({:text, ~s({"op":0,"t":"RESUMED","s":11})}, state(seq: 10))
    end

    test "replies to a gateway heartbeat with the current sequence" do
      shard_state = state(seq: 12)

      assert {:reply, {:text, response}, updated} =
               Shard.handle_frame({:text, ~s({"op":1})}, shard_state)

      assert JSON.decode!(response) == %{"op" => 1, "d" => 12}
      assert updated.awaiting_ack?
    end

    test "clears the heartbeat acknowledgement flag after an ACK" do
      shard_state = state(awaiting_ack?: true)

      assert {:ok, updated} = Shard.handle_frame({:text, ~s({"op":11})}, shard_state)
      refute updated.awaiting_ack?
    end

    test "closes the connection when the gateway asks to reconnect" do
      shard_state = state()

      assert {:close, ^shard_state} = Shard.handle_frame({:text, ~s({"op":7})}, shard_state)
    end

    test "clears the session after an invalid session response" do
      shard_state = state(session_id: "session-1", seq: 12, awaiting_ack?: true)

      assert {:close, updated} =
               Shard.handle_frame({:text, ~s({"op":9,"d":false})}, shard_state)

      assert updated.session_id == nil
      assert updated.seq == nil
      refute updated.awaiting_ack?
    end

    test "schedules authentication after Hello" do
      payload = ~s({"op":10,"d":{"heartbeat_interval":1000}})

      assert {:ok, updated} = Shard.handle_frame({:text, payload}, state())
      assert updated.heartbeat_interval == 1000
      refute updated.awaiting_ack?
      assert is_reference(updated.auth_ref)

      cancel_timers(updated)
    end

    test "ignores unknown opcodes" do
      shard_state = state()

      assert {:ok, ^shard_state} =
               Shard.handle_frame({:text, ~s({"op":12,"d":null})}, shard_state)
    end

    test "ignores malformed and non-object frames" do
      shard_state = state()

      assert {:ok, ^shard_state} = Shard.handle_frame({:text, "not-json"}, shard_state)
      assert {:ok, ^shard_state} = Shard.handle_frame({:text, "[]"}, shard_state)
      assert {:ok, ^shard_state} = Shard.handle_frame(:binary, shard_state)
    end
  end

  describe "handle_connect/2" do
    test "cancels pending timers and clears the acknowledgement flag" do
      shard_state =
        state(
          awaiting_ack?: true,
          heartbeat_ref: Process.send_after(self(), :heartbeat, 10_000),
          auth_ref: Process.send_after(self(), :authenticate, 10_000)
        )

      assert {:ok, updated} = Shard.handle_connect(:connection, shard_state)
      assert updated.heartbeat_ref == nil
      assert updated.auth_ref == nil
      refute updated.awaiting_ack?
    end
  end

  describe "handle_info/2" do
    test "identifies with configured intents" do
      shard_state = state(heartbeat_interval: 1_000)

      assert {:reply, {:text, response}, updated} = Shard.handle_info(:authenticate, shard_state)
      payload = JSON.decode!(response)

      assert payload["op"] == 2
      assert payload["d"]["token"] == @token
      assert payload["d"]["intents"] == 33_554_433
      assert payload["d"]["shard"] == [0, 2]

      assert payload["d"]["properties"] == %{
               "$os" => "test",
               "$browser" => "test",
               "$device" => "test"
             }

      assert is_reference(updated.heartbeat_ref)

      cancel_timers(updated)
    end

    test "resumes an existing session" do
      shard_state = state(session_id: "session-1", seq: 12, heartbeat_interval: 1_000)

      assert {:reply, {:text, response}, updated} = Shard.handle_info(:authenticate, shard_state)
      payload = JSON.decode!(response)

      assert payload["op"] == 6

      assert payload["d"] == %{
               "token" => @token,
               "session_id" => "session-1",
               "seq" => 12
             }

      cancel_timers(updated)
    end

    test "reads the token from the store at authentication time" do
      shard_state = state(heartbeat_interval: 1_000)
      TokenStore.put(@bot, "QQBot rotated-token")

      assert {:reply, {:text, response}, updated} = Shard.handle_info(:authenticate, shard_state)
      assert JSON.decode!(response)["d"]["token"] == "QQBot rotated-token"

      cancel_timers(updated)
    end

    test "sends a heartbeat with the current sequence" do
      shard_state = state(heartbeat_interval: 1_000, seq: 3)

      assert {:reply, {:text, response}, updated} = Shard.handle_info(:heartbeat, shard_state)

      assert JSON.decode!(response) == %{"op" => 1, "d" => 3}
      assert updated.awaiting_ack?
      assert is_reference(updated.heartbeat_ref)

      cancel_timers(updated)
    end

    test "reconnects when a heartbeat is not acknowledged" do
      shard_state = state(awaiting_ack?: true, seq: 3)

      assert {:close, updated} = Shard.handle_info(:heartbeat, shard_state)
      refute updated.awaiting_ack?
    end

    test "ignores unrelated messages" do
      shard_state = state()

      assert {:ok, ^shard_state} = Shard.handle_info(:unrelated, shard_state)
      assert {:ok, ^shard_state} = Shard.handle_cast(:unrelated, shard_state)
    end
  end

  test "dispatches gateway events to the configured handler" do
    start_registry()
    start_task_supervisor()

    test_pid = self()

    :persistent_term.put(@bot, fn event ->
      send(test_pid, {:handled, event})
      %LawnBot.Response{action: :ignore}
    end)

    payload = %{
      "op" => 0,
      "t" => "GROUP_MESSAGE_CREATE",
      "s" => 5,
      "d" => %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "hello",
        "message_type" => 0,
        "author" => %{"member_openid" => "member-1"}
      }
    }

    assert {:ok, %Shard{seq: 5}} =
             Shard.handle_frame({:text, JSON.encode!(payload)}, state())

    assert_receive {:handled,
                    %LawnBot.Event{
                      session_type: :group,
                      session_id: "group-1",
                      message_type: :normal,
                      message_id: "message-1",
                      author_id: "member-1",
                      content: "hello"
                    }},
                   2_000
  end

  defp start_registry do
    case Process.whereis(LawnBot.AdapterRegistry) do
      nil -> start_supervised!({Registry, keys: :unique, name: LawnBot.AdapterRegistry})
      _pid -> :ok
    end
  end

  defp start_task_supervisor do
    name = Utils.task_supervisor_via_tuple(@bot)

    case Registry.lookup(LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, @bot}) do
      [] -> start_supervised!({Task.Supervisor, name: name})
      _pids -> :ok
    end
  end
end
