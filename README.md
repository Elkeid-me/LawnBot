# LawnBot

基于 Elixir 的聊天机器人框架。当前提供 **QQ 官方机器人平台** 的 WebSocket 接入：获取 access_token、按平台建议的分片数建立多条网关连接、完成事件订阅（Intents）、心跳与断线恢复。

## 特性

- **OTP 监督树**：适配器统一挂在 `LawnBot.AdapterSupervisor` 下，单个平台/机器人的故障互不影响。
- **QQ 网关分片**：适配器本身是一个 `DynamicSupervisor`，按 `GET /gateway/bot` 返回的建议分片数拉起多个连接进程，支持多机器人（多组 `app_id`）并存。
- **完整网关协议**：Identify / Resume、心跳与 ACK 超时检测、Op7 重连、Op9 会话失效重建、指数退避重连。
- **凭证自动维护**：access_token 在过期前 60 秒自动刷新并广播给全部分片。

## 架构

### 监督树

```
LawnBot.Supervisor
├── LawnBot.AdapterRegistry            # Registry，按 {平台, app_id, 分片号} 定位进程
└── LawnBot.AdapterSupervisor          # DynamicSupervisor，管理各平台适配器
    └── LawnBot.Adapters.QQ            # DynamicSupervisor，单个机器人的适配器根
        ├── QQ.Coordinator             # 引导与维护：token、网关地址、分片启停
        └── QQ.Shard * N               # 每个分片一条 WebSocket 连接
```

启动流程：`LawnBot.Application` 读取 `:gateways` 配置 → `AdapterSupervisor.start_adapter/2` 启动适配器 → `QQ.Coordinator` 获取 access_token 与 `GET /gateway/bot` → 在适配器的 `DynamicSupervisor` 下启动 `0..shards - 1` 等分片。

模块职责：`LawnBot.Application` 负责应用入口，`LawnBot.AdapterSupervisor` 负责平台适配器，`QQ` 负责单个机器人的监督树与共享协议值，`QQ.Coordinator` 负责引导和 token 生命周期，`QQ.Shard` 负责单条 WebSocket 连接及网关协议。

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
```

### 配置

复制 `config/runtime-template.exs` 并更名为已在 `config/runtime.exs` 中。

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
      }
    ]
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
mix docs                            # 生成 ExDoc 文档
```
