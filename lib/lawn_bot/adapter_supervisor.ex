defmodule LawnBot.AdapterSupervisor do
  @moduledoc """
  管理所有平台适配器的动态监督器。

  平台通过 `:gateways` 配置中的键映射到适配器模块；目前支持 `:qq`。
  """

  use DynamicSupervisor

  require Logger

  @adapter_mapping %{
    qq: LawnBot.Adapters.QQ,
    lark: LawnBot.Adapters.Lark,
    feishu: LawnBot.Adapters.Feishu
  }

  def start_link(init_arg) do
    Logger.info("Starting AdapterSupervisor")
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_adapter(:qq | :lark | :feishu, keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, :validation_failed | :not_implemented}
  def start_adapter(platform, options) do
    case adapter_child_spec(platform, options) do
      {:ok, spec} ->
        DynamicSupervisor.start_child(__MODULE__, spec)

      {:error, %NimbleOptions.ValidationError{} = err} ->
        Logger.error("Failed to start adapter for platform #{platform}: #{Exception.message(err)}.")
        {:error, :validation_failed}

      {:error, :not_implemented} ->
        Logger.error("Cannot find adapter for platform: #{platform}.")
        {:error, :not_implemented}
    end
  end

  @spec adapter_child_spec(:qq | :lark | :feishu, keyword()) ::
          {:ok, {module(), keyword()}}
          | {:error, NimbleOptions.ValidationError.t() | :not_implemented}
  for {key, target_module} <- @adapter_mapping do
    defp adapter_child_spec(unquote(key), options) do
      case apply(unquote(target_module), :validate_options, [options]) do
        {:ok, validated_options} -> {:ok, {unquote(target_module), validated_options}}
        {:error, exception} -> {:error, exception}
      end
    end
  end

  defp adapter_child_spec(_, _), do: {:error, :not_implemented}
end
