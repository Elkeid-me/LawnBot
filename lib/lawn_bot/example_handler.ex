defmodule LawnBot.ExampleHandler do
  @moduledoc """
  An example implementation of LawnBot.Handler behaviour. Echo the message back to the user.
  """
  @behaviour LawnBot.Handler

  alias LawnBot.Event.Content

  @impl LawnBot.Handler
  @spec handle_event(LawnBot.Event.t()) :: LawnBot.Response.t()
  def handle_event(event) do
    content = get_text_content(event)

    %LawnBot.Response{
      action: :reply,
      session_id: event.session_id,
      reply_message_id: event.message_id,
      session_type: event.session_type,
      text: content,
      reference_message_id: event.message_id,
      attachment: get_attachment(event)
    }
  end

  defp get_text_content(%LawnBot.Event{content: content}) when is_binary(content), do: content

  defp get_text_content(%LawnBot.Event{content: %Content{text: content}}) when is_binary(content),
    do: content

  defp get_text_content(_event), do: "Unknown"

  defp get_attachment(%LawnBot.Event{content: %Content{attachments: attachments}})
       when is_list(attachments) and attachments != [], do: {:url, List.first(attachments).url}

  defp get_attachment(_event), do: nil
end
