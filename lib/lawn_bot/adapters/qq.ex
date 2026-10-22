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

  alias LawnBot.Adapters.QQ.Coordinator
  alias LawnBot.Adapters.QQ.TokenStore
  alias LawnBot.Event.Content

  require Logger

  @type config() :: %{
          required(:app_id) => String.t(),
          required(:client_secret) => String.t(),
          optional(:name) => String.t(),
          optional(:os) => String.t(),
          optional(:browser) => String.t(),
          optional(:device) => String.t(),
          optional(:intents) => non_neg_integer() | [atom()],
          optional(:shards) => pos_integer(),
          optional(:handler) =>
            {:func, (LawnBot.Event.t() -> LawnBot.Reply.t())}
            | {:module, module()}
            | {:via_session_id, map()}
            | {:via_func, fun()}
        }

  @type token() :: %{access_token: String.t(), expires_in: pos_integer()}

  @doc """
  启动 QQ 适配器监督树，并在其下拉起负责 access token 与分片管理的 Coordinator。

  未配置 `app_id` / `client_secret`（例如环境变量缺失导致的空字符串）时返回
  `:ignore`，避免用无效凭据反复请求网关。
  """
  @spec start_link(config()) :: {:ok, pid()} | {:error, term()} | :ignore
  def start_link(%{app_id: app_id, client_secret: client_secret} = config)
      when is_binary(app_id) and is_binary(client_secret) and app_id != "" and client_secret != "",
      do: Supervisor.start_link(__MODULE__, config, name: via_tuple(config.app_id))

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
    Logger.info("Starting #{bot_name(config)}")
    tid = TokenStore.new()

    children = [
      {Task.Supervisor, name: task_supervisor_name(config.app_id)},
      {Finch.Pool,
       finch: LawnBot.Finch,
       pool: Finch.Pool.new("https://api.bot.qq.com", tag: config.app_id),
       size: Map.get(config, :shards, 1)},
      {DynamicSupervisor,
       strategy: :one_for_one,
       max_restarts: 3,
       max_seconds: 30,
       name: shard_supervisor_name(config.app_id)},
      {Coordinator, {config, tid}}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 30)
  end

  @doc "Coordinator 进程在 Registry 中的名字。"
  @spec coordinator_name(String.t()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), String.t()}}}
  def coordinator_name(app_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {Coordinator, app_id}}}

  @doc "分片监督树的名字，用于 `DynamicSupervisor.which_children/1` 等。"
  @spec shard_supervisor_name(String.t()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), String.t()}}}
  def shard_supervisor_name(app_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, app_id}}}

  @doc "任务监督树的名字。"
  @spec task_supervisor_name(String.t()) ::
          {:via, Registry, {LawnBot.AdapterRegistry, {module(), String.t()}}}
  def task_supervisor_name(app_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, app_id}}}

  @doc "机器人名称，用于日志输出。形如 `QQ Bot: <name>`，若未配置 `:name` 则使用 `app_id`。"
  @spec bot_name(config()) :: String.t()
  def bot_name(config), do: "QQ Bot: #{Map.get(config, :name) || config.app_id}"

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
  @spec via_tuple(String.t()) :: {:via, Registry, {Registry.registry(), {module(), String.t()}}}
  # 适配器监督树在 Registry 中的名字。
  defp via_tuple(app_id), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, app_id}}}
end
