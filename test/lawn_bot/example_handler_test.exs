defmodule LawnBot.ExampleHandlerTest do
  use ExUnit.Case, async: true

  alias LawnBot.Attachment
  alias LawnBot.Event
  alias LawnBot.Event.Content
  alias LawnBot.ExampleHandler
  alias LawnBot.Response

  defp event(content, overrides \\ []) do
    struct!(
      %Event{
        author_id: "author-1",
        content: content,
        message_id: "message-1",
        message_type: :normal,
        session_id: "session-1",
        session_type: :group
      },
      overrides
    )
  end

  test "echoes plain text content back as a reply" do
    assert %Response{
             action: :reply,
             session_id: "session-1",
             reply_message_id: "message-1",
             session_type: :group,
             text: "hello",
             attachment: nil,
             reference_message_id: "message-1"
           } = ExampleHandler.handle_event(event("hello"))
  end

  test "uses the text field of a multimedia content" do
    content = %Content{text: "hello", attachments: nil, references: nil}

    assert %Response{text: "hello", attachment: nil} = ExampleHandler.handle_event(event(content))
  end

  test "forwards the first attachment url" do
    first = %Attachment{filename: "first.png", url: "https://example.com/first.png"}
    second = %Attachment{filename: "second.png", url: "https://example.com/second.png"}
    content = %Content{text: "look", attachments: [first, second], references: nil}

    assert %Response{text: "look", attachment: {:url, "https://example.com/first.png"}} =
             ExampleHandler.handle_event(event(content))
  end

  test "falls back to Unknown for missing or non-text content" do
    assert %Response{text: "Unknown", attachment: nil} = ExampleHandler.handle_event(event(nil))

    assert %Response{text: "Unknown"} =
             ExampleHandler.handle_event(event(%Content{text: nil, attachments: nil}))

    assert %Response{text: "Unknown"} = ExampleHandler.handle_event(event(%Content{}))
  end

  test "ignores empty attachment lists" do
    content = %Content{text: "hello", attachments: [], references: nil}

    assert %Response{text: "hello", attachment: nil} = ExampleHandler.handle_event(event(content))
  end
end
