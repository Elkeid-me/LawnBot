defmodule LawnBot.Adapters.Lark.Utils do
  @moduledoc false

  @spec bot_name(String.t(), atom()) :: String.t()
  def bot_name(label, name), do: "#{label} Bot: #{name}"

  @spec worker_name(String.t(), atom(), pos_integer()) :: String.t()
  def worker_name(label, name, index), do: "#{bot_name(label, name)} worker #{index}"

  @spec supervisor_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def supervisor_via_tuple(module, name), do: via_tuple(module, name)

  @spec coordinator_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def coordinator_via_tuple(module, name), do: via_tuple(module, name)

  @spec worker_via_tuple(module(), atom(), pos_integer()) :: {:via, Registry, {module(), term()}}
  def worker_via_tuple(module, name, index), do: via_tuple(module, {name, index})

  @spec task_supervisor_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def task_supervisor_via_tuple(module, name), do: via_tuple(module, name)

  @spec worker_supervisor_via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def worker_supervisor_via_tuple(module, name), do: via_tuple(module, name)

  defp via_tuple(module, key) do
    {:via, Registry, {LawnBot.AdapterRegistry, {module, key}}}
  end
end
