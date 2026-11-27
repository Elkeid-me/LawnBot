defmodule LawnBot.Adapters.Lark.BaseCoordinator do
  @moduledoc """
  Generates a platform-specific coordinator.

  API URLs and the worker module are compile-time constants. No adapter or URL
  strings are threaded through the GenServer state at runtime.
  """

  defmacro __using__(opts) do
    accounts_url = Keyword.fetch!(opts, :accounts_url)
    open_api_url = Keyword.fetch!(opts, :open_api_url)
    label = Keyword.fetch!(opts, :label)
    worker = Macro.expand(Keyword.fetch!(opts, :worker), __CALLER__)

    token_url = "#{accounts_url}/oauth/v3/token"
    ws_endpoint_url = "#{open_api_url}/callback/ws/endpoint"

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [
            label: label,
            worker: worker,
            token_url: token_url,
            ws_endpoint_url: ws_endpoint_url
          ] do
      use GenServer

      alias LawnBot.Adapters.Lark.API
      alias LawnBot.Adapters.Lark.Utils
      alias LawnBot.TokenStore

      require Logger

      @label label
      @worker_module worker
      @token_url token_url
      @ws_endpoint_url ws_endpoint_url
      @token_refresh_margin 60

      @type state() :: %{
              name: atom(),
              workers: pos_integer(),
              attempt_number: non_neg_integer(),
              refresh_ref: reference() | nil
            }

      @spec start_link({atom(), pos_integer()}) :: GenServer.on_start()
      def start_link({name, workers}) do
        GenServer.start_link(__MODULE__, {name, workers}, name: via_tuple(name))
      end

      @spec via_tuple(atom()) :: {:via, Registry, {module(), term()}}
      def via_tuple(name), do: Utils.coordinator_via_tuple(__MODULE__, name)

      @impl GenServer
      @spec init({atom(), pos_integer()}) :: {:ok, state(), {:continue, :bootstrap}}
      def init({name, workers}) do
        {:ok,
         %{
           name: name,
           workers: workers,
           attempt_number: 0,
           refresh_ref: nil
         }, {:continue, :bootstrap}}
      end

      @impl GenServer
      def handle_continue(:bootstrap, state), do: bootstrap(state)

      @impl GenServer
      def handle_info(:bootstrap, state), do: bootstrap(state)
      def handle_info(:refresh_token, state), do: refresh_token(state)
      def handle_info(_message, state), do: {:noreply, state}

      defp bootstrap(state) do
        %{name: name, workers: workers} = state

        case API.fetch_tenant_token(@token_url, name) do
          {:ok, auth} ->
            TokenStore.put(name, auth.access_token)

            case start_workers(name, workers) do
              :ok ->
                state = schedule_token_refresh(%{state | attempt_number: 0}, auth.expires_in)
                {:noreply, state, :hibernate}

              {:error, error} ->
                log_failure("Failed to start workers for", name, error)
                retry_bootstrap(state)
            end

          {:error, error} ->
            log_failure("Failed to bootstrap", name, error)
            retry_bootstrap(state)
        end
      end

      defp retry_bootstrap(state) do
        state = %{state | attempt_number: state.attempt_number + 1}
        Process.send_after(self(), :bootstrap, LawnBot.Utils.exp_backoff(state.attempt_number))
        {:noreply, state}
      end

      defp refresh_token(state) do
        %{name: name} = state

        case API.fetch_tenant_token(@token_url, name) do
          {:ok, auth} ->
            Logger.info("Refreshed token for #{Utils.bot_name(@label, name)}")
            TokenStore.put(name, auth.access_token)

            {:noreply, schedule_token_refresh(%{state | attempt_number: 0}, auth.expires_in)}

          {:error, error} ->
            log_failure("Failed to refresh token for", name, error)
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

      defp start_workers(name, workers) do
        Enum.reduce_while(1..workers, :ok, fn index, :ok ->
          with {:ok, endpoint} <- API.fetch_ws_endpoint(@ws_endpoint_url, name),
               :ok <- start_worker(name, index, endpoint) do
            {:cont, :ok}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
      end

      defp start_worker(name, index, endpoint) do
        worker_state =
          struct(@worker_module,
            name: name,
            index: index,
            url: endpoint.url,
            service_id: endpoint.service_id,
            ping_interval: endpoint.ping_interval
          )

        case DynamicSupervisor.start_child(
               Utils.worker_supervisor_via_tuple(@worker_module, name),
               {@worker_module, worker_state}
             ) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Failed to start #{Utils.worker_name(@label, name, index)}: #{inspect(reason)}"
            )

            {:error, reason}
        end
      end

      defp log_failure(prefix, name, error) do
        bot_name = Utils.bot_name(@label, name)

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
  end
end
