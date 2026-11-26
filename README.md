![LawnBot](https://github.com/Elkeid-me/LawnBot/raw/main/assets/readme_logo_light.png#gh-light-mode-only)
![LawnBot](https://github.com/Elkeid-me/LawnBot/raw/main/assets/readme_logo_dark.png#gh-dark-mode-only)

基于 Elixir 的聊天机器人框架。当前提供 QQ 官方机器人平台 的 WebSocket 接入，以及 Lark / 飞书 的长连接接入。

## 快速开始

### 环境要求

- Elixir 1.20，Erlang/OTP 29
- QQ 开放平台（[q.qq.com](https://q.qq.com)），获取 `AppID` 与 `ClientSecret`
- Lark 开放平台（[open.larksuite.com](https://open.larksuite.com)）或飞书开放平台（[open.feishu.cn](https://open.feishu.cn)），获取 App ID 与 App Secret

### 配置

复制 `config/runtime-template.exs` 并更名为 `config/runtime.exs`。以下为示例配置：

```elixir
import Config

config :lawn_bot,
  gateways: [
    qq: [
      %{
        app_id: System.get_env("QQ_APP_ID", ""),
        client_secret: System.get_env("QQ_CLIENT_SECRET", ""),
        name: :LawnBot,
        permissions: [:guilds, :guild_members, :public_guild_messages],
        handler: LawnBot.ExampleHandler
      }
    ],
    feishu: [
      [
        app_id: System.get_env("FEISHU_APP_ID", ""),
        app_secret: System.get_env("FEISHU_APP_SECRET", ""),
        name: :LawnBotFeishu,
        handler: LawnBot.ExampleHandler,
        permissions: ["im:message:receive_as_bot", "im:message:send_as_bot"]
      ]
    ],
    lark: [
      [
        app_id: System.get_env("LARK_APP_ID", ""),
        app_secret: System.get_env("LARK_APP_SECRET", ""),
        name: :LawnBotLark,
        handler: LawnBot.ExampleHandler,
        permissions: ["im:message:receive_as_bot", "im:message:send_as_bot"]
      ]
    ]
  ]
```

#### QQ

1. `:app_id`（必需）字符串。QQ 开放平台获取的 APP ID。建议设置为环境变量。
2. `:client_secret`（必需）字符串。QQ 开放平台获取的 Client Secret。建议设置为环境变量。
3. `:name`（必需）Bot 的名称，必须为 `atom()` 类型。不同 Bot 的名称不能相同。
4. `:permissions`（可选）`atom()` 列表。事件订阅，默认只订阅平台默认有权限的三类事件 `[:guilds, :guild_members, :public_guild_messages]`
5. `:workers`（可选）正整数，默认 `1`。QQ 分片工作进程数量，用于覆盖 `/gateway/bot` 建议的分片数。
6. `:os`、`:browser`、`:device`（可选）客户端信息。
   - `:os` 字符串，无实际意义。默认为 `:os.type() |> elem(1) |> to_string()`，在 Linux 下为 `linux`，Windows 下为 `"nt"`
   - `:browser` 字符串，无实际意义。默认为 `"LawnBot"`。
   - `:device` 字符串，无实际意义。默认为 `"LawnBot"`。
7. `:handler`（可选）实现了 `LawnBot.Handler` 的模块，默认为 `LawnBot.ExampleHandler`。

#### Lark / 飞书

1. `:app_id`（必需）字符串。开放平台获取的 App ID。
2. `:app_secret`（必需）字符串。开放平台获取的 App Secret。
3. `:name`（必需）`atom()`。Bot 名称，不同 Bot 的名称不能相同。
4. `:handler`（可选）实现了 `LawnBot.Handler` 的模块，默认为 `LawnBot.ExampleHandler`。
5. `:permissions`（可选）字符串列表，默认 `[]`。获取 `tenant_access_token` 时写入 OAuth `scope` 的应用身份权限列表，例如 `["im:message:receive_as_bot", "im:message:send_as_bot"]`。为空时会省略 `scope`，由平台使用该应用在租户中已开通的全部应用身份权限。列表中的权限必须已在开发者后台开通，否则 token 接口会返回 `20068`。
6. `:workers`（可选）正整数，默认 `1`。每个 Bot 启动的 WebSocket 工作进程数。Lark/飞书的长连接是集群模式，事件会随机推送到其中一个 worker；需要提高并发或冗余时可以增加该值。所有 worker 共享同一个 `tenant_access_token`。

Lark / 飞书使用长连接接收事件，不使用分片。事件类型（如 `im.message.receive_v1`）需要在开放平台的应用后台订阅，本框架只监听接收消息事件。

> 新版 token 接口为 `POST {accounts}/oauth/v3/token`（飞书 `accounts.feishu.cn`，Lark `accounts.larksuite.com`），使用 OAuth 2.0 `client_credentials`。适配器会把 `:permissions` 作为 `scope` 传入；`scope` 为空时使用应用已开通的全部应用身份权限。返回字段是 `access_token` 和 `expires_in`。

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

## LICENSE

- LawnBot 0.1.8 及之前：MIT 许可证
- LawnBot 0.1.9 及之后：GPLv3 许可证
