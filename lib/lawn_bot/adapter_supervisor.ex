defmodule LawnBot.AdapterSupervisor do
  @moduledoc """
  The `DynamicSupervisor` that manages all the adapter processes.

  It is responsible for checking wether the platform is supported, starting adapter processes, and
  ensuring that they are supervised properly.

  If you want to add a new adapter, you need to add it to the `@adapter_mapping` in this module. For
  example:

  ```elixir
  @adapter_mapping %{
    qq: LawnBot.Adapters.QQ,
    lark: LawnBot.Adapters.Lark,
    feishu: LawnBot.Adapters.Feishu
  }
  ```
  """

  use DynamicSupervisor

  require Logger

  @adapter_mapping %{
    qq: LawnBot.Adapters.QQ,
    lark: LawnBot.Adapters.Lark,
    feishu: LawnBot.Adapters.Feishu
  }

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(args) do
    Logger.info("Starting AdapterSupervisor")
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl DynamicSupervisor
  @spec init(term()) :: {:ok, DynamicSupervisor.sup_flags()} | :ignore
  def init(_args), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Starts an adapter process for the given platform with the given options. If the platform is not
  supported or the options are invalid, it will return an error.
  """
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

  # Check wether the given adapter platform is supported and options are valid.
  #
  # Returns the child specification for the given adapter platform and options,
  # or an error if the platform is not supported or the options are invalid.
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
