defmodule LawnBot.Adapters.QQ do
  @moduledoc """
  QQ 机器人适配器：一个管理 WebSocket 分片连接的 DynamicSupervisor。

  生命周期：

  1. 本模块作为 DynamicSupervisor 挂在 `LawnBot.AdapterSupervisor` 下；
  2. 启动时先拉起 `LawnBot.Adapters.QQ.Coordinator` 子进程；
  3. Coordinator 获取 access_token，并调用 `GET /gateway/bot` 拿到网关地址与建议分片数；
  4. 拿到 token 后在本监督树下按分片数启动 `LawnBot.Adapters.QQ.Shard` 连接进程，
     由各分片自行完成 Identify/Resume、心跳与事件订阅。

  ## 配置

  以 `config :lawn_bot, :gateways, qq: [config]` 传入，支持的键：

  - `:app_id` / `:client_secret` - 必填，用于获取 access_token；
  - `:intents` - 整数或意图原子列表，如 `[:guilds, :group_and_c2c]`，
      默认 `[:guilds, :guild_members, :public_guild_messages]`（仅默认有权限的事件）；
  - `:shards` - 覆盖 `/gateway/bot` 返回的建议分片数；
  - `:os` / `:browser` / `:device` - Identify 时的客户端信息，默认分别为当前 OS、"LawnBot"、"LawnBot"。
  """

  use DynamicSupervisor
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
      when is_binary(app_id) and is_binary(client_secret) and app_id != "" and client_secret != "" do
    Logger.info("Starting")
    Logger.info("Starting #{bot_name(config)}")

    with {:ok, pid} <- DynamicSupervisor.start_link(__MODULE__, config, name: via_tuple(app_id)),
         {:ok, _pid} <- start_coordinator(pid, config) do
      {:ok, pid}
    end
  end

  def start_link(_config) do
    Logger.warning("Skipping QQ adapter: no app_id or client_secret set.")
    :ignore
  end

  @impl true
  def init(_init_arg),
    # 单个分片反复崩溃时让整棵 QQ 适配器树重启，而不是无限拉起坏掉的连接。
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 5)

  @doc "获取 Shard 在 Registry 中的名字，供 Coordinator 广播 token 刷新等消息。"
  @spec shard_registry_key(String.t(), non_neg_integer()) ::
          {module(), String.t(), non_neg_integer()}
  def shard_registry_key(app_id, shard_id), do: {__MODULE__, app_id, shard_id}

  @doc """
  构造机器人 token。形如 `QQBot <access_token>`。
  """
  @spec token(String.t()) :: String.t()
  def token(access_token), do: "QQBot #{access_token}"

  @spec bot_name(config()) :: String.t()
  def bot_name(config), do: "QQ Bot: #{Map.get(config, :name) || config.app_id}"

  # 适配器监督树在 Registry 中的名字。
  defp via_tuple(app_id), do: {:via, Registry, {LawnBot.AdapterRegistry, {__MODULE__, app_id}}}

  @spec start_coordinator(pid(), config()) :: {:ok, pid()} | {:error, term()}
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
end
