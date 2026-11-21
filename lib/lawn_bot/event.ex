defmodule LawnBot.Event do
  @moduledoc """
  An struct representing an event received by LawnBot. It contains information about the session, message, author, and content of the event.
  """

  defstruct [
    :author_id,
    :content,
    :message_id,
    :message_type,
    :session_id,
    :session_type
  ]

  @typedoc """
  The type of an event received by LawnBot. It is a struct containing the following fields:

  - `author_id`: The ID of the author of the message.
  - `content`: The content of the message, which can be a string, a `LawnBot.Event.Content` struct, or `nil`.
  - `message_id`: The ID of the message.
  - `message_type`: The type of message, either `:normal`, `:new_friend`, `:delete_friend`, or `nil`.
  - `session_id`: The ID of the session.
  - `session_type`: The type of session, either `:group` or `:c2c`.
  """
  @type t :: %__MODULE__{
          author_id: String.t(),
          content: LawnBot.Event.Content.t(),
          message_id: String.t(),
          message_type: :normal | :new_friend | :delete_friend | nil,
          session_id: String.t(),
          session_type: :group | :c2c
        }
end

defmodule LawnBot.Event.Content do
  @moduledoc """
  A struct representing the content of an event received by LawnBot. It can contain text, attachments, and references to other messages.
  """
  alias LawnBot.Attachment
  alias LawnBot.Event.Content

  defstruct [:text, :attachments, :references]

  @type multi_media_content :: %__MODULE__{
          text: String.t(),
          attachments: [Attachment.t()] | nil,
          references: [Content.t()] | nil
        }

  @type history_content :: [Content.t()]

  @typedoc """
  The type of the content of an event received by LawnBot. It can be a `multi_media_content`, a `history_content`, a string, or `nil`.
  """
  @type t :: multi_media_content() | history_content() | String.t() | nil
end

defmodule LawnBot.Attachment do
  @moduledoc """
  A struct representing an attachment in a message.
  """

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

  @typedoc """
  The type of an attachment in a message. It can be either an `image_attachment` or a `file_attachment`.
  """
  @type t :: image_attachment() | file_attachment()
end
