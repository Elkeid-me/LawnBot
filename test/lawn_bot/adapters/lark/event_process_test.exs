defmodule LawnBot.Adapters.Lark.EventProcessTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.Lark.EventProcess
  alias LawnBot.Attachment
  alias LawnBot.Event
  alias LawnBot.Event.Content

  @base_url "https://open.feishu.cn"

  defp payload(
         event_type \\ "im.message.receive_v1",
         chat_type \\ "group",
         message_type \\ "text",
         content \\ ~s({"text":"hello"}),
         sender_type \\ "user"
       ) do
    %{
      "schema" => "2.0",
      "header" => %{"event_type" => event_type, "event_id" => "evt-1"},
      "event" => %{
        "sender" => %{
          "sender_type" => sender_type,
          "sender_id" => %{"open_id" => "ou-user", "user_id" => "user-1"}
        },
        "message" => %{
          "message_id" => "om-message",
          "chat_id" => "oc-chat",
          "chat_type" => chat_type,
          "message_type" => message_type,
          "content" => content
        }
      }
    }
  end

  test "converts a group text message" do
    assert {:ok, %Event{} = event} = EventProcess.to_event(payload(), @base_url)

    assert event.author_id == "ou-user"
    assert event.content == "hello"
    assert event.message_id == "om-message"
    assert event.message_type == :normal
    assert event.session_id == "oc-chat"
    assert event.session_type == :group
  end

  test "converts a p2p text message" do
    assert {:ok, %Event{session_type: :c2c, session_id: "oc-chat"}} =
             EventProcess.to_event(payload("im.message.receive_v1", "p2p"), @base_url)
  end

  test "ignores app-authored messages" do
    assert :ignore =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "text", "{}", "app"),
               @base_url
             )

    assert :ignore =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "text", "{}", "bot"),
               @base_url
             )
  end

  test "ignores other event types and unsupported chat types" do
    assert :ignore = EventProcess.to_event(payload("im.message.reaction.created_v1"), @base_url)
    assert :ignore = EventProcess.to_event(payload("im.message.receive_v1", "topic"), @base_url)
  end

  test "ignores messages without a chat id" do
    event_payload = payload()
    message = event_payload["event"]["message"]

    event_payload =
      put_in(event_payload, ["event", "message"], Map.delete(message, "chat_id"))

    assert :ignore = EventProcess.to_event(event_payload, @base_url)
  end

  test "extracts image attachments" do
    content = ~s({"image_key":"img-1"})

    assert {:ok, %Event{content: %Content{text: nil, attachments: [attachment]}}} =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "image", content),
               @base_url
             )

    assert %Attachment{
             url:
               "https://open.feishu.cn/open-apis/im/v1/messages/om-message/resources/img-1?type=image"
           } = attachment
  end

  test "extracts file metadata" do
    content = ~s({"file_key":"file-1","file_name":"report.pdf","file_size":2048})

    assert {:ok, %Event{content: %Content{attachments: [attachment]}}} =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "file", content),
               @base_url
             )

    assert %Attachment{
             filename: "report.pdf",
             size: 2048,
             url:
               "https://open.feishu.cn/open-apis/im/v1/messages/om-message/resources/file-1?type=file"
           } = attachment
  end

  test "extracts text and images from rich text posts" do
    content =
      JSON.encode!(%{
        "zh_cn" => %{
          "title" => "Title",
          "content" => [
            [
              %{"tag" => "text", "text" => "hello "},
              %{"tag" => "a", "text" => "link"}
            ],
            [%{"tag" => "img", "image_key" => "img-2"}]
          ]
        },
        "en_us" => %{"title" => "ignored", "content" => []}
      })

    assert {:ok, %Event{content: %Content{text: "Title\nhello link", attachments: [attachment]}}} =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "post", content),
               @base_url
             )

    assert attachment.url =~ "img-2"
  end

  test "returns nil content for unsupported or malformed content" do
    assert {:ok, %Event{content: nil}} =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "unknown", "{}"),
               @base_url
             )

    assert {:ok, %Event{content: nil}} =
             EventProcess.to_event(
               payload("im.message.receive_v1", "group", "text", "not-json"),
               @base_url
             )
  end
end
