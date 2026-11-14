defmodule LawnBot.Adapters.QQ.Coordinator do
  @moduledoc """
  A GenServer that coordinates the lifecycle of a QQ bot, including authentication and gateway management.
  """

  use GenServer

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ
  alias LawnBot.Adapters.QQ.Utils
  alias LawnBot.TokenStore

  require Logger

  @bootstrap_retry 5_000
  @token_refresh_retry 60_000
  @token_refresh_margin 30

  @token_url "https://api.bot.qq.com/app/getAppAccessToken"
  @gateway_url "https://api.bot.qq.com/gateway/bot"

  @type state() :: %{name: atom(), refresh_ref: reference() | nil}

  @spec start_link(atom()) :: {:ok, pid()} | {:error, term()}
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via_tuple(name))

  @impl GenServer
  @spec init(atom()) :: {:ok, state(), {:continue, :bootstrap}}
  def init(name) do
    state = %{name: name, refresh_ref: nil}
    {:ok, state, {:continue, :bootstrap}}
  end

  @doc "Coordinator 进程在 Registry 中的名字。"
  @spec via_tuple(module()) :: {:via, Registry, {LawnBot.AdapterRegistry, {Coordinator, module()}}}
  def via_tuple(name), do: {:via, Registry, {LawnBot.AdapterRegistry, {Coordinator, name}}}

  @doc "异步启动 Coordinator 进程，避免阻塞 QQ 适配器监督树的启动。"
  @impl GenServer
  @spec handle_continue(:bootstrap, state()) :: {:noreply, state()}
  def handle_continue(:bootstrap, state), do: bootstrap(state)

  @impl GenServer
  @spec handle_info(:refresh_token | term(), state()) :: {:noreply, state()}
  def handle_info(:refresh_token, state) do
    name = state.name

    case fetch_auth(state) do
      {:ok, auth} ->
        Logger.info("Refreshed token for #{QQ.bot_name(name)}")
        TokenStore.put(name, auth.access_token)
        {:noreply, schedule_token_refresh(state, auth.expires_in)}

      {:error, error} ->
        log_failure("Failed to refresh token for", name, error)
        timer = Process.send_after(self(), :refresh_token, @token_refresh_retry)
        {:noreply, %{state | refresh_ref: timer}}
    end
  end

  # 重试启动
  def handle_info(:bootstrap, state), do: bootstrap(state)
  def handle_info(_message, state), do: {:noreply, state}

  # 获取机器人 `access_token` 与刷新时间.
  @spec fetch_auth(state()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}}
          | {:error, {:invalid_field_type, String.t()}}
          | Utils.api_call_error()
  defp fetch_auth(state) do
    app_id = PersistentTerm.get({state.name, :app_id})
    client_secret = PersistentTerm.get({state.name, :client_secret})
    auth_body = %{"appId" => app_id, "clientSecret" => client_secret}

    case Req.post(@token_url, json: auth_body, finch: [name: LawnBot.Finch, pool_tag: state.name]) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"access_token" => access_token, "expires_in" => expires_in}
       }} ->
        with {:ok, access_token} <- LawnBot.Utils.check_empty_string(access_token),
             {:ok, expires_in} <- LawnBot.Utils.check_pos_int(expires_in) do
          access_token = token(access_token)
          {:ok, %{access_token: access_token, expires_in: expires_in}}
        else
          {:error, message} ->
            {:error, {:invalid_field_type, message}}
        end

      error ->
        Utils.check_api_call_error(error)
    end
  end

  # 获取网关地址与建议分片数。
  @spec fetch_gateway(String.t(), state()) ::
          {:ok, %{url: String.t(), max_concurrency: pos_integer()}}
          | {:error, {:invalid_field_type, String.t()}}
          | Utils.api_call_error()
  defp fetch_gateway(access_token, state) do
    headers = %{"authorization" => access_token}

    case Req.get(@gateway_url, headers: headers, finch: [name: LawnBot.Finch, pool_tag: state.name]) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "url" => url,
           "session_start_limit" => %{
             "max_concurrency" => max_concurrency,
             "remaining" => remaining
           }
         }
       }}
      when is_binary(url) ->
        with {:ok, max_concurrency} <- LawnBot.Utils.check_pos_int(max_concurrency),
             {:ok, remaining} <- LawnBot.Utils.check_non_neg_int(remaining) do
          shards = PersistentTerm.get({state.name, :shards})

          if remaining < shards,
            do: Logger.warning("Available sessions (#{remaining}) is lower than shards=#{shards}.")

          gateway = %{url: url, max_concurrency: max_concurrency}
          {:ok, gateway}
        else
          {:error, message} ->
            {:error, {:invalid_gateway_response, message}}
        end

      error ->
        Utils.check_api_call_error(error)
    end
  end

  @spec bootstrap(state()) :: {:noreply, state()} | {:noreply, state(), :hibernate}
  defp bootstrap(state) do
    name = state.name

    with {:ok, auth} <- fetch_auth(state),
         {:ok, gateway} <- fetch_gateway(auth.access_token, state) do
      %{url: url, max_concurrency: max_concurrency} = gateway
      TokenStore.put(name, auth.access_token)
      PersistentTerm.put({name, :gateway_url}, url)
      PersistentTerm.put({name, :max_concurrency}, max_concurrency)
      state = schedule_token_refresh(state, auth.expires_in)
      start_shards(state)
      {:noreply, state, :hibernate}
    else
      {:error, error} ->
        log_failure("Failed to bootstrap", name, error)
        Process.send_after(self(), :bootstrap, @bootstrap_retry)
        {:noreply, state}
    end
  end

  @spec start_shards(state()) :: :ok
  defp start_shards(%{name: name}) do
    shards = PersistentTerm.get({name, :shards})

    started =
      0..(shards - 1)
      |> Stream.map(fn shard_id -> start_shard(name, shard_id) end)
      |> Enum.count(&is_pid/1)

    Logger.info("#{QQ.bot_name(name)} started #{started}/#{shards} shard(s)")
  end

  @spec start_shard(atom(), non_neg_integer()) :: pid() | nil
  defp start_shard(name, shard_id) do
    shard_state = %QQ.Shard{
      name: name,
      shard_id: shard_id
    }

    case DynamicSupervisor.start_child(QQ.shard_supervisor_via_tuple(name), {QQ.Shard, shard_state}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Logger.error("Failed to start #{QQ.bot_name(name)} shard #{shard_id}: #{inspect(reason)}")
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

    # `expires_in` 是 token 的剩余有效期（有效期内重复获取返回同一个 token），
    # 不是固定 7200 秒。刷新点取「剩余 30 秒」：若贴着 60 秒窗口边界刷新，
    # 稍有偏差就会拿回旧 token（expires_in≈60），再被下面的 1 秒下限立即重试，
    # 表现就是两次刷新相隔约 1 秒。
    delay = max((expires_in - @token_refresh_margin) * 1_000, 1_000)
    %{state | refresh_ref: Process.send_after(self(), :refresh_token, delay)}
  end

  @spec log_failure(String.t(), atom(), term()) :: :ok
  defp log_failure(prefix, name, error) do
    case error do
      {:qq_api, http_status, code, message} ->
        Logger.error("#{prefix} #{QQ.bot_name(name)}: HTTP #{http_status}, #{code}, #{message}")

      {:unexpected_response, http_status, response} ->
        Logger.error("#{prefix} #{QQ.bot_name(name)}: HTTP #{http_status}, #{inspect(response)}")

      {:invalid_field_type, message} ->
        Logger.error("#{prefix} #{QQ.bot_name(name)}: invalid_field_type: #{message}")

      message ->
        Logger.error("#{prefix} #{QQ.bot_name(name)}: #{message}")
    end
  end

  # 构造机器人 token。形如 `QQBot <access_token>`。
  @spec token(String.t()) :: String.t()
  defp token(access_token), do: "QQBot #{access_token}"
end
