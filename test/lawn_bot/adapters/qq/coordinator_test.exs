defmodule LawnBot.Adapters.QQ.CoordinatorTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.Coordinator
  alias LawnBot.Adapters.QQ.TokenStore

  defp state(tid) do
    %{
      name: :TestBot,
      token_table_tid: tid,
      refresh_ref: nil
    }
  end

  test "creates a child spec keyed by module" do
    tid = TokenStore.new()

    assert %{id: Coordinator, start: {Coordinator, :start_link, [{:TestBot, ^tid}]}} =
             Coordinator.child_spec({:TestBot, tid})
  end

  test "initializes with an asynchronous bootstrap continuation" do
    tid = TokenStore.new()

    assert {:ok, state, {:continue, :bootstrap}} = Coordinator.init({:TestBot, tid})
    assert state.name == :TestBot
    assert state.token_table_tid == tid
    assert state.refresh_ref == nil
  end

  test "ignores unrelated messages" do
    state = state(TokenStore.new())

    assert {:noreply, ^state} = Coordinator.handle_info(:unrelated, state)
  end
end
