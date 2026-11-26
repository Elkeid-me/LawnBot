defmodule LawnBot.Adapters.QQ.Coordinator do
  @moduledoc """
  A GenServer that coordinates the lifecycle of a QQ bot, including authentication and gateway management.
  """

  use GenServer

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ
  alias LawnBot.Adapters.QQ.API
  alias LawnBot.Adapters.QQ.Utils
  alias LawnBot.TokenStore

  require Logger

  @token_refresh_margin 30

  @type state() :: %{
          name: atom(),
          attempt_number: non_neg_integer(),
          refresh_ref: reference() | nil
        }

  @spec start_link(atom()) :: {:ok, pid()} | {:error, term()}
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via_tuple(name))

  @impl GenServer
  @spec init(atom()) :: {:ok, state(), {:continue, :bootstrap}}
  def init(name) do
    state = %{name: name, attempt_number: 0, refresh_ref: nil}
    {:ok, state, {:continue, :bootstrap}}
  end

  @doc "Coordinator 进程在 Registry 中的名字。"
  @spec via_tuple(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, module()}}}
  def via_tuple(name), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, name}}}

  @doc "Launch coordinator asynchronously."
  @impl GenServer
  @spec handle_continue(:bootstrap, state()) :: {:noreply, state()}
  def handle_continue(:bootstrap, state), do: bootstrap(state)

  @impl GenServer
  @spec handle_info(:refresh_token | term(), state()) :: {:noreply, state()}
  def handle_info(:refresh_token, state) do
    name = state.name

    case fetch_auth(state) do
      {:ok, auth} ->
        Logger.info("Refreshed token for #{Utils.bot_name(name)}")
        TokenStore.put(name, auth.access_token)
        state = state |> schedule_token_refresh(auth.expires_in) |> Map.put(:attempt_number, 0)
        {:noreply, schedule_token_refresh(state, auth.expires_in)}

      {:error, error} ->
        log_failure("Failed to refresh token for", name, error)
        state = %{state | attempt_number: state.attempt_number + 1}
        delay = LawnBot.Utils.exp_backoff(state.attempt_number)
        timer = Process.send_after(self(), :refresh_token, delay)
        {:noreply, %{state | refresh_ref: timer}}
    end
  end

  # Retry bootstrap on failure.
  def handle_info(:bootstrap, state), do: bootstrap(state)
  def handle_info(_message, state), do: {:noreply, state}

  # Fetch the bot's access token and refresh time from the QQ API.
  @spec fetch_auth(state()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}}
          | {:error, {:invalid_field_type, String.t()}}
          | Utils.api_call_error()
  defp fetch_auth(state), do: API.fetch_access_token(state.name)

  # Fetch the gateway URL and recommended shard count.
  @spec fetch_gateway(String.t(), state()) ::
          {:ok, %{url: String.t(), max_concurrency: pos_integer(), remaining: non_neg_integer()}}
          | {:error, {:invalid_field_type, String.t()}}
          | Utils.api_call_error()
  defp fetch_gateway(access_token, state), do: API.fetch_gateway(state.name, access_token)

  @spec bootstrap(state()) :: {:noreply, state()} | {:noreply, state(), :hibernate}
  defp bootstrap(state) do
    name = state.name

    with {:ok, auth} <- fetch_auth(state),
         {:ok, gateway} <- fetch_gateway(auth.access_token, state) do
      %{url: url, max_concurrency: max_concurrency, remaining: remaining} = gateway
      workers = PersistentTerm.get({name, :workers})

      if remaining < workers,
        do: Logger.warning("Available sessions (#{remaining}) is lower than workers=#{workers}.")

      TokenStore.put(name, auth.access_token)
      PersistentTerm.put({name, :gateway_url}, url)
      PersistentTerm.put({name, :max_concurrency}, max_concurrency)
      state = state |> schedule_token_refresh(auth.expires_in) |> Map.put(:attempt_number, 0)
      start_workers(name)
      {:noreply, state, :hibernate}
    else
      {:error, error} ->
        log_failure("Failed to bootstrap", name, error)
        state = %{state | attempt_number: state.attempt_number + 1}
        delay = LawnBot.Utils.exp_backoff(state.attempt_number)
        Process.send_after(self(), :bootstrap, delay)
        {:noreply, state}
    end
  end

  @spec start_workers(atom()) :: :ok
  defp start_workers(name) do
    workers = PersistentTerm.get({name, :workers})

    started =
      0..(workers - 1)
      |> Stream.map(fn worker_id -> start_worker(name, worker_id) end)
      |> Enum.count(&is_pid/1)

    Logger.info("#{Utils.bot_name(name)} started #{started}/#{workers} worker(s)")
  end

  @spec start_worker(atom(), non_neg_integer()) :: pid() | nil
  defp start_worker(name, worker_id) do
    shard_state = %QQ.Shard{
      name: name,
      shard_id: worker_id
    }

    case DynamicSupervisor.start_child(
           Utils.shard_supervisor_via_tuple(name),
           {QQ.Shard, shard_state}
         ) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Logger.error(
          "Failed to start #{Utils.bot_name(name)} worker #{worker_id}: #{inspect(reason)}"
        )

        nil
    end
  end

  @spec schedule_token_refresh(state(), pos_integer()) :: state()
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

  @spec log_failure(String.t(), atom(), term()) :: :ok
  defp log_failure(prefix, name, error) do
    case error do
      {:qq_api, http_status, code, message} ->
        Logger.error("#{prefix} #{Utils.bot_name(name)}: HTTP #{http_status}, #{code}, #{message}")

      {:unexpected_response, http_status, response} ->
        Logger.error("#{prefix} #{Utils.bot_name(name)}: HTTP #{http_status}, #{inspect(response)}")

      {:invalid_field_type, message} ->
        Logger.error("#{prefix} #{Utils.bot_name(name)}: invalid_field_type: #{message}")

      message ->
        Logger.error("#{prefix} #{Utils.bot_name(name)}: #{message}")
    end
  end
end
