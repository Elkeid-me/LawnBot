defmodule LawnBot.Adapters.Lark.Utils do
  @moduledoc false

  @spec bot_name(module(), atom()) :: String.t()
  def bot_name(adapter, name), do: "#{adapter.label()} Bot: #{name}"

  @spec worker_name(module(), atom(), pos_integer()) :: String.t()
  def worker_name(adapter, name, index), do: "#{bot_name(adapter, name)} worker #{index}"

  @spec adapter_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def adapter_via_tuple(adapter, name), do: via_tuple(adapter, name)

  @spec coordinator_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def coordinator_via_tuple(adapter, name),
    do: via_tuple(LawnBot.Adapters.Lark.BaseCoordinator, {adapter, name})

  @spec worker_via_tuple(module(), atom(), pos_integer()) ::
          {:via, Registry, {module(), term()}}
  def worker_via_tuple(adapter, name, index \\ 1),
    do: via_tuple(LawnBot.Adapters.Lark.BaseWorker, {adapter, name, index})

  @spec task_supervisor_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def task_supervisor_via_tuple(adapter, name),
    do: via_tuple(LawnBot.Adapters.Lark.TaskSupervisor, {adapter, name})

  @spec worker_supervisor_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def worker_supervisor_via_tuple(adapter, name),
    do: via_tuple(LawnBot.Adapters.Lark.WorkerSupervisor, {adapter, name})

  defp via_tuple(module, key) do
    {:via, Registry, {LawnBot.AdapterRegistry, {module, key}}}
  end
end
