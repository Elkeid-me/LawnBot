defmodule LawnBot.Adapters.Lark do
  @moduledoc """
  The Lark (international) adapter.

  It uses the same long-connection protocol and OpenAPI shape as the Feishu
  adapter, with `https://open.larksuite.com` as the API base URL.
  """

  use LawnBot.Adapters.Lark.Base,
    open_api_url: "https://open.larksuite.com",
    accounts_url: "https://accounts.larksuite.com",
    coordinator: LawnBot.Adapters.Lark.Coordinator,
    worker: LawnBot.Adapters.Lark.Worker,
    label: "Lark"
end

defmodule LawnBot.Adapters.Lark.Coordinator do
  @moduledoc false

  use LawnBot.Adapters.Lark.BaseCoordinator,
    accounts_url: "https://accounts.larksuite.com",
    open_api_url: "https://open.larksuite.com",
    label: "Lark",
    worker: LawnBot.Adapters.Lark.Worker
end

defmodule LawnBot.Adapters.Lark.Worker do
  @moduledoc false

  use LawnBot.Adapters.Lark.BaseWorker,
    open_api_url: "https://open.larksuite.com",
    label: "Lark"
end
