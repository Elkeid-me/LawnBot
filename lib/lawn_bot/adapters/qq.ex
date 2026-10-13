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
  require Logger

  @type config() :: %{
          required(:app_id) => String.t(),
          required(:client_secret) => String.t(),
          optional(:name) => String.t(),
          optional(:os) => String.t(),
          optional(:browser) => String.t(),
          optional(:device) => String.t(),
          optional(:intents) => non_neg_integer() | [atom()],
          optional(:shards) => pos_integer()
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

  @impl true
  def init(config) do
    children = [
      {LawnBot.Adapters.QQ.Coordinator, config},
      {DynamicSupervisor,
       strategy: :one_for_one,
       max_restarts: 3,
       max_seconds: 30,
       name: shard_supervisor_name(config.app_id)}
    ]

    Logger.info("Starting #{bot_name(config)}")
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 30)
  end

  @doc "返回分片监督树的名字，用于 `DynamicSupervisor.which_children/1` 等。"
  @spec shard_supervisor_name(String.t()) ::
          {:via, Registry, {Registry.registry(), {module(), String.t()}}}
  def shard_supervisor_name(app_id),
    do: {:via, Registry, {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, app_id}}}

  @doc "构造机器人 token。形如 `QQBot <access_token>`。"
  @spec token(String.t()) :: String.t()
  def token(access_token), do: "QQBot #{access_token}"

  @doc "机器人名称，用于日志输出。形如 `QQ Bot: <name>`，若未配置 `:name` 则使用 `app_id`。"
  @spec bot_name(config()) :: String.t()
  def bot_name(config), do: "QQ Bot: #{Map.get(config, :name) || config.app_id}"

  @spec via_tuple(String.t()) :: {:via, Registry, {Registry.registry(), {module(), String.t()}}}
  # 适配器监督树在 Registry 中的名字。
  defp via_tuple(app_id), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, app_id}}}
end
