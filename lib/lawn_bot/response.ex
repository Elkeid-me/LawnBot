defmodule LawnBot.Response do
  @moduledoc """
  A normalized outgoing response returned by a `LawnBot.Handler`.

  A handler receives a `LawnBot.Event` and returns a `LawnBot.Response`.
  Adapters translate the response into platform-specific API calls. The struct
  is intentionally platform-neutral: it describes *what* should happen, while
  the adapter decides *how* to send it.

  ## Actions

  | Action | Meaning |
  | --- | --- |
  | `:ignore` | Do not send anything. All other fields are `nil`. |
  | `:new_message` | Create a new message in the session identified by `session_id`. |
  | `:reply` | Reply to the incoming message identified by `reply_message_id`. |

  ## Fields

  | Field | Type | Description |
  | --- | --- | --- |
  | `:action` | `:ignore \\| :new_message \\| :reply` | What the adapter should do. |
  | `:session_id` | `String.t() \\| nil` | Target session. For group messages this is normally the group/chat ID; for C2C it is the user/chat ID. |
  | `:reply_message_id` | `String.t() \\| nil` | Incoming message ID to reply to. Required for `:reply`, `nil` for `:ignore` and normally `nil` for `:new_message`. |
  | `:session_type` | `:group \\| :c2c \\| nil` | Session type. Adapters use this to choose the platform endpoint. |
  | `:text` | `String.t() \\| nil` | Optional plain text content. |
  | `:attachment` | `attachment_type() \\| nil` | Optional single attachment. Text and attachment can be used together when the adapter supports it. |
  | `:reference_message_id` | `String.t() \\| nil` | Optional message ID used for a quoted/reference message. Support depends on the adapter. |

  At least one of `:text` and `:attachment` should normally be present for
  `:new_message` and `:reply`. A response with both set to `nil` may produce no
  outgoing message, depending on the adapter.

  ## Attachment forms

  `:attachment` accepts one of the following forms:

  - `%LawnBot.Attachment{}`: a normalized attachment struct. Its `:url` is used
    when the adapter can download remote content.
  - `{:path, path}`: a local file path. The adapter reads and uploads it.
  - `{:url, url}`: a remote URL. The adapter downloads it before uploading, when
    the platform requires a platform-specific file key.
  - `{:binary, binary}`: already-loaded binary content.

  There is one attachment field, not a list. To send multiple files, return
  multiple responses from the handler or use a platform-specific rich message
  representation.

  ## Examples

  Ignore an event:

      %LawnBot.Response{action: :ignore}

  Send a new text message:

      %LawnBot.Response{
        action: :new_message,
        session_id: "chat-1",
        session_type: :group,
        text: "hello"
      }

  Reply to a message and quote it as well:

      %LawnBot.Response{
        action: :reply,
        session_id: "chat-1",
        reply_message_id: "message-1",
        session_type: :c2c,
        text: "pong",
        reference_message_id: "message-1"
      }

  Reply with an image URL:

      %LawnBot.Response{
        action: :reply,
        session_id: "chat-1",
        reply_message_id: "message-1",
        session_type: :group,
        text: "look",
        attachment: {:url, "https://example.com/image.png"}
      }

  A handler implementation typically looks like:

      def handle_event(event) do
        %LawnBot.Response{
          action: :reply,
          session_id: event.session_id,
          reply_message_id: event.message_id,
          session_type: event.session_type,
          text: "received: \#{event.content}"
        }
      end

  ## Adapter behavior

  - `:ignore` is always a no-op.
  - `:new_message` requires `:session_id` and `:session_type`.
  - `:reply` requires `:session_id`, `:session_type`, and `:reply_message_id`.
  - `:reference_message_id` is advisory. Adapters that do not support
    message references simply ignore it.
  - `:attachment` requires adapter support for the chosen attachment form.
  - Some adapters send text and attachment as separate messages because the
    platform does not allow both in one message payload.

  See `LawnBot.Handler` for the callback contract.
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

  @typedoc """
  The attachment value accepted by `:attachment`.

  Supported forms:

  - `%LawnBot.Attachment{}` - normalized attachment metadata, usually with a
    remote `:url`
  - `{:path, path}` - local file path
  - `{:url, url}` - remote URL to download
  - `{:binary, binary}` - in-memory binary content
  """
  @type attachment_type ::
          Attachment.t()
          | {:path, String.t()}
          | {:url, String.t()}
          | {:binary, binary()}

  @typedoc """
  A response that tells the adapter to do nothing.

  All fields are `nil`, and `:action` is `:ignore`. This is useful for events
  that the handler does not want to answer, including messages from the bot
  itself.
  """
  @type ignore :: %__MODULE__{
          action: :ignore,
          session_id: nil,
          reply_message_id: nil,
          session_type: nil,
          text: nil,
          attachment: nil,
          reference_message_id: nil
        }

  @typedoc """
  A response that creates a new message in `:session_id`.

  `:session_id` and `:session_type` are required. `:reply_message_id` is `nil`
  because this is not a direct reply. At least one of `:text` and `:attachment`
  should be provided. `:reference_message_id` can optionally point at an
  existing message when the adapter supports quoting.
  """
  @type new_message :: %__MODULE__{
          action: :new_message,
          session_id: String.t(),
          reply_message_id: nil,
          session_type: :group | :c2c,
          text: String.t() | nil,
          attachment: attachment_type() | nil,
          reference_message_id: String.t() | nil
        }

  @typedoc """
  A response that replies to the incoming message identified by
  `:reply_message_id`.

  `:session_id`, `:session_type`, and `:reply_message_id` are required. At
  least one of `:text` and `:attachment` should be provided.
  `:reference_message_id` is an optional additional quote target for adapters
  that distinguish a reply from a reference.
  """
  @type reply :: %__MODULE__{
          action: :reply,
          session_id: String.t(),
          reply_message_id: String.t(),
          session_type: :group | :c2c,
          text: String.t() | nil,
          attachment: attachment_type() | nil,
          reference_message_id: String.t() | nil
        }

  @typedoc """
  Any response a handler may return: `t:ignore/0`, `t:new_message/0`, or
  `t:reply/0`.
  """
  @type t :: ignore() | new_message() | reply()
end
