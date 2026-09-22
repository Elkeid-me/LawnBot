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

  @spec start_link({pid(), QQ.config()}) :: {:ok, pid()} | {:error, term()}
  def start_link({supervisor, config}) do
    GenServer.start_link(__MODULE__, {supervisor, config}, name: QQ.coordinator_name(config))
  end

  def child_spec({supervisor, config}) do
    %{
      id: {__MODULE__, QQ.app_id(config)},
      start: {__MODULE__, :start_link, [{supervisor, config}]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @impl true
  def init({supervisor, config}) do
    state = %{supervisor: supervisor, config: config, token: nil, gateway: nil, refresh_ref: nil}
    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state), do: {:noreply, bootstrap(state)}

  @impl true
  def handle_info(:bootstrap, state), do: {:noreply, bootstrap(state)}

  def handle_info(:refresh_token, state) do
    %{config: config, gateway: gateway} = state

    case QQ.fetch_access_token(config) do
      {:ok, token} ->
        Logger.info("Refreshed QQ access token for app #{QQ.app_id(config)}")
        Enum.each(QQ.shard_pids(config, gateway.shards), &send(&1, {:qq_token_updated, token}))
        {:noreply, schedule_token_refresh(%{state | token: token})}

      {:error, reason} ->
        Logger.error(
          "Failed to refresh QQ access token for app #{QQ.app_id(config)}: #{inspect(reason)}, " <>
            "retry in #{@token_refresh_retry}ms"
        )

        {:noreply,
         %{state | refresh_ref: Process.send_after(self(), :refresh_token, @token_refresh_retry)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp bootstrap(state) do
    %{config: config} = state

    with {:ok, token} <- QQ.fetch_access_token(config),
         {:ok, gateway} <- QQ.fetch_gateway(token.access_token, config) do
      Logger.info(
        "QQ gateway for app #{QQ.app_id(config)}: #{gateway.url} " <>
          "(shards=#{gateway.shards}, max_concurrency=#{gateway.max_concurrency})"
      )

      warn_on_session_limit(gateway)
      state = %{state | token: token, gateway: gateway}
      start_shards(state)
      schedule_token_refresh(state)
    else
      {:error, reason} ->
        Logger.error(
          "Failed to bootstrap QQ adapter for app #{QQ.app_id(config)}: #{inspect(reason)}, " <>
            "retry in #{@bootstrap_retry}ms"
        )

        Process.send_after(self(), :bootstrap, @bootstrap_retry)
        %{state | token: nil}
    end
  end

  defp start_shards(%{supervisor: supervisor, config: config, token: token, gateway: gateway}) do
    started =
      0..(gateway.shards - 1)
      |> Enum.map(fn shard_id -> start_shard(supervisor, config, token, gateway, shard_id) end)
      |> Enum.reject(&is_nil/1)

    Logger.info(
      "QQ adapter for app #{QQ.app_id(config)} started #{length(started)}/#{gateway.shards} shard(s)"
    )
  end

  defp start_shard(supervisor, config, token, gateway, shard_id) do
    shard_state = %QQ.Shard{
      config: config,
      gateway_url: gateway.url,
      shard: [shard_id, gateway.shards],
      max_concurrency: gateway.max_concurrency,
      token: token,
      event_handler: Map.get(config, :event_handler)
    }

    case DynamicSupervisor.start_child(supervisor, {QQ.Shard, shard_state}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        # 分片已在运行（例如 Coordinator 自身被重启），只需同步最新 token。
        send(pid, {:qq_token_updated, token})
        pid

      {:error, reason} ->
        Logger.error("Failed to start QQ shard #{shard_id}: #{inspect(reason)}")
        nil
    end
  end

  defp schedule_token_refresh(%{token: token} = state) do
    state = cancel_timer(state, :refresh_ref)

    # 文档建议在过期前 60 秒刷新，此时获取会拿到新的 token。
    delay = max((token.expires_in - 60) * 1_000, 1_000)
    %{state | refresh_ref: Process.send_after(self(), :refresh_token, delay)}
  end

  defp cancel_timer(state, key) do
    case Map.pop(state, key) do
      {nil, _state} ->
        state

      {ref, state} ->
        Process.cancel_timer(ref)
        Map.put(state, key, nil)
    end
  end

  defp warn_on_session_limit(%{remaining: remaining, shards: shards})
       when is_integer(remaining) and remaining < shards do
    Logger.warning(
      "QQ session_start_limit.remaining=#{remaining} is lower than shards=#{shards}; " <>
        "extra Identify requests may be rejected until the limit resets"
    )
  end

  defp warn_on_session_limit(_gateway), do: :ok
end
