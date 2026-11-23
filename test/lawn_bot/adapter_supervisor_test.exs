defmodule LawnBot.AdapterSupervisorTest do
  use ExUnit.Case, async: false

  alias LawnBot.AdapterSupervisor

  @moduletag capture_log: true

  test "initializes a one-for-one dynamic supervisor" do
    assert {:ok, %{strategy: :one_for_one, intensity: 3, period: 5}} =
             AdapterSupervisor.init(:test)
  end

  test "reports unsupported platforms with a keyword list of options" do
    assert {:error, :not_implemented} = AdapterSupervisor.start_adapter(:unknown, [])
  end

  test "rejects invalid adapter options" do
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:qq, [])
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:qq, app_id: "app")
  end

  test "rejects non-atom platforms and non-list options" do
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter("qq", [])
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:qq, %{})
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:unknown, %{})
  end
end
