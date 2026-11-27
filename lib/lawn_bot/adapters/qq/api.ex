defmodule LawnBot.Adapters.QQ.API do
  @moduledoc false

  alias :persistent_term, as: PersistentTerm
  alias LawnBot.Adapters.QQ.Utils
  alias LawnBot.Attachment
  alias LawnBot.Response
  alias LawnBot.Utils, as: SharedUtils

  require Logger

  @api_base_url "https://api.bot.qq.com"
  @token_url "#{@api_base_url}/app/getAppAccessToken"
  @gateway_url "#{@api_base_url}/gateway/bot"
  @inline_upload_limit 5 * 1024 * 1024
  @md5_10m_limit 10_002_432
  @hash_read_size 1_048_576
  @upload_concurrency 4
  @upload_part_timeout 120_000

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp)
  @video_extensions ~w(.mp4)
  @audio_extensions ~w(.silk .mp3 .wav .flac .ogg)

  @spec fetch_access_token(atom()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}}
          | {:error, {:invalid_field_type, String.t()}}
          | Utils.api_call_error()
  def fetch_access_token(name) do
    body = %{
      "appId" => PersistentTerm.get({name, :app_id}),
      "clientSecret" => PersistentTerm.get({name, :client_secret})
    }

    case Req.post(@token_url, json: body, finch: finch(name)) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"access_token" => access_token, "expires_in" => expires_in}
       }} ->
        with {:ok, access_token} <- SharedUtils.check_empty_string(access_token),
             {:ok, expires_in} <- SharedUtils.check_pos_int(expires_in) do
          {:ok, %{access_token: token(access_token), expires_in: expires_in}}
        else
          {:error, message} -> {:error, {:invalid_field_type, message}}
        end

      error ->
        Utils.check_api_call_error(error)
    end
  end

  @spec fetch_gateway(atom(), String.t()) ::
          {:ok, %{url: String.t(), max_concurrency: pos_integer(), remaining: non_neg_integer()}}
          | {:error, {:invalid_field_type, String.t()}}
          | Utils.api_call_error()
  def fetch_gateway(name, access_token) do
    headers = %{"authorization" => access_token}

    case Req.get(@gateway_url, headers: headers, finch: finch(name)) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "url" => url,
           "session_start_limit" => %{
             "max_concurrency" => max_concurrency,
             "remaining" => remaining
           }
         }
       }}
      when is_binary(url) ->
        with {:ok, max_concurrency} <- SharedUtils.check_pos_int(max_concurrency),
             {:ok, remaining} <- SharedUtils.check_non_neg_int(remaining) do
          {:ok, %{url: url, max_concurrency: max_concurrency, remaining: remaining}}
        else
          {:error, message} -> {:error, {:invalid_gateway_response, message}}
        end

      error ->
        Utils.check_api_call_error(error)
    end
  end

  @doc "Sends a `LawnBot.Response` to a QQ group or C2C session."
  @spec send_message(atom(), String.t(), Response.t()) :: :ok | Utils.api_call_error()
  def send_message(name, access_token, %Response{action: action} = response)
      when action in [:reply, :new_message] do
    with {:ok, message} <- build_message(response, name, access_token) do
      message =
        if action == :reply do
          Map.put(message, "msg_id", response.reply_message_id)
        else
          message
        end

      headers = %{"authorization" => access_token, "content-type" => "application/json"}

      case Req.post(message_url(response), headers: headers, json: message, finch: finch(name)) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        error ->
          Utils.check_api_call_error(error)
      end
    end
  end

  def send_message(_name, _access_token, _response), do: :ok

  defp build_message(%Response{attachment: nil} = response, _name, _access_token) do
    {:ok, message_payload(response, 0)}
  end

  defp build_message(%Response{attachment: attachment} = response, name, access_token) do
    case upload_attachment(name, access_token, response, attachment) do
      {:ok, file_info} ->
        {:ok,
         response
         |> message_payload(7)
         |> Map.put("media", %{"file_info" => file_info})}

      {:error, reason} ->
        Logger.warning("Failed to upload attachment: #{inspect(reason)}")

        if is_binary(response.text) and response.text != "" do
          {:ok, message_payload(response, 0)}
        else
          {:error, reason}
        end
    end
  end

  defp message_payload(response, msg_type) do
    %{}
    |> maybe_put("content", response.text)
    |> maybe_put("message_reference", reference(response.reference_message_id))
    |> Map.put("msg_type", msg_type)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reference(nil), do: nil
  defp reference(message_id), do: %{"message_id" => message_id}

  defp message_url(response) do
    case response.session_type do
      :group -> "#{@api_base_url}/v2/groups/#{response.session_id}/messages"
      :c2c -> "#{@api_base_url}/v2/users/#{response.session_id}/messages"
    end
  end

  defp upload_attachment(name, access_token, response, attachment) do
    with {:ok, source} <- resolve_attachment(attachment) do
      upload_source(name, access_token, response, source)
    end
  end

  defp upload_source(name, access_token, response, %{kind: :url} = source) do
    body = %{"file_type" => source.file_type, "url" => source.url, "srv_send_msg" => false}
    upload(name, access_token, response, body)
  end

  defp upload_source(name, access_token, response, %{kind: :file} = source) do
    if source.size <= @inline_upload_limit do
      with {:ok, binary} <- File.read(source.path) do
        upload_inline(
          name,
          access_token,
          response,
          Map.merge(source, %{kind: :binary, binary: binary})
        )
      end
    else
      upload_chunked_file(name, access_token, response, source)
    end
  end

  defp upload_source(name, access_token, response, %{kind: :binary} = source) do
    if byte_size(source.binary) <= @inline_upload_limit do
      upload_inline(name, access_token, response, source)
    else
      upload_chunked_binary(name, access_token, response, source)
    end
  end

  defp upload_inline(name, access_token, response, source) do
    upload(name, access_token, response, %{
      "file_type" => source.file_type,
      "file_name" => source.file_name,
      "file_data" => Base.encode64(source.binary),
      "srv_send_msg" => false
    })
  end

  defp upload_chunked_binary(name, access_token, response, source) do
    hashes = hashes_for_binary(source.binary)

    with {:ok, prepared} <-
           prepare_upload(name, access_token, response, source, byte_size(source.binary), hashes),
         {:ok, chunks} <- slice_parts(source.binary, prepared.parts),
         :ok <- upload_parts(name, access_token, response, prepared.upload_id, chunks) do
      complete_upload(name, access_token, response, prepared.upload_id, source)
    end
  end

  defp upload_chunked_file(name, access_token, response, source) do
    with {:ok, hashes} <- hashes_for_file(source.path),
         {:ok, prepared} <-
           prepare_upload(name, access_token, response, source, source.size, hashes),
         :ok <- validate_parts(prepared.parts, source.size),
         :ok <-
           upload_file_parts(
             name,
             access_token,
             response,
             prepared.upload_id,
             prepared.parts,
             source.path
           ) do
      complete_upload(name, access_token, response, prepared.upload_id, source)
    end
  end

  defp upload(name, access_token, response, body) do
    upload_url = "#{@api_base_url}#{files_path(response)}"
    headers = %{"authorization" => access_token, "content-type" => "application/json"}

    case Req.post(upload_url, headers: headers, json: body, finch: finch(name)) do
      {:ok, %Req.Response{status: 200, body: %{"file_info" => file_info}}}
      when is_binary(file_info) ->
        {:ok, file_info}

      error ->
        Utils.check_api_call_error(error)
    end
  end

  defp prepare_upload(name, access_token, response, source, size, hashes) do
    body = %{
      "file_type" => source.file_type,
      "file_size" => Integer.to_string(size),
      "file_name" => source.file_name,
      "md5" => hashes.md5,
      "sha1" => hashes.sha1,
      "md5_10m" => hashes.md5_10m
    }

    with {:ok, body} <- post_api(name, access_token, prepare_path(response), body) do
      parse_prepare(body)
    end
  end

  defp parse_prepare(body) do
    with upload_id when is_binary(upload_id) and upload_id != "" <- body["upload_id"],
         parts when is_list(parts) and parts != [] <- body["parts"],
         {:ok, parts} <- parse_parts(parts) do
      {:ok, %{upload_id: upload_id, parts: parts}}
    else
      _other -> {:error, {:invalid_field_type, "invalid chunked upload preparation"}}
    end
  end

  defp parse_parts(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      with index when is_integer(index) or is_binary(index) <- part["index"],
           {:ok, index} <- parse_int(index),
           url when is_binary(url) and url != "" <- part["presigned_url"],
           {:ok, size} <- parse_int(part["block_size"]) do
        {:cont, {:ok, [%{index: index, url: url, size: size} | acc]}}
      else
        _other -> {:halt, {:error, {:invalid_field_type, "invalid upload part"}}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.sort_by(parts, & &1.index)}
      error -> error
    end
  end

  defp slice_parts(binary, parts) do
    parts
    |> Enum.reduce_while({:ok, [], 0}, fn part, {:ok, acc, offset} ->
      if offset + part.size <= byte_size(binary) do
        chunk = binary_part(binary, offset, part.size)
        {:cont, {:ok, [{part, chunk} | acc], offset + part.size}}
      else
        {:halt, {:error, "upload part exceeds attachment size"}}
      end
    end)
    |> case do
      {:ok, chunks, offset} when offset == byte_size(binary) -> {:ok, Enum.reverse(chunks)}
      _other -> {:error, "upload parts do not cover attachment size"}
    end
  end

  defp upload_parts(name, access_token, response, upload_id, chunks) do
    chunks
    |> Task.async_stream(
      fn {part, chunk} ->
        with :ok <- put_part(part, chunk), do: {:ok, part_metadata(part, chunk)}
      end,
      async_stream_options()
    )
    |> collect_parts()
    |> case do
      {:ok, parts} -> finish_parts(name, access_token, response, upload_id, parts)
      error -> error
    end
  end

  defp validate_parts(parts, size) do
    if Enum.sum(Enum.map(parts, & &1.size)) == size do
      :ok
    else
      {:error, "upload parts do not cover attachment size"}
    end
  end

  defp upload_file_parts(name, access_token, response, upload_id, parts, path) do
    parts
    |> with_offsets()
    |> Task.async_stream(
      fn {part, offset} ->
        with {:ok, chunk} <- read_part(path, offset, part.size),
             :ok <- put_part(part, chunk) do
          {:ok, part_metadata(part, chunk)}
        end
      end,
      async_stream_options()
    )
    |> collect_parts()
    |> case do
      {:ok, parts} -> finish_parts(name, access_token, response, upload_id, parts)
      error -> error
    end
  end

  defp with_offsets(parts) do
    {parts, _size} =
      Enum.map_reduce(parts, 0, fn part, offset -> {{part, offset}, offset + part.size} end)

    parts
  end

  # Raw file handles are owned by the process that opened them, and tasks are
  # spawned per part, so each task opens its own handle and reads by offset.
  defp read_part(path, offset, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case :file.pread(file, offset, size) do
            {:ok, chunk} when byte_size(chunk) == size -> {:ok, chunk}
            :eof -> {:error, "unexpected end of attachment file"}
            {:ok, _short} -> {:error, "unexpected end of attachment file"}
            {:error, reason} -> {:error, :file.format_error(reason)}
          end
        after
          :file.close(file)
        end

      {:error, reason} ->
        {:error, "failed to read attachment: #{:file.format_error(reason)}"}
    end
  end

  defp part_metadata(part, chunk) do
    %{part: part, size: byte_size(chunk), md5: hash(:md5, chunk)}
  end

  defp async_stream_options do
    [
      max_concurrency: @upload_concurrency,
      ordered: true,
      timeout: @upload_part_timeout
    ]
  end

  defp collect_parts(stream) do
    stream
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, part}}, {:ok, parts} -> {:cont, {:ok, [part | parts]}}
      {:ok, {:error, _reason} = error}, _parts -> {:halt, error}
      {:exit, reason}, _parts -> {:halt, {:error, "upload part failed: #{inspect(reason)}"}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp finish_parts(name, access_token, response, upload_id, parts) do
    # The API rejects finishing a part while earlier parts are unfinished
    # ("前序分片未完成"), so finishes run in part order even though PUTs do not.
    Enum.reduce_while(parts, :ok, fn %{part: part, size: size, md5: md5}, :ok ->
      body = %{
        "upload_id" => upload_id,
        "part_index" => part.index,
        "block_size" => size,
        "md5" => md5
      }

      case post_api(name, access_token, part_finish_path(response), body) do
        {:ok, _body} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp hashes_for_binary(binary) do
    %{
      md5: hash(:md5, binary),
      sha1: hash(:sha, binary),
      md5_10m: hash(:md5, binary_part(binary, 0, min(byte_size(binary), @md5_10m_limit)))
    }
  end

  defp hashes_for_file(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          stream_hashes(
            file,
            :crypto.hash_init(:md5),
            :crypto.hash_init(:sha),
            :crypto.hash_init(:md5),
            @md5_10m_limit
          )
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, "failed to read attachment: #{:file.format_error(reason)}"}
    end
  end

  defp stream_hashes(file, md5, sha1, md5_10m, remaining_10m) do
    case IO.binread(file, @hash_read_size) do
      :eof ->
        {:ok,
         %{
           md5: final_hash(md5),
           sha1: final_hash(sha1),
           md5_10m: final_hash(md5_10m)
         }}

      data when is_binary(data) ->
        md5 = :crypto.hash_update(md5, data)
        sha1 = :crypto.hash_update(sha1, data)
        {md5_10m, remaining_10m} = update_md5_10m(md5_10m, data, remaining_10m)
        stream_hashes(file, md5, sha1, md5_10m, remaining_10m)

      {:error, reason} ->
        {:error, :file.format_error(reason)}
    end
  end

  defp update_md5_10m(context, _data, remaining) when remaining <= 0, do: {context, 0}

  defp update_md5_10m(context, data, remaining) do
    size = min(byte_size(data), remaining)
    context = :crypto.hash_update(context, binary_part(data, 0, size))
    {context, remaining - size}
  end

  defp final_hash(context), do: context |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp put_part(part, chunk) do
    case Req.put(part.url, body: chunk) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp complete_upload(name, access_token, response, upload_id, source) do
    body = %{
      "file_type" => source.file_type,
      "file_name" => source.file_name,
      "upload_id" => upload_id,
      "srv_send_msg" => false
    }

    with {:ok, body} <- post_api(name, access_token, files_path(response), body),
         file_info when is_binary(file_info) <- body["file_info"] do
      {:ok, file_info}
    else
      _other -> {:error, {:invalid_field_type, "chunked upload completed without file_info"}}
    end
  end

  defp post_api(name, access_token, path, body) do
    headers = %{"authorization" => access_token, "content-type" => "application/json"}

    case Req.post("#{@api_base_url}#{path}",
           headers: headers,
           json: body,
           finch: finch(name)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      error ->
        Utils.check_api_call_error(error)
    end
  end

  defp hash(algorithm, binary), do: algorithm |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _other -> {:error, {:invalid_field_type, "invalid integer"}}
    end
  end

  defp parse_int(_value), do: {:error, {:invalid_field_type, "invalid integer"}}

  defp files_path(%Response{session_type: :group, session_id: session_id}),
    do: "/v2/groups/#{session_id}/files"

  defp files_path(%Response{session_type: :c2c, session_id: session_id}),
    do: "/v2/users/#{session_id}/files"

  defp prepare_path(%Response{session_type: :group, session_id: session_id}),
    do: "/v2/groups/#{session_id}/upload_prepare"

  defp prepare_path(%Response{session_type: :c2c, session_id: session_id}),
    do: "/v2/users/#{session_id}/upload_prepare"

  defp part_finish_path(%Response{session_type: :group, session_id: session_id}),
    do: "/v2/groups/#{session_id}/upload_part_finish"

  defp part_finish_path(%Response{session_type: :c2c, session_id: session_id}),
    do: "/v2/users/#{session_id}/upload_part_finish"

  defp resolve_attachment({:url, url}) when is_binary(url) do
    file_name = filename_from_url(url)
    {:ok, %{kind: :url, url: url, file_name: file_name, file_type: file_type(file_name, nil)}}
  end

  defp resolve_attachment({:path, path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, stat} ->
        file_source(path, Path.basename(path), MIME.from_path(path), stat.size)

      {:error, reason} ->
        {:error, "failed to read attachment: #{:file.format_error(reason)}"}
    end
  end

  defp resolve_attachment({:binary, binary}) when is_binary(binary) do
    binary_source(binary, "attachment", nil)
  end

  defp resolve_attachment(%Attachment{} = attachment) do
    cond do
      is_binary(attachment.url) ->
        file_name = attachment.filename || filename_from_url(attachment.url)

        {:ok,
         %{
           kind: :url,
           url: attachment.url,
           file_name: file_name,
           file_type: file_type(file_name, attachment.mime_type)
         }}

      is_binary(attachment.filename) and File.regular?(attachment.filename) ->
        case File.stat(attachment.filename) do
          {:ok, stat} ->
            file_source(
              attachment.filename,
              Path.basename(attachment.filename),
              attachment.mime_type || MIME.from_path(attachment.filename),
              stat.size
            )

          {:error, reason} ->
            {:error, "failed to read attachment: #{:file.format_error(reason)}"}
        end

      true ->
        {:error, "attachment has no url or readable path"}
    end
  end

  defp resolve_attachment(_attachment), do: {:error, "unsupported attachment"}

  defp file_source(path, file_name, mime_type, size) do
    {:ok,
     %{
       kind: :file,
       path: path,
       file_name: file_name,
       file_type: file_type(file_name, mime_type),
       size: size
     }}
  end

  defp binary_source(binary, file_name, mime_type) do
    {:ok,
     %{
       kind: :binary,
       binary: binary,
       file_name: file_name,
       file_type: file_type(file_name, mime_type)
     }}
  end

  defp file_type(file_name, mime_type) do
    extension = Path.extname(String.downcase(file_name || ""))

    cond do
      image_media?(extension, mime_type) -> 1
      video_media?(extension, mime_type) -> 2
      audio_media?(extension, mime_type) -> 3
      true -> 4
    end
  end

  defp image_media?(extension, mime_type) do
    mime_prefix?(mime_type, "image/") or extension in @image_extensions
  end

  defp video_media?(extension, mime_type) do
    mime_prefix?(mime_type, "video/") or extension in @video_extensions
  end

  defp audio_media?(extension, mime_type) do
    mime_prefix?(mime_type, "audio/") or extension in @audio_extensions
  end

  defp mime_prefix?(mime_type, prefix) when is_binary(mime_type),
    do: String.starts_with?(mime_type, prefix)

  defp mime_prefix?(_mime_type, _prefix), do: false

  defp filename_from_url(url) do
    case URI.parse(url).path do
      nil -> "attachment"
      "" -> "attachment"
      path -> Path.basename(path)
    end
  end

  defp token(access_token), do: "QQBot #{access_token}"

  defp finch(name), do: [name: LawnBot.Finch, pool_tag: name]
end
