# LawnBot

基于 Elixir 的聊天机器人框架。当前提供 QQ 官方机器人平台 的 WebSocket 接入。

## 快速开始

### 环境要求

- Elixir 1.20，Erlang/OTP 29
- QQ 开放平台（[q.qq.com](https://q.qq.com)），获取 `AppID` 与 `ClientSecret`

### 配置

复制 `config/runtime-template.exs` 并更名为 `config/runtime.exs`。以下为示例配置：

```elixir
import Config

config :lawn_bot,
  gateways: %{
    qq: [
      %{
        app_id: System.get_env("QQ_APP_ID", ""),
        client_secret: System.get_env("QQ_CLIENT_SECRET", ""),
        name: :LawnBot,
        intents: [:guilds, :guild_members, :public_guild_messages],
        handler: {:module, LawnBot.ExampleHandler}
      }
    ]
  }
```

1. `:app_id`（必需）字符串。QQ 开放平台获取的 APP ID。建议设置为环境变量。
2. `:client_secret`（必需）字符串。QQ 开放平台获取的 Client Secret。建议设置为环境变量。
3. `:name`（必需）Bot 的名称，必须为 `atom()` 类型。不同 Bot 的名称不能相同。
4. `:intents`（可选）`atom()` 列表。事件订阅，默认只订阅平台默认有权限的三类事件 `[:guilds, :guild_members, :public_guild_messages]`
5. `:shards`（可选）整数。覆盖 /gateway/bot 建议的分片数。
6. `:os`、`:browser`、`:device`（可选）客户端信息。
   - `:os` 字符串，无实际意义。默认为 `:os.type() |> elem(1) |> to_string()`，在 Linux 下为 `linux`，Windows 下为 `"nt"`
   - `:browser` 字符串，无实际意义。默认为 `"LawnBot"`。
   - `:device` 字符串，无实际意义。默认为 `"LawnBot"`。
7. `:handler`。消息处理器。可以为：
   - `:module` + 一个实现了 LawnBot.Handler 的模块。例：`{:module, LawnBot.ExampleHandler}`
   - `:func` + 一个 Lambda 表达式。

### 运行

```bash
mix deps.get
export MIX_ENV=prod
mix release
_build/prod/rel/lawn_bot/bin/lawn_bot start
```

### 测试

```bash
mix test --no-start
mix credo  # 代码风格，也可加 `--format json`获取 JSON 格式输出
mix format # 代码格式化
mix docs   # 生成 ExDoc 文档
```
