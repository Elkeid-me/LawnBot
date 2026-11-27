defmodule LawnBot.AdapterSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LawnBot.Adapters.Feishu
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
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:lark, [])
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:feishu, [])
  end

  test "rejects non-atom platforms and non-list options" do
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter("qq", [])
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:qq, %{})
    assert {:error, :validation_failed} = AdapterSupervisor.start_adapter(:unknown, %{})
  end

  test "reports adapter startup failures instead of swallowing them" do
    name = :LarkAdapterSupervisorTestBot

    ensure_registry()
    ensure_adapter_supervisor()

    # Occupy the supervisor name so starting the adapter fails.
    {:ok, _owner} = Registry.register(LawnBot.AdapterRegistry, {Feishu, name}, nil)

    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 AdapterSupervisor.start_adapter(:feishu,
                   app_id: "cli-app",
                   app_secret: "secret",
                   name: name
                 )
      end)

    assert log =~ "Failed to start adapter for platform feishu"
  end

  defp ensure_registry do
    if Process.whereis(LawnBot.AdapterRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: LawnBot.AdapterRegistry})
    end

    :ok
  end

  defp ensure_adapter_supervisor do
    if Process.whereis(AdapterSupervisor) == nil do
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: AdapterSupervisor})
    end

    :ok
  end
end
