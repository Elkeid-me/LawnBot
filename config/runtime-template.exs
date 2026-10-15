import Config

config :lawn_bot,
  gateways: %{
    qq: [
      %{
        app_id: System.get_env("QQ_APP_ID", ""),
        client_secret: System.get_env("QQ_CLIENT_SECRET", ""),
        intents: [:guilds, :guild_members, :public_guild_messages, :group_and_c2c],
        shards: 1,
        name: "LawnBot",
        handler: {:module, LawnBot.ExampleHandler}
      }
    ]
  }
