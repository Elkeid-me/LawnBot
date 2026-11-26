defmodule LawnBot.Adapters.Feishu do
  @moduledoc """
  The Feishu (China) adapter.

  It uses the same long-connection protocol and OpenAPI shape as the Lark
  adapter, with `https://open.feishu.cn` as the API base URL.
  """

  use LawnBot.Adapters.Lark.Base,
    open_api_url: "https://open.feishu.cn",
    accounts_url: "https://accounts.feishu.cn",
    coordinator: LawnBot.Adapters.Feishu.Coordinator,
    worker: LawnBot.Adapters.Feishu.Worker,
    label: "Feishu"
end

defmodule LawnBot.Adapters.Feishu.Coordinator do
  @moduledoc false

  use LawnBot.Adapters.Lark.BaseCoordinator,
    open_api_url: "https://open.feishu.cn",
    accounts_url: "https://accounts.feishu.cn",
    label: "Feishu",
    worker: LawnBot.Adapters.Feishu.Worker
end

defmodule LawnBot.Adapters.Feishu.Worker do
  @moduledoc false

  use LawnBot.Adapters.Lark.BaseWorker,
    open_api_url: "https://open.feishu.cn",
    label: "Feishu"
end
