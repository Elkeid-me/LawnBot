import Config

config :lawn_bot,
  gateways: [
    qq: [
      [
        app_id: System.get_env("QQ_APP_ID", ""),
        client_secret: System.get_env("QQ_CLIENT_SECRET", ""),
        name: :LawnBot,
        handler: LawnBot.ExampleHandler
      ]
    ]
    # feishu: [
    #   [
    #     app_id: System.get_env("FEISHU_APP_ID", ""),
    #     app_secret: System.get_env("FEISHU_APP_SECRET", ""),
    #     name: :LawnBotFeishu,
    #     handler: LawnBot.ExampleHandler,
    #     permissions: ["im:message:receive_as_bot", "im:message:send_as_bot"],
    #     workers: 1
    #   ]
    # ],
    # lark: [
    #   [
    #     app_id: System.get_env("LARK_APP_ID", ""),
    #     app_secret: System.get_env("LARK_APP_SECRET", ""),
    #     name: :LawnBotLark,
    #     handler: LawnBot.ExampleHandler,
    #     permissions: ["im:message:receive_as_bot", "im:message:send_as_bot"],
    #     workers: 1
    #   ]
    # ]
  ]

config :logger, level: :info
