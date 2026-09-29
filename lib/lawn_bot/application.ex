defmodule LawnBot.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, name: LawnBot.AdapterRegistry, keys: :unique},
      LawnBot.AdapterSupervisor
    ]

    with gateways when is_map(gateways) and map_size(gateways) > 0 <-
           Application.get_env(:lawn_bot, :gateways),
         {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: LawnBot.Supervisor) do
      Enum.each(gateways, &start_adapters/1)
      {:ok, pid}
    else
      {:error, _reason} ->
        Logger.error("Failed to start LawnBot application supervisor.")
        {:error, :cannot_start_supervisor}

      _ ->
        Logger.error("No gateways configured for LawnBot. Please check your configuration.")
        {:error, :no_gateways_configured}
    end
  end

  defp start_adapters({platform, configs}) when is_list(configs),
    do: Enum.each(configs, &LawnBot.AdapterSupervisor.start_adapter(platform, &1))
end
