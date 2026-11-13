defmodule LawnBot.Response do
  @moduledoc """
  A struct representing a response to an event received by LawnBot.

  It contains information about the action to be taken, the session, message, and content (text or
  attachments, or both) of the response.
  """
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
