defmodule LawnBot.Adapters.QQ.Coordinator do
  @moduledoc """
  QQ 适配器的引导与维护进程。

  职责：

    * 获取 access_token，并在过期前定时刷新，结果写入 `TokenStore`；
    * 调用 `GET /gateway/bot` 获取网关地址与建议分片数；
    * 拿到 token 后在所属 DynamicSupervisor 下启动各分片连接进程。

  token 存放在本适配器私有的 ETS 表中，分片与发送任务在用到时才读取，
  因此刷新不需要广播，也不存在旧快照。

  本进程是 `LawnBot.Adapters.QQ`（Supervisor）的最后一个子进程，
  自身被监督树重启后会重新引导：已存在的分片会收到 `{:error, {:already_started, pid}}`
  而被跳过，它们会在下次使用 token 时读到新值。
  """

  use GenServer

  alias :ets, as: ETS
  alias LawnBot.Adapters.QQ
  alias LawnBot.Adapters.QQ.TokenStore

  require Logger

  @bootstrap_retry 5_000
  @token_refresh_retry 60_000

  # QQ 只在 token 剩余有效期不足 60 秒时才签发新 token；更早调用会原样返回旧 token，
  # 并把 expires_in 改成它的剩余时间。因此刷新点必须落在这 60 秒窗口内部。
  # 取中点 30 秒，给取整误差和网络延迟留出余量，同时保证旧 token 还有效，不会出现空窗。
  @token_refresh_margin 30

  @token_url "https://api.bot.qq.com/app/getAppAccessToken"
  @gateway_url "https://api.bot.qq.com/gateway/bot"
  @plain_gateway_url "https://api.bot.qq.com/gateway"
  @type gateway() :: %{
          url: String.t(),
          shards: pos_integer(),
          max_concurrency: pos_integer(),
          remaining: non_neg_integer() | nil
        }
  @type state() :: %{
          config: QQ.config(),
          token_table: ETS.tid(),
          gateway: gateway() | nil,
          refresh_ref: reference() | nil
        }

  @spec start_link({QQ.config(), ETS.tid()}) :: {:ok, pid()} | {:error, term()}
  def start_link({config, tid}),
    do: GenServer.start_link(__MODULE__, {config, tid}, name: QQ.coordinator_name(config.name))

  @impl true
  @spec init({QQ.config(), ETS.tid()}) :: {:ok, state(), {:continue, :bootstrap}}
  def init({config, tid}) do
    state = %{config: config, token_table: tid, gateway: nil, refresh_ref: nil}
    {:ok, state, {:continue, :bootstrap}}
  end

  @doc "异步启动 Coordinator 进程，避免阻塞 QQ 适配器监督树的启动。"
  @impl true
  @spec handle_continue(:bootstrap | :bootstrap, state()) :: {:noreply, state()}
  def handle_continue(:bootstrap, state), do: bootstrap(state)

  @impl true
  @spec handle_info(:refresh_token | term(), state()) :: {:noreply, state()}
  def handle_info(:refresh_token, state) do
    config = state.config
    %{app_id: app_id, client_secret: client_secret, name: name} = config

    case fetch_access_token(app_id, client_secret, name) do
      {:ok, token} ->
        Logger.info("Refreshed token for #{QQ.bot_name(config)}")
        TokenStore.put(state.token_table, token.access_token)
        {:noreply, schedule_token_refresh(state, token.expires_in)}

      {:error, reason} ->
        log_failure("Failed to refresh token for", reason, config)

        {:noreply,
         %{state | refresh_ref: Process.send_after(self(), :refresh_token, @token_refresh_retry)}}
    end
  end

  # 重试启动
  def handle_info(:bootstrap, state), do: bootstrap(state)
  def handle_info(_message, state), do: {:noreply, state}

  # 获取机器人 `access_token` 与 token 刷新时间。
  @spec fetch_access_token(String.t(), String.t(), module()) :: {:ok, QQ.token()} | {:error, term()}
  defp fetch_access_token(app_id, client_secret, name) do
    case Req.post(@token_url,
           json: %{"appId" => app_id, "clientSecret" => client_secret},
           finch: [name: LawnBot.Finch, pool_tag: name]
         ) do
      {:ok, %Req.Response{body: %{"access_token" => access_token, "expires_in" => expires_in}}}
      when is_binary(access_token) ->
        case positive_int(expires_in) do
          {:ok, expires_in} -> {:ok, %{access_token: token(access_token), expires_in: expires_in}}
          :error -> {:error, {:invalid_expires_in, expires_in}}
        end

      {:ok, %Req.Response{body: %{"code" => code, "message" => message}}} ->
        {:error, {:qq_api, code, message}}

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # 获取网关地址与建议分片数。
  @spec fetch_gateway(String.t(), QQ.config()) :: {:ok, gateway()} | {:error, term()}
  defp fetch_gateway(access_token, config) do
    headers = %{"Authorization" => access_token}

    case Req.get(@gateway_url,
           headers: headers,
           finch: [name: LawnBot.Finch, pool_tag: config.name]
         ) do
      {:ok, %Req.Response{body: %{"url" => url} = body}} when is_binary(url) ->
        {:ok, parse_gateway(url, body, config)}

      _ ->
        case Req.get(@plain_gateway_url,
               headers: headers,
               finch: [name: LawnBot.Finch, pool_tag: config.name]
             ) do
          {:ok, %Req.Response{body: %{"url" => url} = body}} when is_binary(url) ->
            {:ok, parse_gateway(url, body, config)}

          {:ok, %Req.Response{body: %{"code" => code, "message" => message}}} ->
            {:error, {:qq_api, code, message}}

          {:ok, response} ->
            {:error, {:unexpected_response, response}}

          {:error, exception} ->
            {:error, exception}
        end
    end
  end

  @spec bootstrap(state()) :: {:noreply, state()}
  defp bootstrap(state) do
    config = state.config
    %{app_id: app_id, client_secret: client_secret, name: name} = config

    with {:ok, token} <- fetch_access_token(app_id, client_secret, name),
         %{access_token: access_token} = token,
         {:ok, gateway} <- fetch_gateway(access_token, config) do
      %{shards: shards, remaining: remaining} = gateway
      warn_on_session_limit(remaining, shards)
      state = %{state | gateway: gateway}
      TokenStore.put(state.token_table, token.access_token)
      state = schedule_token_refresh(state, token.expires_in)
      start_shards(state)
      {:noreply, state}
    else
      {:error, reason} ->
        log_failure("Failed to bootstrap", reason, config)
        Process.send_after(self(), :bootstrap, @bootstrap_retry)
        {:noreply, state}
    end
  end

  @spec parse_gateway(String.t(), map(), QQ.config()) :: gateway()
  defp parse_gateway(url, body, config) do
    limit = Map.get(body, "session_start_limit") || %{}
    shards = positive_int(Map.get(config, :shards) || Map.get(body, "shards"), 1)

    %{
      url: url,
      shards: shards,
      max_concurrency: positive_int(Map.get(limit, "max_concurrency"), 1),
      remaining: non_negative_int(Map.get(limit, "remaining"))
    }
  end

  # QQ 平台返回的整数字段可能是字符串，且可能缺失或为负数。这里做统一解析。
  @spec positive_int(integer() | String.t()) :: {:ok, pos_integer()} | :error
  defp positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp positive_int(_value), do: :error

  @spec positive_int(integer() | String.t(), pos_integer()) :: pos_integer()
  defp positive_int(value, default) do
    case positive_int(value) do
      {:ok, integer} -> integer
      :error -> default
    end
  end

  @spec non_negative_int(integer() | String.t()) :: non_neg_integer() | nil
  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_int(_value), do: nil

  @spec start_shards(state()) :: :ok
  defp start_shards(%{config: config, token_table: tid, gateway: gateway}) do
    started =
      0..(gateway.shards - 1)
      |> Stream.map(fn shard_id -> start_shard(config, tid, gateway, shard_id) end)
      |> Enum.count(&is_pid/1)

    Logger.info("#{QQ.bot_name(config)} started #{started}/#{gateway.shards} shard(s)")
  end

  @spec start_shard(QQ.config(), ETS.tid(), gateway(), non_neg_integer()) :: pid() | nil
  defp start_shard(%{name: name} = config, tid, gateway, shard_id) do
    %{url: url, shards: shards, max_concurrency: max_concurrency} = gateway

    shard_state = %QQ.Shard{
      config: config,
      gateway_url: url,
      shard: [shard_id, shards],
      max_concurrency: max_concurrency,
      token_table: tid
    }

    case DynamicSupervisor.start_child(QQ.shard_supervisor_name(name), {QQ.Shard, shard_state}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, reason} ->
        Logger.error("Failed to start #{QQ.bot_name(config)} shard #{shard_id}: #{inspect(reason)}")
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

  @spec log_failure(String.t(), term(), QQ.config()) :: :ok
  defp log_failure(prefix, reason, config) do
    case reason do
      {:qq_api, code, message} ->
        Logger.error("#{prefix} #{QQ.bot_name(config)}: #{code}, #{message}")

      {:unexpected_response, _} ->
        Logger.error("#{prefix} #{QQ.bot_name(config)}: unexpected response")

      exception ->
        Logger.error("#{prefix} #{QQ.bot_name(config)}: #{inspect(exception)}")
    end
  end

  @spec warn_on_session_limit(non_neg_integer(), pos_integer()) :: :ok
  defp warn_on_session_limit(remaining, shards) when is_integer(remaining) and remaining < shards do
    Logger.warning(
      "session_start_limit.remaining=#{remaining} is lower than shards=#{shards}; " <>
        "extra Identify requests may be rejected until the limit resets"
    )
  end

  defp warn_on_session_limit(_remaining, _shards), do: :ok

  # 构造机器人 token。形如 `QQBot <access_token>`。
  @spec token(String.t()) :: String.t()
  defp token(access_token), do: "QQBot #{access_token}"
end
