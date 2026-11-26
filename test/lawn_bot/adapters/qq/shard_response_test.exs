defmodule LawnBot.Adapters.QQ.ShardResponseTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.QQ.Shard
  alias LawnBot.Adapters.QQ.Utils
  alias LawnBot.Response
  alias LawnBot.TestReqStub
  alias LawnBot.TokenStore

  @moduletag capture_log: true

  @bot :ShardResponseTestBot
  @token "QQBot access-token"
  @inline_limit 5 * 1024 * 1024

  @group_messages "/v2/groups/group-1/messages"
  @c2c_messages "/v2/users/user-1/messages"
  @group_files "/v2/groups/group-1/files"
  @group_prepare "/v2/groups/group-1/upload_prepare"
  @group_part_finish "/v2/groups/group-1/upload_part_finish"
  @upload_part_0 "/part-0"
  @upload_part_1 "/part-1"
  @all_paths [
    @group_messages,
    @c2c_messages,
    @group_files,
    @group_prepare,
    @group_part_finish,
    @upload_part_0,
    @upload_part_1
  ]

  setup do
    ensure_token_store()
    TokenStore.put(@bot, @token)
    :persistent_term.put({@bot, :workers}, 1)

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    start_registry()
    start_task_supervisor()

    on_exit(fn ->
      :persistent_term.erase(@bot)
      :persistent_term.erase({@bot, :workers})
      Enum.each(@all_paths, fn path -> :persistent_term.erase({TestReqStub, path}) end)

      case previous_req_options do
        {:ok, options} -> Elixir.Application.put_env(:req, :default_options, options)
        :error -> Elixir.Application.delete_env(:req, :default_options)
      end
    end)

    :ok
  end

  defp ensure_token_store do
    case :ets.whereis(:auth_tokens) do
      :undefined -> TokenStore.new()
      _table -> :ok
    end
  end

  defp start_registry do
    if Process.whereis(LawnBot.AdapterRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: LawnBot.AdapterRegistry})
    end

    :ok
  end

  defp start_task_supervisor do
    name = Utils.task_supervisor_via_tuple(@bot)

    case Registry.lookup(LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, @bot}) do
      [] -> start_supervised!({Task.Supervisor, name: name})
      _pids -> :ok
    end
  end

  defp stub(path, response \\ Req.Response.new(status: 200, body: %{})) do
    test_pid = self()

    :persistent_term.put({TestReqStub, path}, fn request ->
      send(test_pid, {:request, path, request})
      response
    end)
  end

  defp dispatch(handler) do
    :persistent_term.put(@bot, handler)

    payload = %{
      "op" => 0,
      "t" => "GROUP_MESSAGE_CREATE",
      "s" => 1,
      "d" => %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "hello",
        "message_type" => 0,
        "author" => %{"member_openid" => "member-1"}
      }
    }

    assert {:ok, %Shard{seq: 1}} =
             Shard.handle_frame(
               {:text, JSON.encode!(payload)},
               %Shard{name: @bot, shard_id: 0}
             )
  end

  defp json_body(request) do
    request.body |> IO.iodata_to_binary() |> JSON.decode!()
  end

  test "sends a reply with text and a message reference" do
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :reply,
        session_id: "group-1",
        reply_message_id: "message-1",
        session_type: :group,
        text: "pong",
        attachment: nil,
        reference_message_id: "message-0"
      }
    end)

    assert_receive {:request, @group_messages, request}, 2_000

    assert request.method == :post
    assert URI.to_string(request.url) == "https://api.bot.qq.com" <> @group_messages
    assert Req.Request.get_header(request, "authorization") == [@token]
    assert Req.Request.get_header(request, "content-type") == ["application/json"]

    assert json_body(request) == %{
             "content" => "pong",
             "message_reference" => %{"message_id" => "message-0"},
             "msg_id" => "message-1",
             "msg_type" => 0
           }
  end

  test "sends a new C2C message" do
    stub(@c2c_messages)

    dispatch(fn _event ->
      %Response{
        action: :new_message,
        session_id: "user-1",
        reply_message_id: nil,
        session_type: :c2c,
        text: "hello",
        attachment: nil,
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @c2c_messages, request}, 2_000

    assert URI.to_string(request.url) == "https://api.bot.qq.com" <> @c2c_messages
    assert json_body(request) == %{"content" => "hello", "msg_type" => 0}
  end

  test "uploads a url attachment before sending a multimedia message" do
    stub(@group_files, Req.Response.new(status: 200, body: %{"file_info" => "file-info"}))
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :reply,
        session_id: "group-1",
        reply_message_id: "message-1",
        session_type: :group,
        text: "look",
        attachment: {:url, "https://example.com/image.png"},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_files, upload}, 2_000

    assert json_body(upload) == %{
             "file_type" => 1,
             "url" => "https://example.com/image.png",
             "srv_send_msg" => false
           }

    assert_receive {:request, @group_messages, message}, 2_000

    assert json_body(message) == %{
             "content" => "look",
             "media" => %{"file_info" => "file-info"},
             "msg_id" => "message-1",
             "msg_type" => 7
           }
  end

  test "uploads a path attachment as base64" do
    path =
      Path.join(
        System.tmp_dir!(),
        "qq-shard-attachment-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, "png-data")
    on_exit(fn -> File.rm(path) end)

    stub(@group_files, Req.Response.new(status: 200, body: %{"file_info" => "file-info"}))
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :new_message,
        session_id: "group-1",
        reply_message_id: nil,
        session_type: :group,
        text: "file",
        attachment: {:path, path},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_files, upload}, 2_000

    assert json_body(upload) == %{
             "file_type" => 1,
             "file_name" => Path.basename(path),
             "file_data" => Base.encode64("png-data"),
             "srv_send_msg" => false
           }

    assert_receive {:request, @group_messages, message}, 2_000

    assert json_body(message) == %{
             "content" => "file",
             "media" => %{"file_info" => "file-info"},
             "msg_type" => 7
           }
  end

  test "uploads a binary attachment as base64" do
    stub(@group_files, Req.Response.new(status: 200, body: %{"file_info" => "binary-file-info"}))
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :new_message,
        session_id: "group-1",
        reply_message_id: nil,
        session_type: :group,
        text: nil,
        attachment: {:binary, "binary-data"},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_files, upload}, 2_000

    assert json_body(upload) == %{
             "file_type" => 4,
             "file_name" => "attachment",
             "file_data" => Base.encode64("binary-data"),
             "srv_send_msg" => false
           }

    assert_receive {:request, @group_messages, message}, 2_000

    assert json_body(message) == %{
             "media" => %{"file_info" => "binary-file-info"},
             "msg_type" => 7
           }
  end

  test "uploads a large binary attachment with chunked upload" do
    binary = :binary.copy(<<1>>, @inline_limit + 1)
    <<first::binary-size(@inline_limit), second::binary>> = binary

    stub(
      @group_prepare,
      Req.Response.new(
        status: 200,
        body: %{
          "upload_id" => "upload-1",
          "block_size" => Integer.to_string(@inline_limit),
          "parts" => [
            %{
              "index" => 0,
              "presigned_url" => "https://upload.example.com/part-0",
              "block_size" => Integer.to_string(@inline_limit)
            },
            %{
              "index" => 1,
              "presigned_url" => "https://upload.example.com/part-1",
              "block_size" => "1"
            }
          ]
        }
      )
    )

    stub(@upload_part_0, Req.Response.new(status: 200, body: %{}))
    stub(@upload_part_1, Req.Response.new(status: 200, body: %{}))
    stub(@group_part_finish, Req.Response.new(status: 200, body: %{}))
    stub(@group_files, Req.Response.new(status: 200, body: %{"file_info" => "chunk-file-info"}))
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :new_message,
        session_id: "group-1",
        reply_message_id: nil,
        session_type: :group,
        text: nil,
        attachment: {:binary, binary},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_prepare, prepare}, 2_000

    prepare_body = json_body(prepare)

    assert prepare_body["file_type"] == 4
    assert prepare_body["file_size"] == Integer.to_string(byte_size(binary))
    assert prepare_body["file_name"] == "attachment"
    assert prepare_body["md5"] == Base.encode16(:crypto.hash(:md5, binary), case: :lower)
    assert prepare_body["sha1"] == Base.encode16(:crypto.hash(:sha, binary), case: :lower)

    assert_receive {:request, @upload_part_0, part_0}, 2_000
    assert part_0.method == :put
    assert part_0.body == first

    assert_receive {:request, @group_part_finish, finish_0}, 2_000
    finish_0_body = json_body(finish_0)
    assert finish_0_body["upload_id"] == "upload-1"
    assert finish_0_body["part_index"] == 0
    assert finish_0_body["block_size"] == @inline_limit
    assert finish_0_body["md5"] == Base.encode16(:crypto.hash(:md5, first), case: :lower)

    assert_receive {:request, @upload_part_1, part_1}, 2_000
    assert part_1.method == :put
    assert part_1.body == second

    assert_receive {:request, @group_part_finish, finish_1}, 2_000
    finish_1_body = json_body(finish_1)
    assert finish_1_body["upload_id"] == "upload-1"
    assert finish_1_body["part_index"] == 1
    assert finish_1_body["block_size"] == 1
    assert finish_1_body["md5"] == Base.encode16(:crypto.hash(:md5, second), case: :lower)

    assert_receive {:request, @group_files, complete}, 2_000
    complete_body = json_body(complete)
    assert complete_body["upload_id"] == "upload-1"
    assert complete_body["file_name"] == "attachment"
    assert complete_body["file_type"] == 4

    assert_receive {:request, @group_messages, message}, 2_000
    assert json_body(message)["media"] == %{"file_info" => "chunk-file-info"}
    assert json_body(message)["msg_type"] == 7
  end

  test "streams a large path attachment in chunks" do
    binary = :binary.copy(<<2>>, @inline_limit + 1)
    <<first::binary-size(@inline_limit), second::binary>> = binary
    path = Path.join(System.tmp_dir!(), "qq-large-#{System.unique_integer([:positive])}.bin")
    File.write!(path, binary)
    on_exit(fn -> File.rm(path) end)

    stub(
      @group_prepare,
      Req.Response.new(
        status: 200,
        body: %{
          "upload_id" => "file-upload-1",
          "parts" => [
            %{
              "index" => 0,
              "presigned_url" => "https://upload.example.com/part-0",
              "block_size" => Integer.to_string(@inline_limit)
            },
            %{
              "index" => 1,
              "presigned_url" => "https://upload.example.com/part-1",
              "block_size" => "1"
            }
          ]
        }
      )
    )

    stub(@upload_part_0, Req.Response.new(status: 200, body: %{}))
    stub(@upload_part_1, Req.Response.new(status: 200, body: %{}))
    stub(@group_part_finish, Req.Response.new(status: 200, body: %{}))
    stub(@group_files, Req.Response.new(status: 200, body: %{"file_info" => "file-info"}))
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :new_message,
        session_id: "group-1",
        reply_message_id: nil,
        session_type: :group,
        text: nil,
        attachment: {:path, path},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_prepare, prepare}, 2_000
    prepare_body = json_body(prepare)
    assert prepare_body["file_type"] == 4
    assert prepare_body["file_name"] == Path.basename(path)
    assert prepare_body["file_size"] == Integer.to_string(byte_size(binary))

    assert_receive {:request, @upload_part_0, part_0}, 2_000
    assert part_0.body == first

    assert_receive {:request, @group_part_finish, finish_0}, 2_000
    assert json_body(finish_0)["part_index"] == 0

    assert_receive {:request, @upload_part_1, part_1}, 2_000
    assert part_1.body == second

    assert_receive {:request, @group_part_finish, finish_1}, 2_000
    assert json_body(finish_1)["part_index"] == 1

    assert_receive {:request, @group_files, _complete}, 2_000
    assert_receive {:request, @group_messages, message}, 2_000
    assert json_body(message)["media"] == %{"file_info" => "file-info"}
  end

  test "does not send when attachment upload fails and there is no text" do
    stub(@group_files, Req.Response.new(status: 400, body: %{"message" => "too large"}))

    dispatch(fn _event ->
      %Response{
        action: :reply,
        session_id: "group-1",
        reply_message_id: "message-1",
        session_type: :group,
        text: nil,
        attachment: {:url, "https://example.com/image.png"},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_files, _upload}, 2_000
    refute_receive {:request, @group_messages, _message}, 200
  end

  test "falls back to text when attachment upload fails" do
    stub(@group_files, Req.Response.new(status: 400, body: %{"message" => "too large"}))
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :reply,
        session_id: "group-1",
        reply_message_id: "message-1",
        session_type: :group,
        text: "fallback",
        attachment: {:url, "https://example.com/image.png"},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_files, _upload}, 2_000
    assert_receive {:request, @group_messages, message}, 2_000

    assert json_body(message) == %{
             "content" => "fallback",
             "msg_id" => "message-1",
             "msg_type" => 0
           }
  end

  test "does not send anything for ignored responses" do
    dispatch(fn _event -> %Response{action: :ignore} end)

    refute_receive {:request, _path, _request}, 200
  end
end
