defmodule LawnBot.Application do
  @moduledoc false
  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, name: LawnBot.AdapterRegistry, keys: :unique},
      {Finch, name: LawnBot.Finch},
      LawnBot.AdapterSupervisor
    ]

    LawnBot.TokenStore.new()

    with gateways when is_list(gateways) and gateways != [] <-
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

  defp start_adapters({platform, configs})
       when is_atom(platform) and is_list(configs) and configs != [],
       do: Enum.each(configs, &LawnBot.AdapterSupervisor.start_adapter(platform, &1))

  defp start_adapters(_), do: :ok
end
