# LawnBot

基于 Elixir 的聊天机器人框架。当前提供 **QQ 官方机器人平台** 的 WebSocket 接入：获取 access_token、按平台建议的分片数建立多条网关连接、完成事件订阅（Intents）、心跳与断线恢复，并把标准化后的事件投递给你的业务进程。

## 特性

- **OTP 监督树**：适配器统一挂在 `LawnBot.AdapterSupervisor` 下，单个平台/机器人的故障互不影响。
- **QQ 网关分片**：适配器本身是一个 `DynamicSupervisor`，按 `GET /gateway/bot` 返回的建议分片数拉起多个连接进程，支持多机器人（多组 `app_id`）并存。
- **完整网关协议**：Identify / Resume、心跳与 ACK 超时检测、Op7 重连、Op9 会话失效重建、指数退避重连。
- **凭证自动维护**：access_token 在过期前 60 秒自动刷新并广播给全部分片。
- **平台无关的事件**：网关事件标准化为 `%{platform, shard, type, data, seq, raw}`，业务侧无需关心协议细节。
- **零配置也能启动**：缺少凭据时适配器优雅跳过，不会带着无效凭据反复请求网关。

## 架构

### 监督树

```
LawnBot.Supervisor
├── LawnBot.AdapterRegistry            # Registry，按 {平台, app_id, 分片号} 定位进程
└── LawnBot.AdapterSupervisor          # DynamicSupervisor，管理各平台适配器
    └── LawnBot.Adapters.QQ            # DynamicSupervisor，单个机器人的适配器根
        ├── QQ.Coordinator             # 引导与维护：token、网关地址、分片启停
        └── QQ.Shard × N               # 每个分片一条 WebSocket 连接
```

启动流程：`LawnBot.Application` 读取 `:gateways` 配置 → `AdapterSupervisor.start_adapter/2` 启动适配器 → `QQ.Coordinator` 获取 access_token 与 `GET /gateway/bot` → 在适配器的 `DynamicSupervisor` 下启动 `0..shards-1` 个分片。

### 事件流

```
QQ 网关 ──wss──▶ QQ.Shard（协议循环）
                    │  标准化事件
                    ▼
          {:lawn_bot_event, event}  ──▶  :event_handler（pid / 注册名 / fun/1）
```

### QQ 网关实现细节

| 能力 | 实现 |
| --- | --- |
| 鉴权 | Op10 Hello → 按 `max_concurrency` 错峰发送 Op2 Identify（携带 `shard: [id, total]`、`intents`） |
| 分片 | 分片数取自 `/gateway/bot` 的 `shards`，可用 `:shards` 覆盖；分片规则 `(guild_id >> 22) % num_shards` |
| 心跳 | 按 Hello 给出的周期发送 Op1 并携带最新 `s`；上一次未收到 Op11 ACK 则主动断开重连 |
| 恢复 | READY 保存 `session_id`、Dispatch 记录 `seq`，重连时发送 Op6 Resume 补发遗漏事件 |
| 异常 | Op7 直接重连、Op9 丢弃会话重新 Identify、断线按 1s→60s 指数退避 |
| 凭证 | Coordinator 在 `expires_in - 60s` 刷新 token，广播 `{:qq_token_updated, token}` 给全部分片 |

## 快速开始

### 环境要求

- Elixir ~> 1.20（开发环境为 Erlang/OTP 29）
- QQ 开放平台的机器人应用（[bot.q.qq.com](https://bot.q.qq.com/open)），拿到 `AppID` 与 `ClientSecret`

### 安装

```bash
mix deps.get
mix compile
```

### 配置

`config/runtime.exs` 已在 `.gitignore` 中（包含凭据，不入库），首次使用请自行创建：

```elixir
import Config

config :lawn_bot,
  gateways: %{
    qq: [
      %{
        app_id: System.get_env("QQ_APP_ID", ""),
        client_secret: System.get_env("QQ_CLIENT_SECRET", ""),
        # 可选：事件订阅，默认只订阅平台默认有权限的三类事件
        intents: [:guilds, :guild_members, :public_guild_messages],
        # 可选：覆盖 /gateway/bot 建议的分片数
        # shards: 4,
        # 可选：事件接收方，见下文「接收事件」
        # event_handler: MyBot.Handler
      }
    ],
    lark: []
  }
```

### 运行

```bash
$env:QQ_APP_ID = "你的AppID"        # PowerShell
$env:QQ_CLIENT_SECRET = "你的Secret"
mix run --no-halt
```

启动后会依次看到：`Starting QQ adapter` → `QQ gateway for app ... (shards=N)` → `QQ adapter ... started N/N shard(s)` → 各分片 `READY`。

### 测试

```bash
mix test
mix format --check-formatted        # 代码风格
```

## 配置项

`gateways.qq` 中每个机器人一份配置，支持的键：

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `:app_id` | string | 必填 | 机器人 AppID，同时作为进程注册 key |
| `:client_secret` | string | 必填 | 机器人 ClientSecret，缺失或为空时跳过启动 |
| `:intents` | integer \| [atom] | `[:guilds, :guild_members, :public_guild_messages]` | 事件订阅位掩码；未知意图会被忽略并告警 |
| `:shards` | integer | 平台建议值 | 覆盖 `/gateway/bot` 返回的分片数 |
| `:event_handler` | pid \| atom \| fun/1 | 仅记录日志 | 事件接收方，见下文 |
| `:ws_token_format` | string | `"QQBot {token}"` | Identify/Resume 的 token 模板，可配 `"Bot {appid}.{token}"` |
| `:os` / `:browser` / `:device` | string | 当前系统 / `"lawn_bot"` | Identify 的 `properties` 字段 |

可用的 intents 原子（即文档中的位定义）：`guilds`、`guild_members`、`guild_messages`、`guild_message_reactions`、`direct_message`、`group_and_c2c`、`interaction`、`message_audit`、`forums_event`、`audio_action`、`public_guild_messages`。

> 注意：除 `guilds`、`guild_members`、`public_guild_messages` 外的事件类型需要在开放平台申请权限，携带无权限的 intents 会导致网关直接关闭连接。

## 接收事件

事件统一为如下结构：

```elixir
%{
  platform: :qq,                      # 平台标识
  shard: [0, 2],                      # 来自哪个分片
  type: "GROUP_AT_MESSAGE_CREATE",    # 网关事件类型（t）
  data: %{"id" => "...", ...},        # 事件内容（d）
  seq: 42,                            # 序列号（s）
  raw: %{...}                         # 原始载荷
}
```

`event_handler` 支持三种形式，事件以 `{:lawn_bot_event, event}` 消息投递：

```elixir
defmodule MyBot.Handler do
  use GenServer

  # 1) 注册名：配置 event_handler: MyBot.Handler（GenServer 需以该名字注册）
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:lawn_bot_event, event}, state) do
    case event do
      %{type: "GROUP_AT_MESSAGE_CREATE", data: data} ->
        reply_to_group(data)   # 用 LawnBot.Utils.HTTP 调 OpenAPI 回消息

      %{type: "READY"} ->
        :ok

      _other ->
        :ok
    end

    {:noreply, state}
  end
end
```

也可以直接给一个 pid（`event_handler: self()` 或某进程）、或者 `fun/1`（`event_handler: &Logger.debug/1`）。

发送消息等 API 调用可以复用 `LawnBot.Utils.HTTP`（基于 `:httpc` 的 JSON 客户端），请求头带 `Authorization: QQBot {ACCESS_TOKEN}` 即可。

## 扩展新平台

1. 新增 `LawnBot.Adapters.<平台>`，按需实现为 `GenServer` 或 `DynamicSupervisor`；
2. 在 `LawnBot.AdapterSupervisor.adapter_child_spec/2` 中登记平台与配置的映射；
3. 在 `config/runtime.exs` 的 `gateways` 中加入该平台配置即可被自动拉起。

QQ 的实现（`lib/lawn_bot/adapters/qq/`）可以作为参考模板。

## 项目结构

```
lib/
├── lawn_bot/
│   ├── application.ex            # 应用入口：Registry、AdapterSupervisor、按配置拉起适配器
│   ├── adapter_supervisor.ex     # 适配器根 DynamicSupervisor
│   ├── adapters/
│   │   ├── qq.ex                 # QQ 适配器：分片 DynamicSupervisor + 平台协议（token/网关/载荷）
│   │   └── qq/
│   │       ├── coordinator.ex    # 引导与 token 维护、分片生命周期
│   │       └── shard.ex          # 单分片 WebSocket 连接（WebSockex）
│   └── utils/
│       └── http.ex               # 供适配器使用的 HTTPS JSON 客户端（:httpc）
config/
└── runtime.exs                   # 运行时配置（本地，已 gitignore）
test/
├── lawn_bot_test.exs             # 适配器纯函数：载荷、intents、网关解析、事件标准化
└── qq_shard_test.exs             # 分片协议循环：Hello/READY/Resume/心跳/异常分支
```

## 依赖

- [jason](https://hex.pm/packages/jason) — JSON 编解码
- [websockex](https://hex.pm/packages/websockex) — WebSocket 客户端
- `:inets`（`:httpc`）— HTTP 请求，无额外依赖

## 参考文档

- [QQ 机器人官方文档 · 使用 Websocket 接入](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/reference.html)
- [QQ 机器人官方文档 · 事件订阅与通知（Intents / 分片 LoadBalance）](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/event-emit.html)
- [QQ 机器人官方文档 · opcode](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/interface-framework/opcode.html)
- [QQ 机器人官方文档 · 获取带分片 WSS 接入点](https://bot.q.qq.com/wiki/develop/api-v2/openapi/wss/shard_url_get.html)
- [QQ 机器人官方文档 · 获取访问凭证](https://bot.q.qq.com/wiki/develop/api-v2/dev-prepare/access-token.html)
