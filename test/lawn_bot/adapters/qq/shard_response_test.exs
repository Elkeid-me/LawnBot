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

  @group_messages "/v2/groups/group-1/messages"
  @c2c_messages "/v2/users/user-1/messages"
  @group_files "/v2/groups/group-1/files"
  @all_paths [@group_messages, @c2c_messages, @group_files]

  setup do
    ensure_token_store()
    TokenStore.put(@bot, @token)
    :persistent_term.put({@bot, :shards}, 1)

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    start_registry()
    start_task_supervisor()

    on_exit(fn ->
      :persistent_term.erase(@bot)
      :persistent_term.erase({@bot, :shards})
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

  test "does not upload path attachments" do
    stub(@group_messages)

    dispatch(fn _event ->
      %Response{
        action: :new_message,
        session_id: "group-1",
        reply_message_id: nil,
        session_type: :group,
        text: "file",
        attachment: {:path, "C:\\tmp\\image.png"},
        reference_message_id: nil
      }
    end)

    assert_receive {:request, @group_messages, message}, 2_000

    assert json_body(message) == %{
             "content" => "file",
             "media" => %{"file_info" => nil},
             "msg_type" => 7
           }

    refute_receive {:request, @group_files, _request}, 100
  end

  test "sends the message without media when the upload fails" do
    stub(@group_files, Req.Response.new(status: 400, body: %{"message" => "too large"}))
    stub(@group_messages)

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
    assert_receive {:request, @group_messages, message}, 2_000

    assert json_body(message) == %{
             "media" => %{"file_info" => nil},
             "msg_id" => "message-1",
             "msg_type" => 7
           }
  end

  test "does not send anything for ignored responses" do
    dispatch(fn _event -> %Response{action: :ignore} end)

    refute_receive {:request, _path, _request}, 200
  end
end
