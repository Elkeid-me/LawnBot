defmodule LawnBot.EventTest do
  use ExUnit.Case, async: true

  alias LawnBot.Attachment
  alias LawnBot.Event
  alias LawnBot.Event.Content

  test "event fields default to nil" do
    assert %Event{
             author_id: nil,
             content: nil,
             message_id: nil,
             message_type: nil,
             session_id: nil,
             session_type: nil
           } = %Event{}
  end

  test "content fields default to nil" do
    assert %Content{text: nil, attachments: nil, references: nil} = %Content{}
  end

  test "attachment fields default to nil" do
    assert %Attachment{
             filename: nil,
             mime_type: nil,
             size: nil,
             width: nil,
             height: nil,
             url: nil
           } = %Attachment{}
  end
end
