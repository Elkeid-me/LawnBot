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

  alias :ets, as: ETS
  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ
  alias LawnBot.Adapters.QQ.TokenStore

  require Logger

  defstruct [
    :name,
    :shard,
    :token_table_tid,
    session_id: nil,
    heartbeat_interval: nil,
    heartbeat_ref: nil,
    auth_ref: nil,
    seq: nil,
    awaiting_ack?: false
  ]

  @typedoc """
  分片参数，形如 `[shard_id, total_shards]`，用于 Identify 时启用水平分片。

  其中 `0 <= shard_id < total_shards`。
  """
  @type shard() :: [non_neg_integer()]

  @type t() :: %__MODULE__{
          name: atom(),
          shard: shard(),
          token_table_tid: ETS.tid(),
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
  def start_link(state) do
    opts = [
      async: true,
      handle_initial_conn_failure: true,
      name: via_tuple(state.name, shard_id(state))
    ]

    gateway_url = PersistentTerm.get({state.name, :gateway_url})
    WebSockex.start_link(gateway_url, __MODULE__, state, opts)
  end

  def child_spec(state) do
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
    access_token = TokenStore.get(state.token_table_tid)

    {action, payload} =
      case state.session_id do
        nil -> {"identifying", identify_payload(access_token, state.name, state.shard)}
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

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    delay = backoff(status.attempt_number || 1)
    Logger.warning("#{shard_name(state)} disconnected, reconnecting in #{delay}ms")
    Process.sleep(delay)
    {:reconnect, state}
  end

  # Dispatch：记录 seq（心跳与 Resume 都需要），READY 时保存 session_id。
  @spec handle_payload(map(), t()) ::
          {:ok, t()} | {:reply, {:text, String.t()}, t()} | {:close, t()}
  defp handle_payload(%{"op" => 0} = payload, state) do
    state = update_seq(payload, state)

    case payload do
      %{"t" => "READY", "d" => %{"session_id" => session_id}} ->
        Logger.info("READY on #{shard_name(state)}, session_id=#{session_id}")
        {:ok, %{state | session_id: session_id}}

      %{"t" => "RESUMED"} ->
        Logger.info("RESUMED on #{shard_name(state)}, from seq #{state.seq}")
        {:ok, state}

      %{"t" => _} ->
        handle_event(payload, state)
        {:ok, state}

      _ ->
        Logger.debug("Unknown payload on #{shard_name(state)}: #{inspect(payload)}")
        {:ok, state}
    end
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
  defp handle_payload(%{"op" => 9}, state) do
    Logger.warning("Invalid Session on #{shard_name(state)}, falling back to a fresh Identify")
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

  defp via_tuple(name, shard_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, name, shard_id}}}

  @spec update_seq(nil | non_neg_integer() | map(), t()) :: t()
  defp update_seq(nil, state), do: state

  defp update_seq(seq, state) when is_integer(seq) do
    case state.seq do
      nil -> %{state | seq: seq}
      old_seq when is_integer(old_seq) and old_seq < seq -> %{state | seq: seq}
      _ -> state
    end
  end

  defp update_seq(payload, state) when is_map(payload),
    do: update_seq(Map.fetch!(payload, "s"), state)

  # 各分片按索引错峰 Identify，避免同时鉴权触发限流。
  defp authenticate_delay(state) do
    shard_id = shard_id(state)
    concurrency = PersistentTerm.get({state.name, :max_concurrency})
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
  defp shard_id(%__MODULE__{shard: [shard_id, _]}), do: shard_id

  @spec shard_name(t()) :: String.t()
  defp shard_name(%__MODULE__{shard: [shard_id, shards], name: name}),
    do: "#{QQ.bot_name(name)} shard #{shard_id + 1}/#{shards}"

  # 构造 OpCode 2 Identify 载荷，携带分片参数以启用水平分片。
  @spec identify_payload(String.t(), atom(), shard()) :: map()
  defp identify_payload(access_token, name, shard) do
    %{
      "op" => 2,
      "d" => %{
        "token" => access_token,
        "intents" => PersistentTerm.get({name, :intents}),
        "shard" => shard,
        "properties" => %{
          "$os" => PersistentTerm.get({name, :os}),
          "$browser" => PersistentTerm.get({name, :browser}),
          "$device" => PersistentTerm.get({name, :device})
        }
      }
    }
  end

  # 构造 OpCode 6 Resume 载荷，用 session_id 与 seq 补发断线期间遗漏的事件。
  @spec resume_payload(String.t(), String.t(), non_neg_integer() | nil) :: map()
  defp resume_payload(access_token, session_id, seq) do
    %{
      "op" => 6,
      "d" => %{
        "token" => access_token,
        "session_id" => session_id,
        "seq" => seq
      }
    }
  end

  defp handle_event(payload, state) do
    name = state.name
    tid = state.token_table_tid
    task_supervisor = QQ.task_supervisor_name(name)
    handler = :persistent_term.get(name, nil)

    Task.Supervisor.start_child(task_supervisor, fn ->
      payload |> QQ.to_event() |> handler.() |> handle_reply(tid, name)
    end)
  end

  @spec handle_reply(LawnBot.Reply.t(), ETS.tid(), module()) :: :ok
  defp handle_reply(%LawnBot.Reply{action: action} = reply, tid, name)
       when action == :reply or action == :new_message do
    send_message(reply, TokenStore.get(tid), name)
  end

  defp handle_reply(_reply, _tid, _name), do: :ok

  @spec send_message(LawnBot.Reply.t(), String.t(), module()) :: :ok
  defp send_message(%LawnBot.Reply{action: action, event: event}, access_token, name) do
    session_id = event.session_id

    url =
      case(event.session_type) do
        :group -> "https://api.bot.qq.com/v2/groups/#{session_id}/messages"
        :c2c -> "https://api.bot.qq.com/v2/users/#{session_id}/messages"
      end

    message =
      case action do
        :reply -> event |> build_message_content() |> Map.put("msg_id", event.message_id)
        :new_message -> build_message_content(event)
        _ -> nil
      end

    headers = %{"authorization" => access_token, "content-type" => "application/json"}

    Req.post(url,
      body: JSON.encode_to_iodata!(message),
      headers: headers,
      finch: [name: LawnBot.Finch, pool_tag: name],
      decode_body: false
    )

    :ok
  end

  # 构造消息发送的 JSON 载荷
  # todo
  defp build_message_content(event) do
    %{
      "msg_type" => 0,
      "content" => event.content
    }
  end
end
