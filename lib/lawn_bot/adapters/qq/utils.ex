defmodule LawnBot.Adapters.QQ.Utils do
  @moduledoc false
  @type api_call_error() ::
          {:error, {:qq_api, integer(), integer(), String.t()}}
          | {:error, {:unexpected_response, integer(), term()}}
          | {:error, String.t()}

  @spec check_api_call_error({:ok, Req.Response.t()} | {:error, Exception.t()}) :: api_call_error()
  def check_api_call_error(response) do
    case response do
      {:ok, %Req.Response{status: http_status, body: %{"err_code" => code, "message" => message}}} ->
        {:error, {:qq_api, http_status, code, message}}

      {:ok, %Req.Response{status: http_status, body: %{"code" => code, "message" => message}}} ->
        {:error, {:qq_api, http_status, code, message}}

      {:ok, %Req.Response{status: http_status, body: response}} ->
        {:error, {:unexpected_response, http_status, response}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  @doc "Name of the bot, used in logs and error messages."
  @spec bot_name(atom()) :: String.t()
  def bot_name(name), do: "QQ Bot: #{name}"

  @spec shard_supervisor_via_tuple(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def shard_supervisor_via_tuple(name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, name}}}

  @spec task_supervisor_via_tuple(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def task_supervisor_via_tuple(name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, name}}}
end
