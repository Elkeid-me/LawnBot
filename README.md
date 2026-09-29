# LawnBot

基于 Elixir 的聊天机器人框架。当前提供 **QQ 官方机器人平台** 的 WebSocket 接入：获取 access_token、按平台建议的分片数建立多条网关连接、事件订阅（Intents）、心跳与断线恢复。

## 架构

```
LawnBot.Supervisor
├── LawnBot.AdapterRegistry            # Registry，按 {平台, app_id, 分片号} 定位进程
└── LawnBot.AdapterSupervisor          # DynamicSupervisor，管理各平台适配器
    └── LawnBot.Adapters.QQ            # DynamicSupervisor，单个机器人的适配器根
        ├── QQ.Coordinator             # 引导与维护：token、网关地址、分片启停
        └── QQ.Shard × N               # 每个分片一条 WebSocket 连接
```

启动流程：`LawnBot.Application` 读取 `:gateways` 配置 → `AdapterSupervisor.start_adapter/2` 启动适配器 → `QQ.Coordinator` 获取 access_token 与 `GET /gateway/bot` → 在适配器的 `DynamicSupervisor` 下启动 `0..shards - 1` 等分片。

模块职责：`LawnBot.Application` 负责应用入口，`LawnBot.AdapterSupervisor` 负责平台适配器，`QQ` 负责单个机器人的监督树与共享协议值，`QQ.Coordinator` 负责引导和 token 生命周期，`QQ.Shard` 负责单条 WebSocket 连接及网关协议。

## 快速开始

### 环境要求

- Elixir 1.20，Erlang/OTP 29
- QQ 开放平台的机器人应用（[bot.q.qq.com](https://bot.q.qq.com/open)），拿到 `AppID` 与 `ClientSecret`

### 配置

复制 `config/runtime-template.exs` 并更名为 `config/runtime.exs` 。

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
        # 可选：客户端信息
        # os: "nt",
        # browser: "LawnBot",
        # device: "LawnBot"
      }
    ]
  }
```

### 运行

```bash
mix deps.get
export MIX_ENV=prod
mix release
_build/prod/rel/lawn_bot/bin/lawn_bot start
```

启动后会依次看到：`Starting QQ adapter` → `QQ gateway for app ... (shards=N)` → `QQ adapter ... started N/N shard(s)` → 各分片 `READY`。

### 测试

```bash
mix test
mix format --check-formatted        # 代码风格
mix docs                            # 生成 ExDoc 文档
```
