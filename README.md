# LawnBot

基于 Elixir 的聊天机器人框架。当前提供 **QQ 官方机器人平台** 的 WebSocket 接入：获取 access_token、按平台建议的分片数建立多条网关连接、事件订阅（Intents）、心跳与断线恢复。

## 快速开始

### 环境要求

- Elixir 1.20，Erlang/OTP 29
- QQ 开放平台（[q.qq.com](https://q.qq.com)），获取 `AppID` 与 `ClientSecret`

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
        # name: "LawnBot",
        # os: "Windows NT",
        # browser: "LawnBot",
        # device: "LawnBot"
        # 消息处理器，可以为：
        # 1. 一个实现了 LawnBot.Handler 的模块
        # 2. 一个函数
        handler: {}
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

### 测试

```bash
mix test
mix credo  # 代码风格，也可加 `--format json`获取 JSON 格式输出
mix format # 代码格式化
mix docs   # 生成 ExDoc 文档
```
