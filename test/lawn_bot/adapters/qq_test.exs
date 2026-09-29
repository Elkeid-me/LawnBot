defmodule LawnBot.Adapters.QQTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ

  test "ignores configuration without credentials" do
    assert :ignore = QQ.start_link(%{})
    assert :ignore = QQ.start_link(%{app_id: "", client_secret: "secret"})
    assert :ignore = QQ.start_link(%{app_id: "app", client_secret: ""})
  end

  test "builds the QQ authorization token" do
    assert QQ.token("access-token") == "QQBot access-token"
  end

  test "builds a registry key for a shard" do
    assert QQ.shard_registry_key("app", 2) == {QQ, "app", 2}
  end

  test "initializes a one-for-one supervisor with restart limits" do
    assert {:ok, %{strategy: :one_for_one, intensity: 3, period: 5}} = QQ.init(:test)
  end
end
