defmodule LawnBot.Event do
  @moduledoc false
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
