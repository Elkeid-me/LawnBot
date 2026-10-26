defmodule LawnBot.Adapters.QQ do
  @moduledoc """
  QQ 机器人适配器。

  ## 配置

  以 `config :lawn_bot, :gateways, qq: [config]` 传入，支持的键：

  - `:app_id` / `:client_secret` - 必填，用于获取 access_token；
  - `:intents` - 整数或意图原子列表，如 `[:guilds, :group_and_c2c]`，
      默认 `[:guilds, :guild_members, :public_guild_messages]`（仅默认有权限的事件）；
  - `:shards` - 覆盖 `/gateway/bot` 返回的建议分片数；
  - `:os` / `:browser` / `:device` - Identify 时的客户端信息，默认分别为当前 OS、"LawnBot"、"LawnBot"。
  """

  use Supervisor

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ.Coordinator
  alias LawnBot.Adapters.QQ.TokenStore
  alias LawnBot.Event.Content

  require Logger

  @type config() :: %{
          required(:app_id) => String.t(),
          required(:client_secret) => String.t(),
          required(:name) => atom(),
          required(:handler) =>
            {:func, (LawnBot.Event.t() -> LawnBot.Reply.t())}
            | {:module, module()},
          optional(:os) => String.t(),
          optional(:browser) => String.t(),
          optional(:device) => String.t(),
          optional(:intents) => [atom()],
          optional(:shards) => pos_integer()
        }

  @type token() :: %{access_token: String.t(), expires_in: pos_integer()}

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

  @doc """
  启动 QQ 适配器监督树，并在其下拉起负责 access token 与分片管理的 Coordinator。

  未配置 `app_id` / `client_secret`（例如环境变量缺失导致的空字符串）时返回
  `:ignore`，避免用无效凭据反复请求网关。
  """
  @spec start_link(config()) :: {:ok, pid()} | {:error, term()} | :ignore
  def start_link(%{app_id: app_id, client_secret: client_secret, name: name} = config)
      when is_binary(app_id) and is_binary(client_secret) and is_atom(name) and app_id != "" and
             client_secret != "",
      do: Supervisor.start_link(__MODULE__, config, name: via_tuple(name))

  def start_link(_config) do
    Logger.warning("Skipping QQ adapter: no app_id or client_secret set.")
    :ignore
  end

  def child_spec(%{app_id: app_id} = config) do
    %{
      id: {__MODULE__, app_id},
      start: {__MODULE__, :start_link, [config]}
    }
  end

  @impl true
  def init(config) do
    Logger.info("Starting #{bot_name(config.name)}")
    tid = TokenStore.new()

    case Map.get(config, :handler) do
      nil ->
        PersistentTerm.put(config.name, fn x -> x end)
        Logger.debug("No handler configured for #{bot_name(config.name)}")

      {:func, handler} when is_function(handler) ->
        PersistentTerm.put(config.name, handler)

      {:module, module} when is_atom(module) ->
        PersistentTerm.put(config.name, fn event ->
          apply(module, :handle_event, [event])
        end)
    end

    PersistentTerm.put({config.name, :app_id}, Map.get(config, :app_id))
    PersistentTerm.put({config.name, :client_secret}, Map.get(config, :client_secret))

    intents = config |> Map.get(:intents, @default_intents) |> normalize_intents()

    PersistentTerm.put({config.name, :intents}, intents)
    PersistentTerm.put({config.name, :shards}, Map.get(config, :shards, 1))

    PersistentTerm.put({config.name, :os}, Map.get(config, :os, to_string(elem(:os.type(), 1))))
    PersistentTerm.put({config.name, :browser}, Map.get(config, :browser, "LawnBot"))
    PersistentTerm.put({config.name, :device}, Map.get(config, :device, "LawnBot"))

    children = [
      {Task.Supervisor, name: task_supervisor_name(config.name)},
      {Finch.Pool,
       finch: LawnBot.Finch,
       pool: Finch.Pool.new("https://api.bot.qq.com", tag: config.name),
       size: Map.get(config, :shards, 1) * 16},
      {DynamicSupervisor,
       strategy: :one_for_one,
       max_restarts: 3,
       max_seconds: 30,
       name: shard_supervisor_name(config.name)},
      {Coordinator, {config.name, tid}}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 30)
  end

  @doc "Coordinator 进程在 Registry 中的名字。"
  @spec coordinator_name(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def coordinator_name(bot_name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {Coordinator, bot_name}}}

  @doc "分片监督树的名字，用于 `DynamicSupervisor.which_children/1` 等。"
  @spec shard_supervisor_name(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def shard_supervisor_name(bot_name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, bot_name}}}

  @doc "任务监督树的名字。"
  @spec task_supervisor_name(module()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), module()}}}
  def task_supervisor_name(bot_name),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, bot_name}}}

  @doc "机器人名称，用于日志输出。形如 `QQ Bot: <name>`。"
  @spec bot_name(atom()) :: String.t()
  def bot_name(name), do: "QQ Bot: #{to_string(name)}"

  @doc "将 QQ 网关事件 payload 转换为 LawnBot 事件结构体。"
  @spec to_event(map()) :: LawnBot.Event.t()
  def to_event(payload) do
    data = payload["d"]
    {message_type, session_type} = extract_event_type(payload)
    message_id = data["id"]
    session_id = extract_session_id(data, session_type)
    author_id = extract_author_id(data, session_type)
    content = extract_content(data)

    %LawnBot.Event{
      session_type: session_type,
      session_id: session_id,
      message_type: message_type,
      message_id: message_id,
      author_id: author_id,
      content: content,
      extra: nil
    }
  end

  @spec extract_event_type(map()) ::
          {:normal | :new_friend | :delete_friend | nil, :group | :c2c | nil}
  defp extract_event_type(%{"t" => "C2C_MESSAGE_CREATE"}), do: {:normal, :c2c}
  defp extract_event_type(%{"t" => "FRIEND_ADD"}), do: {:new_friend, :c2c}
  defp extract_event_type(%{"t" => "FRIEND_DEL"}), do: {:delete_friend, :c2c}
  defp extract_event_type(%{"t" => "GROUP_MESSAGE_CREATE"}), do: {:normal, :group}
  defp extract_event_type(%{"t" => "GROUP_AT_MESSAGE_CREATE"}), do: {:normal, :group}

  defp extract_event_type(%{"t" => type}) do
    Logger.warning("Unknown QQ event type: #{type}")
    {nil, nil}
  end

  @spec extract_session_id(map(), :c2c | :group | nil) :: String.t() | nil
  defp extract_session_id(data, :c2c), do: data["author"]["user_openid"]
  defp extract_session_id(data, :group), do: data["group_openid"]
  defp extract_session_id(_data, _), do: nil

  @spec extract_author_id(map(), :c2c | :group | nil) :: String.t() | nil
  defp extract_author_id(data, :c2c), do: data["author"]["user_openid"]
  defp extract_author_id(data, :group), do: data["author"]["member_openid"]
  defp extract_author_id(_data, _), do: nil

  @spec extract_content(map()) :: Content.t() | nil
  defp extract_content(%{"message_type" => 103} = data) do
    text = data["content"]
    attachments = extract_attachments(data)

    references =
      case data["msg_elements"] do
        nil -> nil
        references -> Enum.map(references, &extract_content/1)
      end

    %Content{
      text: text,
      attachments: attachments,
      references: references
    }
  end

  # 0：普通消息
  defp extract_content(%{"message_type" => 0} = data) do
    text = data["content"]
    attachments = extract_attachments(data)

    if attachments == nil do
      text
    else
      %Content{
        text: text,
        attachments: attachments,
        references: nil
      }
    end
  end

  defp extract_attachments(%{"attachments" => attachments}) when is_list(attachments),
    do:
      Enum.map(attachments, fn attachment ->
        %LawnBot.Event.Attachment{
          filename: attachment["filename"],
          mime_type: attachment["content_type"],
          size: attachment["size"],
          width: attachment["width"],
          height: attachment["height"],
          url: attachment["url"]
        }
      end)

  defp extract_attachments(_), do: nil

  # 计算连接的 intents 位掩码。
  #
  # `:intents` 可以给意图原子列表；未知意图会被忽略并告警，
  # 因为携带无权限的 intents 会导致网关直接关闭连接。
  @spec normalize_intents([atom()] | any()) :: non_neg_integer()
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

  @spec via_tuple(atom()) :: {:via, Registry, {Registry.registry(), {module(), atom()}}}
  # 适配器监督树在 Registry 中的名字。
  defp via_tuple(name), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, name}}}
end
