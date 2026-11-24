defmodule LawnBot.Adapters.Lark.BaseCoordinator do
  @moduledoc """
  Bootstraps a Lark/Feishu bot: obtains the tenant access token, then requests
  one WebSocket endpoint per configured connection and starts the workers.

  Lark/Feishu long connections are clustered: with multiple connections, each
  event is delivered to one randomly selected connection. There is no sharding
  or local event routing.
  """

  use GenServer

  alias LawnBot.Adapters.Lark.Api
  alias LawnBot.Adapters.Lark.BaseWorker
  alias LawnBot.Adapters.Lark.Utils
  alias LawnBot.TokenStore

  require Logger

  @token_refresh_margin 60

  @type state() :: %{
          adapter: module(),
          name: atom(),
          connections: pos_integer(),
          attempt_number: non_neg_integer(),
          refresh_ref: reference() | nil
        }

  @spec start_link({module(), atom()} | {module(), atom(), pos_integer()}) ::
          GenServer.on_start()
  def start_link({adapter, name}), do: start_link({adapter, name, 1})

  def start_link({adapter, name, connections}) do
    GenServer.start_link(
      __MODULE__,
      {adapter, name, connections},
      name: via_tuple(adapter, name)
    )
  end

  @spec via_tuple(module(), atom()) :: {:via, Registry, {module(), term()}}
  def via_tuple(adapter, name), do: Utils.coordinator_via_tuple(adapter, name)

  @impl GenServer
  @spec init({module(), atom()} | {module(), atom(), pos_integer()}) ::
          {:ok, state(), {:continue, :bootstrap}}
  def init({adapter, name}), do: init({adapter, name, 1})

  def init({adapter, name, connections}) do
    {:ok,
     %{
       adapter: adapter,
       name: name,
       connections: connections,
       attempt_number: 0,
       refresh_ref: nil
     }, {:continue, :bootstrap}}
  end

  @impl GenServer
  def handle_continue(:bootstrap, state), do: bootstrap(state)
  def handle_continue(_continue, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:bootstrap, state), do: bootstrap(state)
  def handle_info(:refresh_token, state), do: refresh_token(state)
  def handle_info(_message, state), do: {:noreply, state}

  defp bootstrap(state) do
    %{adapter: adapter, name: name, connections: connections} = state

    case Api.fetch_tenant_token(adapter, name) do
      {:ok, auth} ->
        TokenStore.put(name, auth.access_token)

        case start_workers(adapter, name, connections) do
          :ok ->
            state = schedule_token_refresh(%{state | attempt_number: 0}, auth.expires_in)
            {:noreply, state, :hibernate}

          {:error, error} ->
            log_failure("Failed to start connections for", adapter, name, error)
            retry_bootstrap(state)
        end

      {:error, error} ->
        log_failure("Failed to bootstrap", adapter, name, error)
        retry_bootstrap(state)
    end
  end

  defp retry_bootstrap(state) do
    state = %{state | attempt_number: state.attempt_number + 1}
    Process.send_after(self(), :bootstrap, LawnBot.Utils.exp_backoff(state.attempt_number))
    {:noreply, state}
  end

  defp refresh_token(state) do
    %{adapter: adapter, name: name} = state

    case Api.fetch_tenant_token(adapter, name) do
      {:ok, auth} ->
        Logger.info("Refreshed token for #{Utils.bot_name(adapter, name)}")
        TokenStore.put(name, auth.access_token)

        {:noreply, schedule_token_refresh(%{state | attempt_number: 0}, auth.expires_in)}

      {:error, error} ->
        log_failure("Failed to refresh token for", adapter, name, error)
        state = %{state | attempt_number: state.attempt_number + 1}
        delay = LawnBot.Utils.exp_backoff(state.attempt_number)
        timer = Process.send_after(self(), :refresh_token, delay)
        {:noreply, %{state | refresh_ref: timer}}
    end
  end

  defp schedule_token_refresh(state, expires_in) do
    state =
      case state.refresh_ref do
        nil ->
          state

        ref ->
          Process.cancel_timer(ref)
          %{state | refresh_ref: nil}
      end

    delay = max((expires_in - @token_refresh_margin) * 1_000, 1_000)
    %{state | refresh_ref: Process.send_after(self(), :refresh_token, delay)}
  end

  defp start_workers(adapter, name, connections) do
    Enum.reduce_while(1..connections, :ok, fn index, :ok ->
      with {:ok, endpoint} <- Api.fetch_ws_endpoint(adapter, name),
           :ok <- start_worker(adapter, name, index, endpoint) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp start_worker(adapter, name, index, endpoint) do
    worker_state = %BaseWorker{
      adapter: adapter,
      name: name,
      index: index,
      url: endpoint.url,
      service_id: endpoint.service_id,
      ping_interval: endpoint.ping_interval
    }

    case DynamicSupervisor.start_child(
           Utils.worker_supervisor_via_tuple(adapter, name),
           {BaseWorker, worker_state}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to start #{Utils.connection_name(adapter, name, index)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp log_failure(prefix, adapter, name, error) do
    bot_name = Utils.bot_name(adapter, name)

    case error do
      {:lark_api, http_status, code, message} ->
        Logger.error("#{prefix} #{bot_name}: HTTP #{http_status}, #{inspect(code)}, #{message}")

      {:unexpected_response, http_status, response} ->
        Logger.error("#{prefix} #{bot_name}: HTTP #{http_status}, #{inspect(response)}")

      {:invalid_field_type, message} ->
        Logger.error("#{prefix} #{bot_name}: invalid_field_type: #{message}")

      message when is_binary(message) ->
        Logger.error("#{prefix} #{bot_name}: #{message}")

      other ->
        Logger.error("#{prefix} #{bot_name}: #{inspect(other)}")
    end
  end
end
