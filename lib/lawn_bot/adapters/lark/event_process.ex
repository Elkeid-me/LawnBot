defmodule LawnBot.Adapters.Lark.EventProcess do
  @moduledoc false

  alias LawnBot.Attachment
  alias LawnBot.Event
  alias LawnBot.Event.Content

  @message_event "im.message.receive_v1"
  @attachment_types ~w(image file audio media sticker)

  @doc """
  Converts an `im.message.receive_v1` payload into a `LawnBot.Event`.

  Other event types, bot-authored messages and messages without a usable
  session are ignored.
  """
  @spec to_event(map(), String.t()) :: {:ok, Event.t()} | :ignore
  def to_event(payload, messages_url) when is_map(payload) do
    case get_in(payload, ["header", "event_type"]) do
      @message_event -> build_event(payload, messages_url)
      _other -> :ignore
    end
  end

  def to_event(_payload, _messages_url), do: :ignore

  defp build_event(payload, messages_url) do
    event = payload["event"] || %{}
    message = event["message"] || %{}
    sender = event["sender"] || %{}
    sender_type = sender["sender_type"]
    session_type = session_type(message["chat_type"])
    session_id = message["chat_id"]

    if sender_type in ["app", "bot"] or is_nil(session_type) or is_nil(session_id) do
      :ignore
    else
      {:ok,
       %Event{
         author_id: author_id(sender),
         content: parse_content(message, messages_url),
         message_id: message["message_id"],
         message_type: :normal,
         session_id: session_id,
         session_type: session_type
       }}
    end
  end

  defp session_type("group"), do: :group
  defp session_type("p2p"), do: :c2c
  defp session_type(_other), do: nil

  defp author_id(sender) do
    sender_id = sender["sender_id"] || %{}

    sender_id["open_id"] || sender_id["user_id"] || sender_id["union_id"]
  end

  defp parse_content(message, messages_url) do
    content = decode_content(message["content"])

    case message["message_type"] do
      "text" ->
        text_content(content)

      "post" ->
        post_content(content, message, messages_url)

      type when type in @attachment_types ->
        attachment_content(type, content, message, messages_url)

      _other ->
        nil
    end
  end

  defp decode_content(content) when is_binary(content) do
    case JSON.decode(content) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp decode_content(_content), do: nil

  defp text_content(%{"text" => text}) when is_binary(text), do: text
  defp text_content(_content), do: nil

  defp post_content(content, message, messages_url) when is_map(content) do
    locale =
      Enum.find_value(["zh_cn", "en_us", "ja_jp"], fn key ->
        case content[key] do
          %{} = value -> value
          _other -> nil
        end
      end) || content

    title = if is_binary(locale["title"]), do: locale["title"], else: ""

    blocks =
      case locale["content"] do
        blocks when is_list(blocks) -> blocks
        _other -> []
      end

    {texts, attachments} = extract_post_blocks(blocks, message, messages_url)

    lines = Enum.reject([title | texts], &(&1 in [nil, ""]))
    text = if lines == [], do: nil, else: Enum.join(lines, "\n")

    if attachments == [] do
      text
    else
      %Content{text: text, attachments: attachments, references: nil}
    end
  end

  defp post_content(_content, _message, _messages_url), do: nil

  defp extract_post_blocks(blocks, message, messages_url) do
    blocks
    |> Enum.reduce({[], []}, fn block, {texts, attachments} ->
      elements = if is_list(block), do: block, else: []

      block_text =
        elements
        |> Enum.map(&element_text/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("")

      block_attachments =
        elements
        |> Enum.filter(&(&1["tag"] in ["img", "media"]))
        |> Enum.map(&element_attachment(&1, message, messages_url))
        |> Enum.reject(&is_nil/1)

      texts = if block_text == "", do: texts, else: [block_text | texts]
      {texts, attachments ++ block_attachments}
    end)
    |> then(fn {texts, attachments} -> {Enum.reverse(texts), attachments} end)
  end

  defp element_text(%{"tag" => tag, "text" => text})
       when tag in ["text", "a", "md", "code_block"] and is_binary(text), do: text

  defp element_text(%{"tag" => "at", "name" => name}) when is_binary(name), do: "@#{name}"
  defp element_text(_element), do: nil

  defp element_attachment(%{"tag" => "img", "image_key" => key}, message, messages_url)
       when is_binary(key) do
    resource_attachment(message, key, "image", messages_url)
  end

  defp element_attachment(%{"tag" => "media", "file_key" => key}, message, messages_url)
       when is_binary(key) do
    resource_attachment(message, key, "file", messages_url)
  end

  defp element_attachment(_element, _message, _messages_url), do: nil

  defp attachment_content(type, content, message, messages_url) when is_map(content) do
    key = content["image_key"] || content["file_key"]

    if is_binary(key) do
      resource_type = if type == "image", do: "image", else: "file"

      attachment = %Attachment{
        filename: content["file_name"],
        mime_type: nil,
        size: content["file_size"] || content["size"],
        width: content["width"],
        height: content["height"],
        url: resource_url(message["message_id"], key, resource_type, messages_url)
      }

      %Content{text: nil, attachments: [attachment], references: nil}
    end
  end

  defp attachment_content(_type, _content, _message, _messages_url), do: nil

  defp resource_attachment(message, key, type, messages_url) do
    %Attachment{
      filename: nil,
      mime_type: nil,
      size: nil,
      width: nil,
      height: nil,
      url: resource_url(message["message_id"], key, type, messages_url)
    }
  end

  defp resource_url(message_id, key, type, messages_url) do
    if is_binary(message_id) and is_binary(messages_url) do
      messages_url <> "/" <> message_id <> "/resources/" <> key <> "?type=" <> type
    end
  end
end
