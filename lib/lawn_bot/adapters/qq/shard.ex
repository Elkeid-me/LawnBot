defmodule LawnBot.Adapters.QQ.Shard do
  @moduledoc """
  单个 QQ 网关分片的 WebSocket 连接进程。

  每个分片独立完成 QQ 网关协议循环：

  - 连接成功后等待 OpCode 10 Hello，拿到心跳周期；
  - 按 `session_start_limit.max_concurrency` 错峰发送 OpCode 2 Identify，
    首次连接获得 session_id，断线重连时改发 OpCode 6 Resume 补发事件；
  - 按 Hello 给出的周期发送 OpCode 1 心跳，携带最近一次收到的 `s`，
    若上一次心跳没有收到 OpCode 11 ACK 则主动重连；

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
    :session_id,
    :heartbeat_interval,
    :heartbeat_ref,
    :auth_ref,
    seq: nil,
    awaiting_ack?: false
  ]

  @type shard() :: [non_neg_integer()]

  @type t() :: %__MODULE__{
          config: QQ.config(),
          gateway_url: String.t(),
          shard: shard(),
          max_concurrency: pos_integer(),
          token: QQ.token(),
          session_id: String.t() | nil,
          heartbeat_interval: pos_integer() | nil,
          heartbeat_ref: reference() | nil,
          auth_ref: reference() | nil,
          seq: non_neg_integer() | nil,
          awaiting_ack?: boolean()
        }

  # 事件订阅 intents 位定义
  @intents %{
    guilds: 1,
    guild_members: 2,
    guild_messages: 512,
    guild_message_reactions: 1_024,
    direct_message: 4_096,
    group_and_c2c: 33_554_432,
    interaction: 67_108_864,
    message_audit: 134_217_728,
    forums_event: 268_435_456,
    audio_action: 536_870_912,
    public_guild_messages: 1_073_741_824
  }

  # 未配置 intents 时只订阅默认就有权限的事件，避免无权限 intents 导致网关直接断开连接。
  @default_intents [:guilds, :guild_members, :public_guild_messages]

  @default_heartbeat_interval 45_000
  @max_backoff 60_000

  @spec start_link(t()) :: {:ok, pid()} | {:error, term()}
  def start_link(%__MODULE__{} = state) do
    opts = [
      async: true,
      handle_initial_conn_failure: true,
      name: via_tuple(state.config.app_id, shard_id(state))
    ]

    WebSockex.start_link(state.gateway_url, __MODULE__, state, opts)
  end

  def child_spec(%__MODULE__{} = state) do
    %{
      id: {__MODULE__, shard_id(state)},
      start: {__MODULE__, :start_link, [state]}
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
  @spec handle_frame(WebSockex.frame(), t()) :: {:ok, t()} | {:reply, {:text, String.t()}, t()}
  def handle_frame({:text, text}, state) do
    case JSON.decode(text) do
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

  @impl true
  def handle_info(:authenticate, state) do
    %{access_token: access_token} = state.token

    {action, payload} =
      case state.session_id do
        nil -> {"identifying", identify_payload(access_token, state.config, state.shard)}
        session_id -> {"resuming", resume_payload(access_token, session_id, state.seq)}
      end

    Logger.info("#{shard_name(state)} #{action}")
    {:reply, {:text, JSON.encode!(payload)}, schedule_heartbeat(%{state | awaiting_ack?: false})}
  end

  def handle_info(:heartbeat, state) do
    if state.awaiting_ack? do
      Logger.warning("ACK missed on #{shard_name(state)}, reconnecting to resume")
      {:close, %{state | awaiting_ack?: false}}
    else
      state = schedule_heartbeat(%{state | awaiting_ack?: true})
      {:reply, heartbeat_frame(state), state}
    end
  end

  def handle_info({:qq_token_updated, token}, state) do
    Logger.info("#{shard_name(state)} received updated QQ token")
    {:ok, %{state | token: token}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    delay = backoff(status.attempt_number || 1)

    Logger.warning(
      "#{shard_name(state)} disconnected: #{inspect(status.reason)}, reconnecting in #{delay}ms"
    )

    Process.sleep(delay)
    {:reconnect, state}
  end

  # Dispatch：记录 seq（心跳与 Resume 都需要），READY 时保存 session_id。
  @spec handle_payload(map(), t()) ::
          {:ok, t()} | {:reply, {:text, String.t()}, t()} | {:close, t()}
  defp handle_payload(%{"op" => 0} = payload, state) do
    state =
      case payload do
        %{"t" => "READY", "d" => %{"session_id" => session_id}} ->
          Logger.info("READY on #{shard_name(state)}, session_id=#{session_id}")
          %{state | session_id: session_id, seq: Map.get(payload, "s")}

        %{"t" => "RESUMED"} ->
          Logger.info("RESUMED on #{shard_name(state)}, from seq #{state.seq}")
          update_seq(state, payload)

        %{"t" => event} ->
          Logger.debug("Unhandled event #{event} on #{shard_name(state)}: #{inspect(payload)}")
          update_seq(state, payload)

        _ ->
          Logger.debug("Unknown payload on #{shard_name(state)}: #{inspect(payload)}")
          update_seq(state, payload)
      end

    # todo
    {:ok, state}
  end

  # 服务端主动下发的心跳请求，立即回包。
  defp handle_payload(%{"op" => 1}, state),
    do: {:reply, heartbeat_frame(state), %{state | awaiting_ack?: true}}

  # 服务端要求重连，重连后用 Resume 继续，不丢事件。
  defp handle_payload(%{"op" => 7}, state) do
    Logger.info("#{shard_name(state)} asked to reconnect by gateway")
    {:close, state}
  end

  # Identify/Resume 被拒绝：丢弃会话，下次连接重新 Identify。
  defp handle_payload(%{"op" => 9} = payload, state) do
    Logger.warning(
      "Invalid Session on #{shard_name(state)}: #{inspect(Map.get(payload, "d"))}, " <>
        "falling back to a fresh Identify"
    )

    {:close, %{state | session_id: nil, seq: nil, awaiting_ack?: false}}
  end

  # Hello：心跳周期以此为准，延时后发起 Identify/Resume。
  defp handle_payload(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    state = %{state | heartbeat_interval: interval, awaiting_ack?: false}
    Logger.info("Hello on #{shard_name(state)}, heartbeat interval #{interval}ms")
    {:ok, schedule_authenticate(state, authenticate_delay(state))}
  end

  # 心跳 ACK。
  defp handle_payload(%{"op" => 11}, state), do: {:ok, %{state | awaiting_ack?: false}}

  defp handle_payload(%{"op" => op}, state) do
    Logger.debug("#{shard_name(state)} ignoring op=#{op}")
    {:ok, state}
  end

  defp via_tuple(app_id, shard_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, QQ.shard_registry_key(app_id, shard_id)}}

  @spec update_seq(t(), nil | non_neg_integer() | map()) :: t()
  defp update_seq(state, nil), do: state
  defp update_seq(state, seq) when is_integer(seq), do: %{state | seq: seq}
  defp update_seq(state, payload) when is_map(payload), do: update_seq(state, Map.get(payload, "s"))

  # 各分片按索引错峰 Identify，避免同时鉴权触发限流。
  defp authenticate_delay(state) do
    shard_id = shard_id(state)
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
    case Map.get(state, key) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        %{state | key => nil}
    end
  end

  defp heartbeat_frame(state), do: {:text, JSON.encode!(%{"op" => 1, "d" => state.seq})}
  defp backoff(attempt), do: min(round(:math.pow(2, attempt)) * 500, @max_backoff)
  defp shard_id(%__MODULE__{shard: [shard_id | _]}), do: shard_id
  @spec shard_name(t()) :: String.t()
  defp shard_name(%__MODULE__{shard: [shard_id, shards], config: config}),
    do: "#{QQ.bot_name(config)} shard #{shard_id + 1}/#{shards}"

  # 构造 OpCode 2 Identify 载荷，携带分片参数以启用水平分片。
  @spec identify_payload(String.t(), QQ.config(), shard()) :: map()
  defp identify_payload(access_token, config, shard) do
    %{
      "op" => 2,
      "d" => %{
        "token" => QQ.token(access_token),
        "intents" => intents(config),
        "shard" => shard,
        "properties" => %{
          "$os" => Map.get(config, :os, default_os()),
          "$browser" => Map.get(config, :browser, "LawnBot"),
          "$device" => Map.get(config, :device, "LawnBot")
        }
      }
    }
  end

  defp default_os, do: to_string(elem(:os.type(), 1))

  # 构造 OpCode 6 Resume 载荷，用 session_id 与 seq 补发断线期间遗漏的事件。
  @spec resume_payload(String.t(), String.t(), non_neg_integer() | nil) :: map()
  defp resume_payload(access_token, session_id, seq) do
    %{
      "op" => 6,
      "d" => %{
        "token" => QQ.token(access_token),
        "session_id" => session_id,
        "seq" => seq
      }
    }
  end

  # 计算本次连接订阅的 intents 位掩码。
  #
  # `:intents` 可以直接给整数，也可以给意图原子列表；未知意图会被忽略并告警，
  # 因为携带无权限的 intents 会导致网关直接关闭连接。
  @spec intents(QQ.config()) :: non_neg_integer()
  defp intents(config), do: config |> Map.get(:intents, @default_intents) |> normalize_intents()
  @spec normalize_intents(non_neg_integer() | [atom()] | any()) :: non_neg_integer()
  defp normalize_intents(intents) when is_integer(intents) and intents >= 0, do: intents

  defp normalize_intents(intents) when is_list(intents) do
    Enum.reduce(intents, 0, fn intent, acc ->
      case Map.get(@intents, intent) do
        nil ->
          Logger.warning("Ignoring unknown QQ intent: #{inspect(intent)}")
          acc

        bit ->
          acc + bit
      end
    end)
  end

  defp normalize_intents(other) do
    Logger.warning("Ignoring invalid QQ intents: #{inspect(other)}")
    normalize_intents(@default_intents)
  end
end
