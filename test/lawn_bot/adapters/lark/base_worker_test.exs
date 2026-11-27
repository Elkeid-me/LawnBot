defmodule LawnBot.Adapters.Lark.BaseWorkerTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.Feishu.Worker
  alias LawnBot.Adapters.Lark.Frame
  alias LawnBot.Adapters.Lark.Utils
  alias LawnBot.Response
  alias LawnBot.TestReqStub
  alias LawnBot.TokenStore

  @moduletag capture_log: true

  @bot :LarkWorkerTestBot
  @token "t-token"
  @messages_path "/open-apis/im/v1/messages"

  setup do
    ensure_token_store()
    TokenStore.put(@bot, @token)
    :persistent_term.put(@bot, fn _event -> %Response{action: :ignore} end)

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    start_registry()
    start_task_supervisor()

    on_exit(fn ->
      :persistent_term.erase(@bot)
      :persistent_term.erase({TestReqStub, @messages_path})

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
    name = Utils.task_supervisor_via_tuple(Worker, @bot)

    case Registry.lookup(LawnBot.AdapterRegistry, {Worker, {:task_supervisor, @bot}}) do
      [] -> start_supervised!({Task.Supervisor, name: name})
      _pids -> :ok
    end
  end

  defp state(overrides \\ []) do
    struct!(
      %Worker{
        name: @bot,
        url: "wss://msg.example.com/ws?service_id=42",
        service_id: 42,
        ping_interval: 1_000
      },
      overrides
    )
  end

  defp event_payload(content \\ ~s({"text":"hello"})) do
    %{
      "schema" => "2.0",
      "header" => %{"event_type" => "im.message.receive_v1"},
      "event" => %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou-user"}
        },
        "message" => %{
          "message_id" => "om-message",
          "chat_id" => "oc-chat",
          "chat_type" => "group",
          "message_type" => "text",
          "content" => content
        }
      }
    }
  end

  defp data_frame(payload, headers \\ %{"type" => "event"}) do
    %Frame{seq_id: 7, service: 42, method: 1, headers: Frame.header_list(headers), payload: payload}
  end

  defp ack_body(ack_binary) do
    assert {:ok, ack} = Frame.decode_frame(ack_binary)
    {ack, JSON.decode!(ack.payload)}
  end

  test "ACKs data frames and dispatches events" do
    test_pid = self()

    :persistent_term.put(@bot, fn event ->
      send(test_pid, {:handled, event})
      %Response{action: :ignore}
    end)

    frame = data_frame(JSON.encode!(event_payload()))

    assert {:reply, {:binary, ack_binary}, _updated} =
             Worker.handle_frame({:binary, Frame.encode_frame(frame)}, state())

    {ack, body} = ack_body(ack_binary)

    assert ack.seq_id == 7
    assert ack.service == 42
    assert Frame.get_header(ack, "biz_rt") == "0"
    assert Frame.get_header(ack, "type") == "event"
    assert body == %{"code" => 200, "headers" => %{}, "data" => []}

    assert_receive {:handled,
                    %LawnBot.Event{
                      content: "hello",
                      session_id: "oc-chat",
                      session_type: :group,
                      message_id: "om-message",
                      author_id: "ou-user"
                    }},
                   2_000
  end

  test "does not dispatch non-event data frames" do
    frame = data_frame("{}", %{"type" => "card"})

    assert {:reply, {:binary, ack_binary}, _updated} =
             Worker.handle_frame({:binary, Frame.encode_frame(frame)}, state())

    {_ack, body} = ack_body(ack_binary)
    assert body["code"] == 200
    refute_receive {:handled, _event}, 100
  end

  test "acknowledges but ignores malformed event payloads" do
    test_pid = self()
    :persistent_term.put(@bot, fn event -> send(test_pid, {:handled, event}) end)

    for payload <- ["not-json", "[]", ~s("text")] do
      frame = data_frame(payload)

      assert {:reply, {:binary, ack_binary}, _updated} =
               Worker.handle_frame({:binary, Frame.encode_frame(frame)}, state())

      {_ack, body} = ack_body(ack_binary)
      assert body["code"] == 200
    end

    refute_receive {:handled, _event}, 100
  end

  test "combines fragmented event payloads before dispatching" do
    test_pid = self()

    :persistent_term.put(@bot, fn event ->
      send(test_pid, {:handled, event})
      %Response{action: :ignore}
    end)

    payload = JSON.encode!(event_payload())
    split_at = div(byte_size(payload), 2)
    first = binary_part(payload, 0, split_at)
    second = binary_part(payload, split_at, byte_size(payload) - split_at)

    first_frame =
      data_frame(first, %{"type" => "event", "message_id" => "frag-1", "sum" => "2", "seq" => "0"})

    second_frame =
      data_frame(second, %{"type" => "event", "message_id" => "frag-1", "sum" => "2", "seq" => "1"})

    assert {:reply, {:binary, _ack}, state_after_first} =
             Worker.handle_frame({:binary, Frame.encode_frame(first_frame)}, state())

    refute_receive {:handled, _event}, 100
    assert map_size(state_after_first.fragments) == 1

    assert {:reply, {:binary, _ack}, state_after_second} =
             Worker.handle_frame({:binary, Frame.encode_frame(second_frame)}, state_after_first)

    assert state_after_second.fragments == %{}
    assert_receive {:handled, %LawnBot.Event{content: "hello"}}, 2_000
  end

  test "updates the ping interval from pong frames" do
    frame = %Frame{
      method: 0,
      service: 42,
      headers: Frame.header_list(%{"type" => "pong"}),
      payload: ~s({"PingInterval":30})
    }

    assert {:ok, updated} =
             Worker.handle_frame({:binary, Frame.encode_frame(frame)}, state())

    assert updated.ping_interval == 30_000
    assert is_reference(updated.ping_ref)

    Process.cancel_timer(updated.ping_ref)
  end

  test "sends a ping and schedules the next heartbeat" do
    shard_state = state()

    assert {:reply, {:binary, ping_binary}, updated} = Worker.handle_info(:ping, shard_state)
    assert {:ok, ping} = Frame.decode_frame(ping_binary)

    assert ping.method == 0
    assert ping.service == 42
    assert Frame.get_header(ping, "type") == "ping"
    assert ping.seq_id == 1
    assert is_reference(updated.ping_ref)

    Process.cancel_timer(updated.ping_ref)
  end

  test "reconnects when no inbound frame arrives for too long" do
    now = System.monotonic_time(:millisecond)

    stale =
      state(
        ping_interval: 1_000,
        last_frame_at: now - 10_000
      )

    assert {:close, _state} = Worker.handle_info(:ping, stale)
  end

  test "replies to a server ping" do
    frame = %Frame{
      seq_id: 3,
      method: 0,
      service: 42,
      headers: Frame.header_list(%{"type" => "ping"})
    }

    assert {:reply, {:binary, pong_binary}, _state} =
             Worker.handle_frame({:binary, Frame.encode_frame(frame)}, state())

    assert {:ok, pong} = Frame.decode_frame(pong_binary)
    assert Frame.get_header(pong, "type") == "pong"
    assert pong.seq_id == 3
  end

  test "cancels timers on connect and sends an initial ping" do
    connected =
      state(ping_ref: Process.send_after(self(), :old_ping, 10_000))

    assert {:ok, updated} = Worker.handle_connect(:conn, connected)
    assert updated.ping_ref == nil
    assert updated.last_frame_at != 0
    assert_receive :ping, 100
  end

  test "ignores malformed frames" do
    shard_state = state()

    assert {:ok, updated} =
             Worker.handle_frame({:binary, "not-protobuf"}, shard_state)

    assert updated.last_frame_at != 0
    assert {:ok, ^shard_state} = Worker.handle_frame({:text, "text"}, shard_state)
  end

  test "sends a response from the handler" do
    test_pid = self()

    :persistent_term.put({TestReqStub, @messages_path}, fn request ->
      send(test_pid, {:request, request})
      Req.Response.new(status: 200, body: %{"code" => 0})
    end)

    :persistent_term.put(@bot, fn _event ->
      %Response{
        action: :new_message,
        session_id: "oc-chat",
        session_type: :group,
        text: "pong"
      }
    end)

    frame = data_frame(JSON.encode!(event_payload()))

    assert {:reply, {:binary, _ack}, _updated} =
             Worker.handle_frame({:binary, Frame.encode_frame(frame)}, state())

    assert_receive {:request, request}, 2_000
    body = request.body |> IO.iodata_to_binary() |> JSON.decode!()

    assert body["receive_id"] == "oc-chat"
    assert body["msg_type"] == "text"
    assert body["content"] == ~s({"text":"pong"})
    assert Req.Request.get_header(request, "authorization") == ["Bearer " <> @token]
  end
end
