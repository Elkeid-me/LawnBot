defmodule LawnBot.AdapterSupervisorTest do
  use ExUnit.Case, async: false

  alias LawnBot.AdapterSupervisor

  test "initializes a one-for-one dynamic supervisor" do
    assert {:ok, %{strategy: :one_for_one, intensity: 3, period: 5}} = AdapterSupervisor.init(:test)
  end

  test "rejects unsupported platforms before starting a child" do
    assert {:error, :not_implemented} = AdapterSupervisor.start_adapter(:unknown, %{})
  end
end
