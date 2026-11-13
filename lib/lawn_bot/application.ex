defmodule LawnBot.Application do
  @moduledoc false
  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, name: LawnBot.AdapterRegistry, keys: :unique},
      {Finch, name: LawnBot.Finch},
      LawnBot.AdapterSupervisor
    ]

    LawnBot.TokenStore.new()

    with gateways when is_list(gateways) and gateways != [] <-
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

  defp start_adapters({platform, configs})
       when is_atom(platform) and is_list(configs) and configs != [],
       do: Enum.each(configs, &LawnBot.AdapterSupervisor.start_adapter(platform, &1))

  defp start_adapters(_), do: :ok
end

defmodule LawnBot.Attachment do
  @moduledoc false
  defstruct [:filename, :mime_type, :size, :width, :height, :url]

  @type image_attachment :: %__MODULE__{
          filename: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          url: String.t()
        }

  @type file_attachment :: %__MODULE__{
          filename: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          width: nil,
          height: nil,
          url: String.t()
        }

  @type t :: image_attachment() | file_attachment()
end

defmodule LawnBot.Event.Content do
  @moduledoc false
  alias LawnBot.Attachment
  alias LawnBot.Event.Content

  defstruct [:text, :attachments, :references]

  @type multi_media_content :: %__MODULE__{
          text: String.t(),
          attachments: [Attachment.t()] | nil,
          references: [Content.t()] | nil
        }

  @type history_content :: [Content.t()]

  @type t :: multi_media_content() | history_content() | String.t() | nil
end

defmodule LawnBot.Response do
  @moduledoc false
  alias LawnBot.Attachment

  defstruct [
    :action,
    :session_id,
    :reply_message_id,
    :session_type,
    :text,
    :attachment,
    :reference_message_id
  ]

  @type attachment_type ::
          Attachment.t()
          | {:path, String.t()}
          | {:url, String.t()}
          | {:binary, binary()}

  @type ignore :: %__MODULE__{
          action: :ignore,
          session_id: nil,
          reply_message_id: nil,
          session_type: nil,
          text: nil,
          attachment: nil,
          reference_message_id: nil
        }

  @type new_message :: %__MODULE__{
          action: :new_message,
          session_id: String.t(),
          reply_message_id: nil,
          session_type: :group | :c2c,
          text: String.t() | nil,
          attachment: attachment_type() | nil,
          reference_message_id: String.t() | nil
        }

  @type reply :: %__MODULE__{
          action: :reply,
          session_id: String.t(),
          reply_message_id: String.t(),
          session_type: :group | :c2c,
          text: String.t() | nil,
          attachment: attachment_type() | nil,
          reference_message_id: String.t() | nil
        }

  @type t :: ignore() | new_message() | reply()
end
