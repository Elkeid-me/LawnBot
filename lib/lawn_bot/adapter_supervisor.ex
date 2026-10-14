defmodule LawnBot.AdapterSupervisor do
  @moduledoc """
  管理所有平台适配器的动态监督器。

  平台通过 `:gateways` 配置中的键映射到适配器模块；目前支持 `:qq`。
  """

  use DynamicSupervisor

  require Logger

  @adapter_mapping %{qq: LawnBot.Adapters.QQ}

  def start_link(init_arg) do
    Logger.info("Starting AdapterSupervisor")
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "按平台键启动适配器；未知平台返回 `{:error, :not_implemented}`。"
  @spec start_adapter(:qq | :lark | atom(), map()) ::
          :ignore | {:error, any()} | {:ok, pid()} | {:ok, pid(), any()}
  def start_adapter(platform, config) do
    case adapter_child_spec(platform, config) do
      {:ok, spec} ->
        DynamicSupervisor.start_child(__MODULE__, spec)

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
