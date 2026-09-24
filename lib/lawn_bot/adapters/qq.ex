defmodule LawnBot.Adapters.QQ do
  @moduledoc """
  QQ 机器人适配器：一个管理 WebSocket 分片连接的 DynamicSupervisor。

  生命周期：

  1. 本模块作为 DynamicSupervisor 挂在 `LawnBot.AdapterSupervisor` 下；
  2. 启动时先拉起 `LawnBot.Adapters.QQ.Coordinator` 子进程；
  3. Coordinator 获取 access_token，并调用 `GET /gateway/bot` 拿到网关地址与建议分片数；
  4. 拿到 token 后在本监督树下按分片数启动 `LawnBot.Adapters.QQ.Shard` 连接进程，
     由各分片自行完成 Identify/Resume、心跳与事件订阅。

  分片规则参考 QQ 机器人文档「分片连接 LoadBalance」：Identify 时携带 `shard: [id, total]`，
  同一频道的事件固定落在 `(guild_id >>> 22) % total` 对应的连接上，因此必须启动全部分片
  才能完整接收事件。

  ## 配置

  以 `config :lawn_bot, :gateways, qq: [config]` 传入，支持的键：

  - `:app_id` / `:client_secret` - 必填，用于获取 access_token；
  - `:intents` - 整数或意图原子列表，如 `[:guilds, :group_and_c2c]`，
      默认 `[:guilds, :guild_members, :public_guild_messages]`（仅默认有权限的事件）；
  - `:shards` - 覆盖 `/gateway/bot` 返回的建议分片数；
  - `:event_handler` - 事件接收方，pid、已注册进程名或 `fun/1`，
      事件以 `{:lawn_bot_event, event}` 消息投递；
  """

  use DynamicSupervisor
  require Logger

  alias LawnBot.Utils.HTTP

  @token_url "https://api.bot.qq.com/app/getAppAccessToken"
  @gateway_url "https://api.bot.qq.com/gateway/bot"
  @plain_gateway_url "https://api.bot.qq.com/gateway"

  # 事件订阅 intents 位定义，来自 QQ 机器人文档「事件订阅Intents」（1 << n）。
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

  @type config :: %{
          required(:app_id) => String.t(),
          required(:client_secret) => String.t(),
          optional(atom()) => term()
        }
  @type token :: %{access_token: String.t(), expires_in: pos_integer()}
  @type shard_index :: non_neg_integer()
  # 分片参数形如 [shard_id, shard_count]，见 QQ 机器人文档 Identify 载荷。
  @type shard :: [shard_index()]
  @type gateway :: %{
          url: String.t(),
          shards: pos_integer(),
          max_concurrency: pos_integer(),
          remaining: non_neg_integer() | nil
        }

  @doc """
  启动 QQ 适配器监督树，并在其下拉起负责 access token 与分片管理的 Coordinator。

  未配置 `app_id` / `client_secret`（例如环境变量缺失导致的空字符串）时返回
  `:ignore`，避免用无效凭据反复请求网关。
  """
  @spec start_link(config()) :: {:ok, pid()} | {:error, term()} | :ignore
  def start_link(%{app_id: app_id, client_secret: client_secret} = config)
      when is_binary(app_id) and is_binary(client_secret) and app_id != "" and client_secret != "" do
    Logger.info("Starting QQ adapter, app id: #{app_id}")

    with {:ok, pid} <- DynamicSupervisor.start_link(__MODULE__, config, name: via(config)),
         {:ok, _pid} <- start_coordinator(pid, config) do
      {:ok, pid}
    end
  end

  def start_link(_config) do
    Logger.warning("Skipping QQ adapter: no app_id or client_secret set.")
    :ignore
  end

  @impl true
  def init(_config),
    # 单个分片反复崩溃时让整棵 QQ 适配器树重启，而不是无限拉起坏掉的连接。
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 5)

  defp start_coordinator(supervisor_pid, config) do
    spec = {LawnBot.Adapters.QQ.Coordinator, {supervisor_pid, config}}

    case DynamicSupervisor.start_child(supervisor_pid, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start QQ coordinator: #{inspect(reason)}")
        DynamicSupervisor.stop(supervisor_pid, :shutdown)
        {:error, reason}
    end
  end

  @doc "适配器监督树在 Registry 中的名字。"
  def via(config), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, app_id(config)}}}

  @doc "Coordinator 进程在 Registry 中的名字。"
  def coordinator_name(config),
    do:
      {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.Coordinator, app_id(config)}}}

  # 指定分片连接进程在 Registry 中的 key。
  defp shard_registry_key(config, shard_id),
    do: {LawnBot.Adapters.QQ.Shard, app_id(config), shard_id}

  @doc "指定分片连接进程在 Registry 中的名字。"
  def shard_name(config, shard_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, shard_registry_key(config, shard_id)}}

  @doc "当前配置对应的机器人 AppID。"
  @spec app_id(config()) :: String.t()
  def app_id(config), do: Map.fetch!(config, :app_id)

  @doc """
  当前存活的分片进程，供 Coordinator 广播 token 刷新等消息。

  通过 Registry 查找而不是缓存 pid，分片被监督树重启后仍然能找到新进程。
  """
  @spec shard_pids(config(), pos_integer()) :: [pid()]
  def shard_pids(config, shard_count) do
    for shard_id <- 0..(shard_count - 1),
        [{pid, _}] <- [
          Registry.lookup(LawnBot.AdapterRegistry, shard_registry_key(config, shard_id))
        ],
        do: pid
  end

  @doc """
  获取机器人 access_token。

  注意：QQ 的业务错误可能仍返回 HTTP 200，需要以响应体中的 `code` 判断成败。
  """
  @spec fetch_access_token(config()) :: {:ok, token()} | {:error, term()}
  def fetch_access_token(%{app_id: app_id, client_secret: client_secret}) do
    case HTTP.json_request(:post, @token_url, [], %{appId: app_id, clientSecret: client_secret}) do
      {:ok, %{"access_token" => access_token, "expires_in" => expires_in}}
      when is_binary(access_token) ->
        case positive_integer(expires_in) do
          {:ok, expires_in} -> {:ok, %{access_token: access_token, expires_in: expires_in}}
          :error -> {:error, {:invalid_expires_in, expires_in}}
        end

      {:ok, %{"code" => code, "message" => message}} ->
        {:error, {:qq_api, code, message}}

      {:ok, response} ->
        {:error, {:unexpected_token_response, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  获取带分片信息的 WSS 接入点（`GET /gateway/bot`）。

  返回值中的 `shards` 是平台建议的分片数，`max_concurrency` 与 `remaining`
  来自 `session_start_limit`，分别用于 Identify 限速与连接数提醒。
  无 `/gateway/bot` 权限时回退到不分片的 `GET /gateway`。
  """
  @spec fetch_gateway(String.t(), config()) :: {:ok, gateway()} | {:error, term()}
  def fetch_gateway(access_token, config) do
    headers = [{"Authorization", "QQBot #{access_token}"}]

    case HTTP.request(:get, @gateway_url, headers) do
      {:ok, %{"url" => url} = body} when is_binary(url) ->
        {:ok, parse_gateway(url, body, config)}

      sharded_error ->
        case HTTP.request(:get, @plain_gateway_url, headers) do
          {:ok, %{"url" => url} = body} when is_binary(url) ->
            {:ok, parse_gateway(url, body, config)}

          plain_error ->
            {:error, {:gateway_unavailable, sharded_error, plain_error}}
        end
    end
  end

  @doc """
  解析网关响应。抽出为纯函数以便单元测试。
  """
  @spec parse_gateway(String.t(), map(), config()) :: gateway()
  def parse_gateway(url, body, config) do
    limit = Map.get(body, "session_start_limit") || %{}
    shards = positive_int(Map.get(config, :shards) || body["shards"], 1)

    %{
      url: url,
      shards: shards,
      max_concurrency: positive_int(limit["max_concurrency"], 1),
      remaining: non_negative_int(limit["remaining"])
    }
  end

  @doc """
  计算本次连接订阅的 intents 位掩码。

  `:intents` 可以直接给整数，也可以给意图原子列表；未知意图会被忽略并告警，
  因为携带无权限的 intents 会导致网关直接关闭连接。
  """
  @spec intents(config()) :: non_neg_integer()
  def intents(config) do
    config
    |> Map.get(:intents, @default_intents)
    |> normalize_intents()
  end

  defp normalize_intents(intents) when is_integer(intents) and intents >= 0, do: intents

  defp normalize_intents(intents) when is_list(intents) do
    Enum.reduce(intents, 0, fn intent, acc ->
      case Map.fetch(@intents, intent) do
        # 各 intents 位互不重叠，相加等价于按位或。
        {:ok, bit} -> acc + bit
        :error -> Logger.warning("Ignoring unknown QQ intent: #{inspect(intent)}")
      end
    end)
  end

  defp normalize_intents(other) do
    Logger.warning("Ignoring invalid QQ intents: #{inspect(other)}")
    normalize_intents(@default_intents)
  end

  @doc """
  构造 OpCode 2 Identify 载荷，携带分片参数以启用水平分片。
  """
  @spec identify_payload(String.t(), config(), shard()) :: map()
  def identify_payload(access_token, config, shard) do
    %{
      "op" => 2,
      "d" => %{
        "token" => token(access_token),
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

  @doc """
  构造 OpCode 6 Resume 载荷，用 session_id 与 seq 补发断线期间遗漏的事件。
  """
  @spec resume_payload(String.t(), String.t(), non_neg_integer() | nil) :: map()
  def resume_payload(access_token, session_id, seq) do
    %{
      "op" => 6,
      "d" => %{
        "token" => token(access_token),
        "session_id" => session_id,
        "seq" => seq
      }
    }
  end

  defp token(access_token), do: "QQBot #{access_token}"

  @doc """
  将网关 Dispatch 载荷标准化为内部事件结构。

  保留 `raw` 原始数据，便于后续处理新增的 QQ 事件字段。
  """
  @spec event(map(), shard()) :: map()
  def event(payload, shard) when is_map(payload) do
    %{
      platform: :qq,
      shard: shard,
      type: payload["t"],
      data: payload["d"],
      seq: payload["s"],
      raw: payload
    }
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp positive_integer(_value), do: :error

  # 网关文档中的数字字段可能以字符串返回，统一转成正整数，缺省回退到 default。
  defp positive_int(value, default) do
    case positive_integer(value) do
      {:ok, integer} -> integer
      :error -> default
    end
  end

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_int(_value), do: nil
end
