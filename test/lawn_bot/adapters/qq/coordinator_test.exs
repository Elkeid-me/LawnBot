defmodule LawnBot.Adapters.QQ.CoordinatorTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.Coordinator
  alias LawnBot.Adapters.QQ.TokenStore

  @config %{app_id: "app", client_secret: "secret"}

  defp state(tid) do
    %{
      config: @config,
      token_table: tid,
      gateway: nil,
      refresh_ref: nil
    }
  end

  test "creates a child spec keyed by module" do
    tid = TokenStore.new()

    assert %{id: Coordinator, start: {Coordinator, :start_link, [{@config, ^tid}]}} =
             Coordinator.child_spec({@config, tid})
  end

  test "initializes with an asynchronous bootstrap continuation" do
    tid = TokenStore.new()

    assert {:ok, state, {:continue, :bootstrap}} = Coordinator.init({@config, tid})
    assert state.config == @config
    assert state.token_table == tid
    assert state.gateway == nil
    assert state.refresh_ref == nil
  end

  test "ignores unrelated messages" do
    state = state(TokenStore.new())

    assert {:noreply, ^state} = Coordinator.handle_info(:unrelated, state)
  end
end
