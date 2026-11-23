defmodule LawnBot.ApplicationTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  setup do
    previous_gateways = Elixir.Application.get_env(:lawn_bot, :gateways)
    Elixir.Application.delete_env(:lawn_bot, :gateways)

    on_exit(fn ->
      stop_application()
      restore_gateways(previous_gateways)
    end)

    :ok
  end

  test "refuses to start without gateways" do
    assert {:error, :no_gateways_configured} = LawnBot.Application.start(:normal, [])
  end

  test "refuses to start with a non-list gateways value" do
    Elixir.Application.put_env(:lawn_bot, :gateways, %{})

    assert {:error, :no_gateways_configured} = LawnBot.Application.start(:normal, [])
  end

  test "refuses to start with an empty gateways list" do
    Elixir.Application.put_env(:lawn_bot, :gateways, [])

    assert {:error, :no_gateways_configured} = LawnBot.Application.start(:normal, [])
  end

  test "starts the shared infrastructure without adapters" do
    Elixir.Application.put_env(:lawn_bot, :gateways, qq: [])

    assert {:ok, supervisor} = LawnBot.Application.start(:normal, [])
    assert supervisor == Process.whereis(LawnBot.Supervisor)
    assert is_pid(Process.whereis(LawnBot.AdapterRegistry))
    assert is_pid(Process.whereis(LawnBot.Finch))
    assert is_pid(Process.whereis(LawnBot.AdapterSupervisor))
    assert :ets.whereis(:auth_tokens) != :undefined
    assert %{active: 0} = DynamicSupervisor.count_children(LawnBot.AdapterSupervisor)

    assert :ok = Supervisor.stop(supervisor)
  end

  test "skips malformed gateway entries" do
    Elixir.Application.put_env(:lawn_bot, :gateways, ["not-a-gateway", qq: []])

    assert {:ok, supervisor} = LawnBot.Application.start(:normal, [])
    assert %{active: 0} = DynamicSupervisor.count_children(LawnBot.AdapterSupervisor)

    assert :ok = Supervisor.stop(supervisor)
  end

  defp stop_application do
    case Process.whereis(LawnBot.Supervisor) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  defp restore_gateways(nil), do: Elixir.Application.delete_env(:lawn_bot, :gateways)

  defp restore_gateways(gateways), do: Elixir.Application.put_env(:lawn_bot, :gateways, gateways)
end
