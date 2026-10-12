defmodule LawnBot.Adapters.QQ.ShardTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.Shard

  @config %{app_id: "app", client_secret: "secret"}

  defp state(overrides \\ []) do
    struct!(
      %Shard{
        config: @config,
        gateway_url: "wss://gateway.example",
        shard: [0, 2],
        max_concurrency: 1,
        token: %{access_token: "access-token", expires_in: 3_600}
      },
      overrides
    )
  end

  defp cancel_timers(state) do
    Enum.each([state.heartbeat_ref, state.auth_ref], fn
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end)
  end

  test "creates a child spec keyed by shard id" do
    shard_state = state()

    assert %{id: {Shard, 0}, start: {Shard, :start_link, [^shard_state]}} =
             Shard.child_spec(shard_state)
  end

  test "stores session data and sequence from READY" do
    payload = ~s({"op":0,"t":"READY","s":7,"d":{"session_id":"session-1"}})

    assert {:ok, updated} = Shard.handle_frame({:text, payload}, state())
    assert updated.session_id == "session-1"
    assert updated.seq == 7
  end

  test "schedules authentication after Hello" do
    payload = ~s({"op":10,"d":{"heartbeat_interval":1000}})

    assert {:ok, updated} = Shard.handle_frame({:text, payload}, state())
    assert updated.heartbeat_interval == 1000
    assert is_reference(updated.auth_ref)

    cancel_timers(updated)
  end

  test "replies to a gateway heartbeat with the current sequence" do
    shard_state = state(seq: 12)

    assert {:reply, {:text, response}, updated} =
             Shard.handle_frame({:text, ~s({"op":1})}, shard_state)

    assert JSON.decode!(response) == %{"op" => 1, "d" => 12}
    assert updated.awaiting_ack?
  end

  test "clears the session after an invalid session response" do
    shard_state = state(session_id: "session-1", seq: 12, awaiting_ack?: true)

    assert {:close, updated} =
             Shard.handle_frame({:text, ~s({"op":9,"d":false})}, shard_state)

    assert updated.session_id == nil
    assert updated.seq == nil
    refute updated.awaiting_ack?
  end

  test "identifies with configured intents" do
    shard_state = state(config: Map.put(@config, :intents, [:guilds, :group_and_c2c]))

    assert {:reply, {:text, response}, updated} = Shard.handle_info(:authenticate, shard_state)
    payload = JSON.decode!(response)

    assert payload["op"] == 2
    assert payload["d"]["token"] == "QQBot access-token"
    assert payload["d"]["intents"] == 33_554_433
    assert payload["d"]["shard"] == [0, 2]
    assert is_reference(updated.heartbeat_ref)

    cancel_timers(updated)
  end

  test "ignores malformed and non-object frames" do
    shard_state = state()

    assert {:ok, ^shard_state} = Shard.handle_frame({:text, "not-json"}, shard_state)
    assert {:ok, ^shard_state} = Shard.handle_frame({:text, "[]"}, shard_state)
    assert {:ok, ^shard_state} = Shard.handle_frame(:binary, shard_state)
  end
end
