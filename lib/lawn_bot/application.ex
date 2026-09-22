defmodule LawnBot.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, name: LawnBot.AdapterRegistry, keys: :unique},
      LawnBot.AdapterSupervisor,
      # {Registry, name: LawnBot.SessionRegistry, keys: :unique},
      # {DynamicSupervisor, name: LawnBot.SessionSupervisor, strategy: :one_for_one}
    ]

    Logger.info("Starting LawnBot")
    opts = [strategy: :one_for_one, name: LawnBot.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    gateways = Application.get_env(:lawn_bot, :gateways, %{})

    Enum.each(gateways, fn {platform, configs} ->
      Enum.each(configs, fn config ->
        LawnBot.AdapterSupervisor.start_adapter(platform, config)
      end)
    end)

    {:ok, pid}
  end
end
