defmodule LawnBot.Adapters.QQ.EventProcess do
  @moduledoc false
  alias LawnBot.Event.Content

  require Logger

  @doc "将 QQ 网关事件 payload 转换为 LawnBot 事件结构体。"
  @spec to_event(map()) :: LawnBot.Event.t()
  def to_event(payload) do
    data = payload["d"]
    {message_type, session_type} = extract_event_type(payload)
    message_id = data["id"]
    session_id = extract_session_id(data, session_type)
    author_id = extract_author_id(data, session_type)
    content = extract_content(data)

    %LawnBot.Event{
      session_type: session_type,
      session_id: session_id,
      message_type: message_type,
      message_id: message_id,
      author_id: author_id,
      content: content
    }
  end

  @spec extract_event_type(map()) ::
          {:normal | :new_friend | :delete_friend | nil, :group | :c2c | nil}
  defp extract_event_type(%{"t" => "C2C_MESSAGE_CREATE"}), do: {:normal, :c2c}
  defp extract_event_type(%{"t" => "FRIEND_ADD"}), do: {:new_friend, :c2c}
  defp extract_event_type(%{"t" => "FRIEND_DEL"}), do: {:delete_friend, :c2c}
  defp extract_event_type(%{"t" => "GROUP_MESSAGE_CREATE"}), do: {:normal, :group}
  defp extract_event_type(%{"t" => "GROUP_AT_MESSAGE_CREATE"}), do: {:normal, :group}

  defp extract_event_type(%{"t" => type}) do
    Logger.warning("Unknown QQ event type: #{type}")
    {nil, nil}
  end

  @spec extract_session_id(map(), :c2c | :group | nil) :: String.t() | nil
  defp extract_session_id(data, :c2c), do: data["author"]["user_openid"]
  defp extract_session_id(data, :group), do: data["group_openid"]
  defp extract_session_id(_data, _), do: nil

  @spec extract_author_id(map(), :c2c | :group | nil) :: String.t() | nil
  defp extract_author_id(data, :c2c), do: data["author"]["user_openid"]
  defp extract_author_id(data, :group), do: data["author"]["member_openid"]
  defp extract_author_id(_data, _), do: nil

  @spec extract_content(map()) :: Content.t() | nil
  defp extract_content(%{"message_type" => 103} = data) do
    text = data["content"]
    attachments = extract_attachments(data)

    references =
      case data["msg_elements"] do
        nil -> nil
        references -> Enum.map(references, &extract_content/1)
      end

    %Content{
      text: text,
      attachments: attachments,
      references: references
    }
  end

  defp extract_content(%{"message_type" => 0} = data) do
    text = data["content"]
    attachments = extract_attachments(data)

    if attachments == nil do
      text
    else
      %Content{
        text: text,
        attachments: attachments,
        references: nil
      }
    end
  end

  defp extract_attachments(%{"attachments" => attachments}) when is_list(attachments),
    do:
      Enum.map(attachments, fn attachment ->
        %LawnBot.Attachment{
          filename: Map.get(attachment, "filename"),
          mime_type: Map.get(attachment, "content_type"),
          size: Map.get(attachment, "size"),
          width: Map.get(attachment, "width"),
          height: Map.get(attachment, "height"),
          url: Map.get(attachment, "url")
        }
      end)

  defp extract_attachments(_), do: nil
end
