defmodule LawnBot.Adapters.QQ.CoordinatorTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.Coordinator

  @config %{app_id: "app", client_secret: "secret"}

  test "creates a child spec keyed by app id" do
    supervisor = self()

    assert %{id: {Coordinator, "app"}, start: {Coordinator, :start_link, [{^supervisor, @config}]}} =
             Coordinator.child_spec({supervisor, @config})
  end

  test "initializes with an asynchronous bootstrap continuation" do
    assert {:ok, state, {:continue, :bootstrap}} = Coordinator.init({self(), @config})
    assert state.supervisor == self()
    assert state.config == @config
    assert state.token == nil
    assert state.gateway == nil
    assert state.refresh_ref == nil
  end

  test "ignores unrelated messages" do
    state = %{supervisor: self(), config: @config, token: nil, gateway: nil, refresh_ref: nil}

    assert {:noreply, ^state} = Coordinator.handle_info(:unrelated, state)
  end
end
