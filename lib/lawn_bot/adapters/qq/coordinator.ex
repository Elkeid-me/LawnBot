defmodule LawnBot.Adapters.QQ.Coordinator do
  @moduledoc """
  QQ 适配器的引导与维护进程。

  职责：

    * 获取 access_token，并在过期前定时刷新，刷新结果广播给全部分片；
    * 调用 `GET /gateway/bot` 获取网关地址与建议分片数；
    * 拿到 token 后在所属 DynamicSupervisor 下启动各分片连接进程。

  本进程是 `LawnBot.Adapters.QQ`（DynamicSupervisor）的第一个子进程，
  自身被监督树重启后会重新引导：已存在的分片会收到 `{:error, {:already_started, pid}}`
  而被跳过，只刷新它们持有的 token。
  """

  use GenServer
  require Logger

  alias LawnBot.Adapters.QQ

  @bootstrap_retry 5_000
  @token_refresh_retry 60_000

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
          supervisor: pid(),
          config: QQ.config(),
          token: QQ.token() | nil,
          gateway: gateway() | nil,
          refresh_ref: reference() | nil
        }

  @spec start_link({pid(), QQ.config()}) :: {:ok, pid()} | {:error, term()}
  def start_link({supervisor, %{app_id: app_id} = config}) do
    GenServer.start_link(__MODULE__, {supervisor, config}, name: via_tuple(app_id))
  end

  def child_spec({supervisor, %{app_id: app_id} = config}) do
    %{
      id: {__MODULE__, app_id},
      start: {__MODULE__, :start_link, [{supervisor, config}]}
    }
  end

  @impl true
  def init({supervisor, config}) do
    state = %{supervisor: supervisor, config: config, token: nil, gateway: nil, refresh_ref: nil}
    {:ok, state, {:continue, :bootstrap}}
  end

  @doc "异步启动 Coordinator 进程，避免阻塞 QQ 适配器监督树的启动。"
  @impl true
  @spec handle_continue(:bootstrap | :bootstrap, state()) :: {:noreply, state()}
  def handle_continue(:bootstrap, state), do: bootstrap(state)

  @impl true
  @spec handle_info(:refresh_token | term(), state()) :: {:noreply, state()}
  def handle_info(:refresh_token, state) do
    %{config: config, gateway: gateway} = state
    %{app_id: app_id, client_secret: client_secret} = config

    case fetch_access_token(app_id, client_secret) do
      {:ok, token} ->
        Logger.info("Refreshed token for #{QQ.bot_name(config)}")
        Enum.each(shard_pids(app_id, gateway.shards), &send(&1, {:qq_token_updated, token}))
        {:noreply, schedule_token_refresh(%{state | token: token})}

      {:error, reason} ->
        case reason do
          {:qq_api, code, message} ->
            Logger.error("Failed to refresh token for #{QQ.bot_name(config)}: #{code}, #{message}")

          {:unexpected_response, _} ->
            Logger.error("Failed to refresh token for #{QQ.bot_name(config)}: unexpected response")

          exception ->
            Logger.error(
              "Failed to refresh token for #{QQ.bot_name(config)}: #{inspect(exception)}"
            )
        end

        {:noreply,
         %{state | refresh_ref: Process.send_after(self(), :refresh_token, @token_refresh_retry)}}
    end
  end

  # 重试启动
  def handle_info(:bootstrap, state), do: bootstrap(state)
  def handle_info(_message, state), do: {:noreply, state}

  # Coordinator 进程在 Registry 中的名字。
  defp via_tuple(app_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.Coordinator, app_id}}}

  # 获取当前存活的分片进程，供 Coordinator 广播 token 刷新等消息。
  #
  # 通过 Registry 查找而不是缓存 pid，分片被监督树重启后仍然能找到新进程。
  @spec shard_pids(String.t(), pos_integer()) :: [pid()]
  defp shard_pids(app_id, shard_count) do
    0..(shard_count - 1)
    |> Stream.map(fn shard_id ->
      case Registry.lookup(
        LawnBot.AdapterRegistry,
        LawnBot.Adapters.QQ.shard_registry_key(app_id, shard_id)
           ) do
      [{pid, _}] -> pid
      [] -> nil
      end
    end)
    |> Enum.filter(&is_pid/1)
  end

  # 获取机器人 `access_token` 与 token 刷新时间。
  @spec fetch_access_token(String.t(), String.t()) :: {:ok, QQ.token()} | {:error, term()}
  defp fetch_access_token(app_id, client_secret) do
    case Req.post(@token_url, json: %{"appId" => app_id, "clientSecret" => client_secret}) do
      {:ok, %Req.Response{body: %{"access_token" => access_token, "expires_in" => expires_in}}}
      when is_binary(access_token) ->
        case positive_int(expires_in) do
          {:ok, expires_in} -> {:ok, %{access_token: access_token, expires_in: expires_in}}
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
    headers = %{"Authorization" => QQ.token(access_token)}

    case Req.get(@gateway_url, headers: headers) do
      {:ok, %Req.Response{body: %{"url" => url} = body}} when is_binary(url) ->
        {:ok, parse_gateway(url, body, config)}

      _ ->
        case Req.get(@plain_gateway_url, headers: headers) do
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
    %{app_id: app_id, client_secret: client_secret} = config

    with {:ok, token} <- fetch_access_token(app_id, client_secret),
         %{access_token: access_token} = token,
         {:ok, gateway} <- fetch_gateway(access_token, config) do
      %{url: url, shards: shards, remaining: remaining} = gateway
      Logger.info("Gateway for #{QQ.bot_name(config)}, #{url} (shards: #{shards})")
      warn_on_session_limit(remaining, shards)
      state = %{state | token: token, gateway: gateway}
      start_shards(state)
      state = schedule_token_refresh(state)
      {:noreply, state}
    else
      {:error, reason} ->
        case reason do
          {:qq_api, code, message} ->
            Logger.error("Failed to bootstrap #{QQ.bot_name(config)}: #{code}, #{message}")

          {:unexpected_response, _} ->
            Logger.error("Failed to bootstrap #{QQ.bot_name(config)}: unexpected response")

          exception ->
            Logger.error("Failed to bootstrap #{QQ.bot_name(config)}: #{inspect(exception)}")
        end

        Process.send_after(self(), :bootstrap, @bootstrap_retry)
        state = %{state | token: nil}
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
  defp start_shards(%{supervisor: supervisor, config: config, token: token, gateway: gateway}) do
    started =
      0..(gateway.shards - 1)
      |> Stream.map(fn shard_id -> start_shard(supervisor, config, token, gateway, shard_id) end)
      |> Enum.count(&is_pid/1)

    Logger.info("#{QQ.bot_name(config)} started #{started}/#{gateway.shards} shard(s)")
  end

  @spec start_shard(pid(), QQ.config(), QQ.token(), gateway(), non_neg_integer()) :: pid() | nil
  defp start_shard(supervisor, config, token, gateway, shard_id) do
    %{url: url, shards: shards, max_concurrency: max_concurrency} = gateway

    shard_state = %QQ.Shard{
      config: config,
      gateway_url: url,
      shard: [shard_id, shards],
      max_concurrency: max_concurrency,
      token: token
    }

    case DynamicSupervisor.start_child(supervisor, {QQ.Shard, shard_state}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        # 分片已在运行（例如 Coordinator 自身被重启），只需同步最新 token。
        send(pid, {:qq_token_updated, token})
        pid

      {:error, reason} ->
        Logger.error("Failed to start #{QQ.bot_name(config)} shard #{shard_id}: #{inspect(reason)}")
        nil
    end
  end

  @spec schedule_token_refresh(state()) :: state()
  defp schedule_token_refresh(%{token: token} = state) do
    state =
      case state.refresh_ref do
        nil ->
          state

        ref ->
          Process.cancel_timer(ref)
          %{state | refresh_ref: nil}
      end

    # 文档建议在过期前 60 秒刷新，此时获取会拿到新的 token。
    # 如果 expires_in 小于 60 秒，则立即刷新。
    delay = max((token.expires_in - 60) * 1_000, 1_000)
    %{state | refresh_ref: Process.send_after(self(), :refresh_token, delay)}
  end

  @spec warn_on_session_limit(non_neg_integer(), pos_integer()) :: :ok
  defp warn_on_session_limit(remaining, shards)
       when is_integer(remaining) and remaining < shards do
    Logger.warning(
      "session_start_limit.remaining=#{remaining} is lower than shards=#{shards}; " <>
        "extra Identify requests may be rejected until the limit resets"
    )
  end

  defp warn_on_session_limit(_remaining, _shards), do: :ok
end
