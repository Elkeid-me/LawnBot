defmodule LawnBot.Event do
  defstruct [:session_type, :session_id, :message_type, :message_id, :author, :content, :extra]

  @type t :: %__MODULE__{
          session_type: :group | :c2c,
          session_id: String.t(),
          message_type: :normal | :new_friend,
          message_id: String.t(),
          author: %{id: String.t(), nickname: String.t() | nil},
          content: term(),
          extra: map()
        }
end
