defmodule LawnBot.ApplicationTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.QQ

  setup do
    previous_gateways = Elixir.Application.get_env(:lawn_bot, :gateways)
    Elixir.Application.delete_env(:lawn_bot, :gateways)

    on_exit(fn ->
      if supervisor = Process.whereis(LawnBot.Supervisor) do
        if Process.whereis(LawnBot.AdapterSupervisor) do
          Supervisor.terminate_child(supervisor, LawnBot.AdapterSupervisor)
        end

        Supervisor.stop(supervisor)
      end

      if previous_gateways do
        Elixir.Application.put_env(:lawn_bot, :gateways, previous_gateways)
      else
        Elixir.Application.delete_env(:lawn_bot, :gateways)
      end
    end)
  end

  test "refuses to start without gateways" do
    assert {:error, :no_gateways_configured} = LawnBot.Application.start(:normal, [])
  end

  test "starts multiple QQ bots under independent adapter supervisors" do
    gateways = %{
      qq: [
        %{app_id: "app-1", client_secret: "secret-1", name: :TestBot1, handler: {:func, & &1}},
        %{app_id: "app-2", client_secret: "secret-2", name: :TestBot2, handler: {:func, & &1}},
        %{app_id: "app-3", client_secret: "secret-3", name: :TestBot3, handler: {:func, & &1}}
      ]
    }

    Elixir.Application.put_env(:lawn_bot, :gateways, gateways)
    assert {:ok, supervisor} = LawnBot.Application.start(:normal, [])

    assert [{pid_1, _value}] =
             Registry.lookup(LawnBot.AdapterRegistry, {QQ, :TestBot1})

    assert [{pid_2, _value}] =
             Registry.lookup(LawnBot.AdapterRegistry, {QQ, :TestBot2})

    assert [{pid_3, _value}] =
             Registry.lookup(LawnBot.AdapterRegistry, {QQ, :TestBot3})

    assert pid_1 != pid_2
    assert pid_1 != pid_3
    assert pid_2 != pid_3

    Supervisor.terminate_child(LawnBot.Supervisor, LawnBot.AdapterSupervisor)
    Supervisor.stop(supervisor)
  end
end
