defmodule LawnBot.AdapterSupervisor do
  use DynamicSupervisor
  require Logger

  @doc """
  平台到适配器模块映射
  """
  @adapter_mapping %{qq: LawnBot.Adapters.QQ}

  def start_link(init_arg) do
    Logger.info("Starting AdapterSupervisor")
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_adapter(:qq | :lark | atom(), map()) ::
          :ignore | {:error, any()} | {:ok, pid()} | {:ok, pid(), any()}
  def start_adapter(platform, config) do
    with {:ok, spec} <- adapter_child_spec(platform, config) do
      DynamicSupervisor.start_child(__MODULE__, spec)
    else
      _ ->
        Logger.error("Cannot find adapter for platform: #{platform}.")
        {:error, :not_implemented}
    end
  end

  for {key, target_module} <- @adapter_mapping do
    defp adapter_child_spec(unquote(key), config), do: {:ok, {unquote(target_module), config}}
  end

  defp adapter_child_spec(_, _), do: {:error, :not_implemented}
end
