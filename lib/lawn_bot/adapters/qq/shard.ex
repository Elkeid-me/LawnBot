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

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ
  alias LawnBot.TokenStore

  require Logger

  defstruct [
    :name,
    :shard_id,
    session_id: nil,
    heartbeat_interval: nil,
    heartbeat_ref: nil,
    auth_ref: nil,
    seq: nil,
    awaiting_ack?: false
  ]

  @type t() :: %__MODULE__{
          name: atom(),
          shard_id: non_neg_integer(),
          session_id: String.t() | nil,
          heartbeat_interval: pos_integer() | nil,
          heartbeat_ref: reference() | nil,
          auth_ref: reference() | nil,
          seq: non_neg_integer() | nil,
          awaiting_ack?: boolean()
        }

  @max_backoff 64_000

  @spec start_link(t()) :: {:ok, pid()} | {:error, term()}
  def start_link(state) do
    opts = [
      async: true,
      handle_initial_conn_failure: true,
      name: via_tuple(state.name, state.shard_id)
    ]

    gateway_url = PersistentTerm.get({state.name, :gateway_url})
    WebSockex.start_link(gateway_url, __MODULE__, state, opts)
  end

  def child_spec(state) do
    %{
      id: {__MODULE__, state.shard_id},
      start: {__MODULE__, :start_link, [state]}
    }
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    state =
      state
      |> cancel_timer(:heartbeat_ref)
      |> cancel_timer(:auth_ref)
      |> Map.put(:awaiting_ack?, false)

    {:ok, state}
  end

  @impl WebSockex
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

  @impl WebSockex
  def handle_info(:authenticate, state) do
    access_token = TokenStore.get(state.name)

    {action, payload} =
      case state.session_id do
        nil -> {"identifying", identify_payload(access_token, state.name, state.shard_id)}
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

  @impl WebSockex
  def handle_cast(_message, state), do: {:ok, state}

  @impl WebSockex
  def handle_disconnect(status, state) do
    delay = backoff(status.attempt_number)
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
    {:ok, schedule_authenticate(state)}
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

  defp schedule_authenticate(state) do
    concurrency = PersistentTerm.get({state.name, :max_concurrency})
    delay = round(state.shard_id * 5_000 / concurrency) + :rand.uniform(1000)
    start_timer(state, :auth_ref, :authenticate, delay)
  end

  defp schedule_heartbeat(state) do
    delay = state.heartbeat_interval
    start_timer(state, :heartbeat_ref, :heartbeat, delay)
  end

  defp start_timer(state, key, message, delay) do
    state = cancel_timer(state, key)
    %{state | key => Process.send_after(self(), message, delay)}
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

  @spec shard_name(t()) :: String.t()
  defp shard_name(%__MODULE__{shard_id: shard_id, name: name}) do
    shards = PersistentTerm.get({name, :shards})
    "#{QQ.bot_name(name)} shard #{shard_id + 1}/#{shards}"
  end

  # Construct OpCode 2 "Identify" payload, using access_token and shard_id.
  @spec identify_payload(String.t(), atom(), non_neg_integer()) :: map()
  defp identify_payload(access_token, name, shard_id) do
    shards = PersistentTerm.get({name, :shards})

    %{
      "op" => 2,
      "d" => %{
        "token" => access_token,
        "intents" => PersistentTerm.get({name, :intents}),
        "shard" => [shard_id, shards],
        "properties" => %{
          "$os" => PersistentTerm.get({name, :os}),
          "$browser" => PersistentTerm.get({name, :browser}),
          "$device" => PersistentTerm.get({name, :device})
        }
      }
    }
  end

  # Construct OpCode 6 "Resume" payload, using session_id and seq to recover missed events during disconnection.
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
    task_supervisor = QQ.task_supervisor_via_tuple(name)
    handler = :persistent_term.get(name, nil)

    Task.Supervisor.start_child(task_supervisor, fn ->
      payload |> LawnBot.Adapters.QQ.EventProcess.to_event() |> handler.() |> handle_response(name)
    end)
  end

  @spec handle_response(LawnBot.Response.t(), module()) :: :ok
  defp handle_response(%LawnBot.Response{action: action} = response, name)
       when action == :reply or action == :new_message do
    send_message(response, TokenStore.get(name), name)
  end

  defp handle_response(_response, _name), do: :ok

  @spec send_message(LawnBot.Response.t(), String.t(), module()) :: :ok
  defp send_message(response, access_token, name) do
    url =
      case(response.session_type) do
        :group -> "https://api.bot.qq.com/v2/groups/#{response.session_id}/messages"
        :c2c -> "https://api.bot.qq.com/v2/users/#{response.session_id}/messages"
      end

    message =
      case response.action do
        :reply ->
          response
          |> build_message_content(access_token, name)
          |> Map.put("msg_id", response.reply_message_id)

        :new_message ->
          build_message_content(response, access_token, name)

        _ ->
          nil
      end

    headers = %{"authorization" => access_token, "content-type" => "application/json"}

    Req.post(url,
      headers: headers,
      json: message,
      finch: [name: LawnBot.Finch, pool_tag: name]
    )

    :ok
  end

  # 构造消息发送的 JSON 载荷
  @spec build_message_content(LawnBot.Response.t(), String.t(), atom()) :: map()
  defp build_message_content(response, access_token, name) do
    media_info_task =
      case response.attachment do
        nil -> nil
        _ -> Task.async(fn -> upload_attachment(response, access_token, name) end)
      end

    payload =
      case response.text do
        nil -> %{}
        text -> %{"content" => text}
      end

    payload =
      case response.reference_message_id do
        nil -> payload
        id -> Map.put(payload, "message_reference", %{"message_id" => id})
      end

    case media_info_task do
      nil ->
        Map.put(payload, "msg_type", 0)

      task ->
        payload
        |> Map.put("msg_type", 7)
        |> Map.put("media", %{"file_info" => Task.await(task, 30_000)})
    end
  end

  @spec upload_attachment(LawnBot.Response.t(), String.t(), atom()) :: nil
  defp upload_attachment(%LawnBot.Response{attachment: {:path, path}}, _access_token, _name)
       when is_binary(path) do
    nil
  end

  @spec upload_attachment(LawnBot.Response.t(), String.t(), atom()) :: nil
  defp upload_attachment(%LawnBot.Response{attachment: {:url, url}} = response, access_token, name)
       when is_binary(url) do
    headers = %{"authorization" => access_token, "content-type" => "application/json"}

    body = %{
      "file_type" => 1,
      "url" => url,
      "srv_send_msg" => false
    }

    url =
      case response.session_type do
        :group -> "https://api.bot.qq.com/v2/groups/#{response.session_id}/files"
        :c2c -> "https://api.bot.qq.com/v2/users/#{response.session_id}/files"
      end

    case Req.post(url, headers: headers, json: body, finch: [name: LawnBot.Finch, pool_tag: name]) do
      {:ok, %Req.Response{status: 200, body: %{"file_info" => file_info}}}
      when is_binary(file_info) ->
        file_info

      {:ok, %Req.Response{status: 400, body: %{"message" => message}}} ->
        Logger.warning("Failed to upload attachment: #{message}")
        nil

      {:error, reason} ->
        Logger.warning("Failed to upload attachment: #{inspect(reason)}")
        nil
    end
  end
end
