defmodule LawnBot.AdapterSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    Logger.info("Starting AdapterSupervisor")
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_adapter(:qq | :lark | atom(), map()) ::
          :ignore | {:error, any()} | {:ok, pid()} | {:ok, pid(), any()}
  def start_adapter(platform, config) do
    spec = adapter_child_spec(platform, config)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  defp adapter_child_spec(:qq, config), do: {LawnBot.Adapters.QQ, config}
end
