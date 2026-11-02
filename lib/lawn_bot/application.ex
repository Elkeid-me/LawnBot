defmodule LawnBot.Application do
  @moduledoc """
  LawnBot 的 OTP 应用入口。

  应用启动 Registry 与平台适配器监督器，并根据 `:gateways` 配置启动各个平台的适配器。
  未配置任何网关时，应用会返回 `{:error, :no_gateways_configured}`。
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, name: LawnBot.AdapterRegistry, keys: :unique},
      LawnBot.AdapterSupervisor,
      {Finch, name: LawnBot.Finch}
    ]

    with gateways when is_map(gateways) and map_size(gateways) > 0 <-
           Application.get_env(:lawn_bot, :gateways),
         {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: LawnBot.Supervisor) do
      Enum.each(gateways, &start_adapters/1)
      {:ok, pid}
    else
      {:error, _reason} ->
        Logger.error("Failed to start LawnBot application supervisor.")
        {:error, :cannot_start_supervisor}

      _ ->
        Logger.error("No gateways configured for LawnBot. Please check your configuration.")
        {:error, :no_gateways_configured}
    end
  end

  defp start_adapters({platform, configs}) when is_list(configs),
    do: Enum.each(configs, &LawnBot.AdapterSupervisor.start_adapter(platform, &1))
end

defmodule LawnBot.Event do
  @moduledoc "LawnBot 事件结构体。"
  defstruct [
    :session_type,
    :session_id,
    :message_type,
    :message_id,
    :author_id,
    :content
  ]

  @type t :: %__MODULE__{
          session_type: :group | :c2c,
          session_id: String.t(),
          message_type: :normal | :new_friend | :delete_friend | nil,
          message_id: String.t(),
          author_id: String.t(),
          content: LawnBot.Event.Content.t()
        }
end

defmodule LawnBot.Event.Attachment do
  @moduledoc "LawnBot 事件附件结构体。"
  defstruct [:filename, :mime_type, :size, :width, :height, :url]

  @type t ::
          %__MODULE__{
            filename: String.t(),
            mime_type: String.t(),
            size: non_neg_integer(),
            width: nil,
            height: nil,
            url: String.t()
          }
          | %__MODULE__{
              filename: String.t(),
              mime_type: String.t(),
              size: non_neg_integer(),
              width: non_neg_integer(),
              height: non_neg_integer(),
              url: String.t()
            }
end

defmodule LawnBot.Event.History do
  @moduledoc false
  @type t :: [LawnBot.Event.Content.t()]
end

defmodule LawnBot.Event.Content do
  @moduledoc false
  defstruct [:text, :attachments, :references]

  @type t ::
          %__MODULE__{
            text: String.t(),
            attachments: [LawnBot.Event.Attachment.t()] | nil,
            references: [LawnBot.Event.Content.t()] | nil
          }
          | LawnBot.Event.History.t()
          | String.t()
          | nil
end

defmodule LawnBot.Reply do
  @moduledoc "LawnBot 回复结构体。"
  alias LawnBot.Event.Attachment

  defstruct [
    :action,
    :session_id,
    :reply_message_id,
    :session_type,
    :text,
    :attachment,
    :reference_message_id
  ]

  @typep attachment_type ::
           Attachment.t()
           | {:path, String.t()}
           | {:url, String.t()}
           | {:binary, binary()}

  @type t ::
          %__MODULE__{
            action: :ignore,
            session_id: nil,
            reply_message_id: nil,
            session_type: nil,
            text: nil,
            attachment: nil,
            reference_message_id: nil
          }
          | %__MODULE__{
              action: :new_message,
              session_id: String.t(),
              reply_message_id: nil,
              session_type: :group | :c2c,
              text: String.t() | nil,
              attachment: attachment_type() | nil,
              reference_message_id: String.t() | nil
            }
          | %__MODULE__{
              action: :reply,
              session_id: String.t(),
              reply_message_id: String.t(),
              session_type: :group | :c2c,
              text: String.t() | nil,
              attachment: attachment_type() | nil,
              reference_message_id: String.t() | nil
            }
end

defmodule LawnBot.Handler do
  @moduledoc """
  LawnBot 事件处理器行为定义。

  事件处理器负责接收 LawnBot 事件并返回相应的回复。
  """
  @callback handle_event(event :: LawnBot.Event.t()) :: LawnBot.Reply.t()
end
