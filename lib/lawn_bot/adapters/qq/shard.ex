defmodule LawnBot.Adapters.QQ.Shard do
  @moduledoc """
  单个 QQ 网关分片的 WebSocket 连接进程。

  每个分片独立完成 QQ 网关协议循环：

    * 连接成功后等待 OpCode 10 Hello，拿到心跳周期；
    * 按 `session_start_limit.max_concurrency` 错峰发送 OpCode 2 Identify，
      首次连接获得 session_id，断线重连时改发 OpCode 6 Resume 补发事件；
    * 按 Hello 给出的周期发送 OpCode 1 心跳，携带最近一次收到的 `s`，
      若上一次心跳没有收到 OpCode 11 ACK 则主动重连；
    * OpCode 0 Dispatch 事件标准化后以 `{:lawn_bot_event, event}` 投递给
      配置的 `:event_handler`。

  进程由 `LawnBot.Adapters.QQ`（DynamicSupervisor）监督，连接本身使用
  WebSockex 的 `handle_initial_conn_failure` + 指数退避自行重连。
  """

  use WebSockex
  require Logger

  alias LawnBot.Adapters.QQ

  defstruct [
    :config,
    :gateway_url,
    :shard,
    :max_concurrency,
    :token,
    :event_handler,
    :session_id,
    :heartbeat_interval,
    :heartbeat_ref,
    :auth_ref,
    seq: nil,
    awaiting_ack?: false
  ]

  @type t :: %__MODULE__{
          config: QQ.config(),
          gateway_url: String.t(),
          shard: QQ.shard(),
          max_concurrency: pos_integer(),
          token: QQ.token(),
          event_handler: pid() | atom() | (map() -> term()) | nil,
          session_id: String.t() | nil,
          heartbeat_interval: pos_integer() | nil,
          heartbeat_ref: reference() | nil,
          auth_ref: reference() | nil,
          seq: non_neg_integer() | nil,
          awaiting_ack?: boolean()
        }

  @default_heartbeat_interval 45_000
  @max_backoff 60_000

  @spec start_link(t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%__MODULE__{} = state) do
    opts = [
      async: true,
      handle_initial_conn_failure: true,
      name: QQ.shard_name(state.config, shard_id(state))
    ]

    WebSockex.start_link(state.gateway_url, __MODULE__, state, opts)
  end

  def child_spec(%__MODULE__{} = state) do
    %{
      id: {__MODULE__, shard_id(state)},
      start: {__MODULE__, :start_link, [state]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @impl true
  def handle_connect(_conn, state) do
    # 重连后先清掉上一条连接的心跳定时器，等 Hello 再重新调度。
    {:ok,
     state
     |> cancel_timer(:heartbeat_ref)
     |> cancel_timer(:auth_ref)
     |> Map.put(:awaiting_ack?, false)}
  end

  @impl true
  def handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, payload} when is_map(payload) ->
        handle_payload(payload, state)

      {:ok, other} ->
        Logger.warning("Ignoring non-object QQ gateway payload: #{inspect(other)}")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Ignoring invalid QQ gateway JSON: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  # Dispatch：记录 seq（心跳与 Resume 都需要），READY 时保存 session_id。
  defp handle_payload(%{"op" => 0} = payload, state) do
    state =
      case payload do
        %{"t" => "READY", "d" => %{"session_id" => session_id}} ->
          Logger.info("READY on QQ shard #{inspect_shard(state.shard)}, session_id=#{session_id}")
          %{state | session_id: session_id, seq: payload["s"]}

        %{"t" => "RESUMED"} ->
          Logger.info("RESUMED on QQ shard #{inspect_shard(state.shard)}, from seq #{state.seq}")
          update_seq(state, payload)

        _ ->
          update_seq(state, payload)
      end

    {:ok, emit(state, payload)}
  end

  # 服务端主动下发的心跳请求，立即回包。
  defp handle_payload(%{"op" => 1}, state),
    do: {:reply, heartbeat_frame(state), %{state | awaiting_ack?: true}}

  # 服务端要求重连，重连后用 Resume 继续，不丢事件。
  defp handle_payload(%{"op" => 7}, state) do
    Logger.info("QQ shard #{inspect_shard(state.shard)} asked to reconnect by gateway")
    {:close, state}
  end

  # Identify/Resume 被拒绝：丢弃会话，下次连接重新 Identify。
  defp handle_payload(%{"op" => 9} = payload, state) do
    Logger.warning(
      "Invalid Session on QQ shard #{inspect_shard(state.shard)}: #{inspect(payload["d"])}, " <>
        "falling back to a fresh Identify"
    )

    {:close, %{state | session_id: nil, seq: nil, awaiting_ack?: false}}
  end

  # Hello：心跳周期以此为准，延时后发起 Identify/Resume。
  defp handle_payload(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    state = %{state | heartbeat_interval: interval, awaiting_ack?: false}
    Logger.info("Hello on QQ shard #{inspect_shard(state.shard)}, heartbeat interval #{interval}ms")
    {:ok, schedule_authenticate(state, authenticate_delay(state))}
  end

  # 心跳 ACK。
  defp handle_payload(%{"op" => 11}, state), do: {:ok, %{state | awaiting_ack?: false}}

  defp handle_payload(payload, state) do
    Logger.debug("QQ shard #{inspect_shard(state.shard)} ignoring op=#{inspect(payload["op"])}")
    {:ok, state}
  end

  @impl true
  def handle_info(:authenticate, state) do
    %{access_token: access_token} = state.token

    {action, payload} =
      case state.session_id do
        nil -> {"identifying", QQ.identify_payload(access_token, state.config, state.shard)}
        session_id -> {"resuming", QQ.resume_payload(access_token, session_id, state.seq)}
      end

    Logger.info("QQ shard #{inspect_shard(state.shard)} #{action}")
    {:reply, {:text, Jason.encode!(payload)}, schedule_heartbeat(%{state | awaiting_ack?: false})}
  end

  def handle_info(:heartbeat, state) do
    if state.awaiting_ack? do
      Logger.warning("ACK missed on QQ shard #{inspect_shard(state.shard)}, reconnecting to resume")
      {:close, %{state | awaiting_ack?: false}}
    else
      state = schedule_heartbeat(%{state | awaiting_ack?: true})
      {:reply, heartbeat_frame(state), state}
    end
  end

  def handle_info({:qq_token_updated, token}, state) do
    {:ok, %{state | token: token}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    reason = Map.get(status, :reason)
    delay = backoff(Map.get(status, :attempt_number, 1))

    Logger.warning(
      "QQ shard #{inspect_shard(state.shard)} disconnected: #{inspect(reason)}, " <>
        "reconnecting in #{delay}ms"
    )

    Process.sleep(delay)
    {:reconnect, state}
  end

  defp update_seq(state, payload) do
    case payload["s"] do
      seq when is_integer(seq) -> %{state | seq: seq}
      _other -> state
    end
  end

  defp emit(state, payload) do
    event = QQ.event(payload, state.shard)

    case state.event_handler do
      nil -> Logger.debug("#{inspect(event.type)} on QQ shard #{inspect_shard(state.shard)}")
      handler -> dispatch(handler, event)
    end

    state
  end

  defp dispatch(_handler, _event), do: nil

  # 各分片按索引错峰 Identify，避免同时鉴权触发限流。
  defp authenticate_delay(state) do
    [shard_id | _] = state.shard
    concurrency = max(state.max_concurrency || 1, 1)
    round(shard_id * 5_000 / concurrency)
  end

  defp schedule_authenticate(state, delay) do
    state = cancel_timer(state, :auth_ref)
    %{state | auth_ref: Process.send_after(self(), :authenticate, delay)}
  end

  defp schedule_heartbeat(state) do
    state = cancel_timer(state, :heartbeat_ref)
    interval = state.heartbeat_interval || @default_heartbeat_interval
    %{state | heartbeat_ref: Process.send_after(self(), :heartbeat, interval)}
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

  defp heartbeat_frame(state), do: {:text, Jason.encode!(%{"op" => 1, "d" => state.seq})}
  defp backoff(attempt), do: min(round(:math.pow(2, attempt)) * 500, @max_backoff)
  defp shard_id(%__MODULE__{shard: [shard_id | _]}), do: shard_id
  defp inspect_shard([shard_id, shards]), do: "#{shard_id + 1}/#{shards}"
end
