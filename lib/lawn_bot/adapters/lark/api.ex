defmodule LawnBot.Adapters.Lark.Api do
  @moduledoc false

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Attachment
  alias LawnBot.Response
  alias LawnBot.Utils

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp)

  @type api_error() ::
          {:error, {:lark_api, integer(), term(), String.t()}}
          | {:error, {:unexpected_response, integer(), term()}}
          | {:error, {:invalid_field_type, String.t()}}
          | {:error, String.t()}

  @doc """
  Fetches a tenant access token and its lifetime in seconds.

  Uses the OAuth 2.0 client credentials endpoint
  `POST {accounts_url}/oauth/v3/token`. The optional `scope` field is built
  from the configured `:permissions`; when it is empty, the platform uses all
  application-identity scopes activated for the app in the tenant.
  """
  @spec fetch_tenant_token(String.t(), atom()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}} | api_error()
  def fetch_tenant_token(token_url, name) do
    body = [
      grant_type: "client_credentials",
      client_id: PersistentTerm.get({name, :app_id}),
      client_secret: PersistentTerm.get({name, :app_secret})
    ]

    body =
      case PersistentTerm.get({name, :permissions}, []) do
        [] -> body
        scopes -> Keyword.put(body, :scope, Enum.join(scopes, " "))
      end

    case request(:post, token_url, form: body, finch: finch(name)) do
      {:ok, body} ->
        with {:ok, access_token} <-
               Utils.check_empty_string(body["access_token"] || body["tenant_access_token"]),
             {:ok, expires_in} <-
               Utils.check_pos_int(body["expires_in"] || body["expire"]) do
          {:ok, %{access_token: access_token, expires_in: expires_in}}
        else
          {:error, message} -> {:error, {:invalid_field_type, message}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Requests a WebSocket endpoint from the Lark/Feishu open platform.
  """
  @spec fetch_ws_endpoint(String.t(), atom()) ::
          {:ok,
           %{
             url: String.t(),
             service_id: integer(),
             ping_interval: pos_integer(),
             reconnect_nonce: non_neg_integer(),
             reconnect_interval: non_neg_integer()
           }}
          | api_error()
  def fetch_ws_endpoint(ws_endpoint_url, name) do
    body = %{
      "AppID" => PersistentTerm.get({name, :app_id}),
      "AppSecret" => PersistentTerm.get({name, :app_secret})
    }

    with {:ok, body} <-
           request(:post, ws_endpoint_url,
             json: body,
             headers: %{"locale" => "zh"},
             finch: finch(name)
           ),
         data when is_map(data) <- body["data"],
         url when is_binary(url) and url != "" <- data["URL"] || data["url"] do
      config = data["ClientConfig"] || data["client_config"] || %{}

      {:ok,
       %{
         url: url,
         service_id: service_id(url),
         ping_interval: seconds_to_ms(config["PingInterval"], 120),
         reconnect_nonce: seconds(config["ReconnectNonce"], 30),
         reconnect_interval: seconds(config["ReconnectInterval"], 120)
       }}
    else
      nil -> {:error, {:invalid_field_type, "missing websocket endpoint"}}
      {:error, _reason} = error -> error
      _other -> {:error, {:invalid_field_type, "invalid websocket endpoint response"}}
    end
  end

  @doc """
  Sends a `LawnBot.Response` through the Lark/Feishu messaging API.
  """
  @spec send_response(map(), atom(), String.t(), Response.t()) :: :ok | api_error()
  def send_response(urls, name, token, %Response{action: action} = response)
      when action in [:reply, :new_message] do
    with {:ok, messages} <- build_messages(urls, name, token, response) do
      send_messages(urls, name, token, response, messages)
    end
  end

  def send_response(_urls, _name, _token, _response), do: :ok

  defp send_messages(urls, name, token, response, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      send_message_result(urls, name, token, response, message)
    end)
  end

  defp send_message_result(urls, name, token, response, {msg_type, content}) do
    case send_one(urls, name, token, response, msg_type, content) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp build_messages(urls, name, token, response) do
    text_messages =
      if is_binary(response.text) and response.text != "" do
        [{"text", JSON.encode!(%{"text" => response.text})}]
      else
        []
      end

    with {:ok, attachment_messages} <-
           build_attachment_messages(urls, name, token, response.attachment) do
      {:ok, text_messages ++ attachment_messages}
    end
  end

  defp build_attachment_messages(_urls, _name, _token, nil), do: {:ok, []}

  defp build_attachment_messages(urls, name, token, attachment) do
    with {:ok, resolved} <- resolve_attachment(attachment, name),
         {:ok, msg_type, key} <- upload_attachment(urls, name, token, resolved) do
      content =
        case msg_type do
          "image" -> JSON.encode!(%{"image_key" => key})
          "file" -> JSON.encode!(%{"file_key" => key})
        end

      {:ok, [{msg_type, content}]}
    end
  end

  defp upload_attachment(urls, name, token, %{
         binary: binary,
         filename: filename,
         content_type: content_type
       }) do
    if image?(filename, content_type) do
      upload_image_message(urls, name, token, binary, filename, content_type)
    else
      upload_file_message(urls, name, token, binary, filename, content_type)
    end
  end

  defp upload_image_message(urls, name, token, binary, filename, content_type) do
    with {:ok, key} <- upload_image(urls, name, token, binary, filename, content_type) do
      {:ok, "image", key}
    end
  end

  defp upload_file_message(urls, name, token, binary, filename, content_type) do
    with {:ok, key} <- upload_file(urls, name, token, binary, filename, content_type) do
      {:ok, "file", key}
    end
  end

  defp resolve_attachment({:binary, binary}, _name) when is_binary(binary) do
    {:ok, %{binary: binary, filename: "attachment", content_type: nil}}
  end

  defp resolve_attachment({:path, path}, _name) when is_binary(path) do
    case File.read(path) do
      {:ok, binary} ->
        {:ok,
         %{
           binary: binary,
           filename: Path.basename(path),
           content_type: MIME.from_path(path)
         }}

      {:error, reason} ->
        {:error, "failed to read attachment: #{:file.format_error(reason)}"}
    end
  end

  defp resolve_attachment({:url, url}, name) when is_binary(url), do: fetch_remote(url, name)

  defp resolve_attachment(%Attachment{} = attachment, name) do
    if is_binary(attachment.url) do
      with {:ok, remote} <- fetch_remote(attachment.url, name) do
        {:ok,
         %{
           binary: remote.binary,
           filename: attachment.filename || remote.filename,
           content_type: attachment.mime_type || remote.content_type
         }}
      end
    else
      {:error, "attachment has no url"}
    end
  end

  defp resolve_attachment(_attachment, _name), do: {:error, "unsupported attachment"}

  defp fetch_remote(url, name) do
    case Req.get(url, finch: finch(name)) do
      {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) ->
        {:ok,
         %{
           binary: body,
           filename: filename_from_url(url),
           content_type: response |> Req.Response.get_header("content-type") |> List.first()
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, "failed to download attachment: HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp upload_image(urls, name, token, binary, filename, content_type) do
    fields = [
      image_type: "message",
      image: {binary, filename: filename, content_type: content_type || "application/octet-stream"}
    ]

    with {:ok, body} <-
           request(:post, urls.images,
             headers: auth_header(token),
             form_multipart: fields,
             finch: finch(name)
           ) do
      check_key(get_in(body, ["data", "image_key"]))
    end
  end

  defp upload_file(urls, name, token, binary, filename, content_type) do
    fields = [
      file_type: "stream",
      file_name: filename,
      file: {binary, filename: filename, content_type: content_type || "application/octet-stream"}
    ]

    with {:ok, body} <-
           request(:post, urls.files,
             headers: auth_header(token),
             form_multipart: fields,
             finch: finch(name)
           ) do
      check_key(get_in(body, ["data", "file_key"]))
    end
  end

  defp send_one(urls, name, token, response, msg_type, content) do
    case_result =
      case response.action do
        :reply ->
          request(
            :post,
            urls.messages <> "/" <> response.reply_message_id <> "/reply",
            headers: auth_header(token),
            json: %{"content" => content, "msg_type" => msg_type},
            finch: finch(name)
          )

        :new_message ->
          request(
            :post,
            urls.messages,
            params: [receive_id_type: "chat_id"],
            headers: auth_header(token),
            json: %{
              "receive_id" => response.session_id,
              "content" => content,
              "msg_type" => msg_type
            },
            finch: finch(name)
          )
      end

    case case_result do
      {:ok, _body} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp request(method, url, options) do
    case Req.request([method: method, url: url] ++ options) do
      {:ok, %Req.Response{status: status, body: %{"code" => 0} = body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: %{"code" => code} = body}} ->
        {:error, {:lark_api, status, code, error_message(body)}}

      {:ok, %Req.Response{status: status, body: %{"error" => error} = body}} ->
        {:error, {:lark_api, status, body["code"] || 0, body["error_description"] || error}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp error_message(body) do
    body["error_description"] || body["msg"] || body["error"] || ""
  end

  defp auth_header(token), do: %{"authorization" => "Bearer #{token}"}

  defp finch(name), do: [name: LawnBot.Finch, pool_tag: name]

  defp check_key(value) do
    case Utils.check_empty_string(value) do
      {:ok, key} -> {:ok, key}
      {:error, message} -> {:error, {:invalid_field_type, message}}
    end
  end

  defp image?(filename, content_type) do
    (is_binary(content_type) and String.starts_with?(content_type, "image/")) or
      Path.extname(String.downcase(filename || "")) in @image_extensions
  end

  defp filename_from_url(url) do
    case URI.parse(url).path do
      nil -> "attachment"
      "" -> "attachment"
      path -> Path.basename(path)
    end
  end

  defp service_id(url) do
    with %URI{query: query} when is_binary(query) <- URI.parse(url),
         %{"service_id" => value} <- URI.decode_query(query),
         {service_id, ""} <- Integer.parse(value) do
      service_id
    else
      _other -> 0
    end
  end

  defp seconds_to_ms(value, default_seconds) do
    max(seconds(value, default_seconds) * 1_000, 10_000)
  end

  defp seconds(value, default) do
    case Utils.check_non_neg_int(value) do
      {:ok, seconds} -> seconds
      {:error, _message} -> default
    end
  end
end
