defmodule LawnBot.Adapters.QQ.EventProcessTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.EventProcess
  alias LawnBot.Attachment
  alias LawnBot.Event
  alias LawnBot.Event.Content

  @moduletag capture_log: true

  defp group_event(type, data) do
    EventProcess.to_event(%{"t" => type, "d" => data})
  end

  describe "to_event/1" do
    test "converts a group message into a group event" do
      data = %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "hello",
        "message_type" => 0,
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{
               author_id: "member-1",
               content: "hello",
               message_id: "message-1",
               message_type: :normal,
               session_id: "group-1",
               session_type: :group
             } = group_event("GROUP_AT_MESSAGE_CREATE", data)
    end

    test "converts a C2C message into a c2c event" do
      data = %{
        "id" => "message-2",
        "content" => "hi",
        "message_type" => 0,
        "author" => %{"user_openid" => "user-1"}
      }

      assert %Event{
               author_id: "user-1",
               content: "hi",
               message_id: "message-2",
               message_type: :normal,
               session_id: "user-1",
               session_type: :c2c
             } = group_event("C2C_MESSAGE_CREATE", data)
    end

    test "maps friend events to c2c message types" do
      data = %{
        "id" => "notification-1",
        "content" => "friend",
        "message_type" => 0,
        "author" => %{"user_openid" => "user-1"}
      }

      assert %Event{message_type: :new_friend, session_type: :c2c, session_id: "user-1"} =
               group_event("FRIEND_ADD", data)

      assert %Event{message_type: :delete_friend, session_type: :c2c, session_id: "user-1"} =
               group_event("FRIEND_DEL", data)
    end

    test "treats GROUP_MESSAGE_CREATE as a normal group message" do
      data = %{
        "id" => "message-3",
        "group_openid" => "group-1",
        "content" => "hello",
        "message_type" => 0,
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{message_type: :normal, session_type: :group} =
               group_event("GROUP_MESSAGE_CREATE", data)
    end

    test "leaves event and session types nil for unknown events" do
      data = %{
        "id" => "message-4",
        "content" => "unknown",
        "message_type" => 0,
        "group_openid" => "group-1",
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{
               author_id: nil,
               message_id: "message-4",
               message_type: nil,
               session_id: nil,
               session_type: nil,
               content: "unknown"
             } = group_event("UNKNOWN_EVENT", data)
    end
  end

  describe "content extraction" do
    test "keeps plain text when there are no attachments" do
      data = %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "hello",
        "message_type" => 0,
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{content: "hello"} = group_event("GROUP_AT_MESSAGE_CREATE", data)
    end

    test "wraps text and attachments in a Content struct" do
      data = %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "look",
        "message_type" => 0,
        "attachments" => [
          %{
            "filename" => "image.png",
            "content_type" => "image/png",
            "size" => 1024,
            "width" => 640,
            "height" => 480,
            "url" => "https://example.com/image.png"
          }
        ],
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{
               content: %Content{
                 text: "look",
                 references: nil,
                 attachments: [
                   %Attachment{
                     filename: "image.png",
                     mime_type: "image/png",
                     size: 1024,
                     width: 640,
                     height: 480,
                     url: "https://example.com/image.png"
                   }
                 ]
               }
             } = group_event("GROUP_AT_MESSAGE_CREATE", data)
    end

    test "extracts multimedia messages and their references" do
      data = %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "rich",
        "message_type" => 103,
        "msg_elements" => [
          %{"message_type" => 0, "content" => "quoted text"},
          %{
            "message_type" => 103,
            "content" => "quoted rich",
            "attachments" => [
              %{
                "filename" => "quote.png",
                "content_type" => "image/png",
                "size" => 10,
                "width" => 1,
                "height" => 1,
                "url" => "https://example.com/quote.png"
              }
            ]
          }
        ],
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{
               content: %Content{
                 text: "rich",
                 attachments: nil,
                 references: [
                   "quoted text",
                   %Content{
                     text: "quoted rich",
                     attachments: [%Attachment{filename: "quote.png"}],
                     references: nil
                   }
                 ]
               }
             } = group_event("GROUP_AT_MESSAGE_CREATE", data)
    end

    test "leaves references nil when a multimedia message has no elements" do
      data = %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "rich",
        "message_type" => 103,
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{content: %Content{text: "rich", attachments: nil, references: nil}} =
               group_event("GROUP_AT_MESSAGE_CREATE", data)
    end

    test "fills missing attachment fields with nil" do
      data = %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "file",
        "message_type" => 0,
        "attachments" => [%{"url" => "https://example.com/file"}],
        "author" => %{"member_openid" => "member-1"}
      }

      assert %Event{
               content: %Content{
                 attachments: [
                   %Attachment{
                     filename: nil,
                     mime_type: nil,
                     size: nil,
                     width: nil,
                     height: nil,
                     url: "https://example.com/file"
                   }
                 ]
               }
             } = group_event("GROUP_AT_MESSAGE_CREATE", data)
    end
  end
end
