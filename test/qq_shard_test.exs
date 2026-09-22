defmodule LawnBot.Adapters.QQ.ShardTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.Shard

  # 分片进程只依赖结构体里的连接参数，测试中把事件回投给当前测试进程。
  defp shard(overrides \\ []) do
    Map.merge(
      %Shard{
        config: %{app_id: "app", client_secret: "secret", intents: 513},
        gateway_url: "wss://example/websocket",
        shard: [0, 2],
        max_concurrency: 1,
        token: %{access_token: "token", expires_in: 7200},
        event_handler: self()
      },
      Map.new(overrides)
    )
  end

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  test "Hello 启动鉴权流程并按网关给的周期调度心跳" do
    state = shard()

    assert {:ok, state} =
             Shard.handle_frame(
               frame(%{"op" => 10, "d" => %{"heartbeat_interval" => 1_000}}),
               state
             )

    assert state.heartbeat_interval == 1_000

    assert {:reply, {:text, reply}, state} = Shard.handle_info(:authenticate, state)
    assert %{"op" => 2, "d" => identify} = Jason.decode!(reply)
    assert identify["token"] == "QQBot token"
    assert identify["intents"] == 513
    assert identify["shard"] == [0, 2]
    assert is_reference(state.heartbeat_ref)
  end

  test "READY 保存 session_id，重连时改发 Resume 补发事件" do
    state = shard()

    ready = %{"op" => 0, "s" => 1, "t" => "READY", "d" => %{"session_id" => "session-1"}}
    assert {:ok, state} = Shard.handle_frame(frame(ready), state)
    assert state.session_id == "session-1"
    assert state.seq == 1

    assert_received {:lawn_bot_event, event}
    assert event.type == "READY"
    assert event.shard == [0, 2]

    assert {:reply, {:text, reply}, _state} = Shard.handle_info(:authenticate, state)
    assert %{"op" => 6, "d" => resume} = Jason.decode!(reply)
    assert resume["session_id"] == "session-1"
    assert resume["seq"] == 1
    assert resume["token"] == "QQBot token"
  end

  test "Dispatch 记录最新 seq 并转发事件" do
    state = shard()

    dispatch = %{"op" => 0, "s" => 42, "t" => "GROUP_AT_MESSAGE_CREATE", "d" => %{"id" => "1"}}
    assert {:ok, state} = Shard.handle_frame(frame(dispatch), state)
    assert state.seq == 42

    assert_received {:lawn_bot_event, event}
    assert event.type == "GROUP_AT_MESSAGE_CREATE"
    assert event.data == %{"id" => "1"}
    assert event.raw == dispatch
  end

  test "心跳 ACK 超时会主动断开以触发重连" do
    state = shard(heartbeat_interval: 1_000)

    # 第一次心跳：发出并标记等待 ACK。
    assert {:reply, {:text, reply}, state} = Shard.handle_info(:heartbeat, state)
    assert %{"op" => 1, "d" => nil} = Jason.decode!(reply)
    assert state.awaiting_ack?

    # 收到 ACK 后可以继续下一次心跳。
    assert {:ok, state} = Shard.handle_frame(frame(%{"op" => 11}), state)
    refute state.awaiting_ack?
    assert {:reply, {:text, _reply}, state} = Shard.handle_info(:heartbeat, state)

    # 上一次心跳没有 ACK 时直接断开，由重连流程用 Resume 续上。
    assert {:close, state} = Shard.handle_info(:heartbeat, state)
    refute state.awaiting_ack?
  end

  test "Invalid Session 丢弃会话，下次连接重新 Identify" do
    state = shard(session_id: "session-1", seq: 9)

    assert {:close, state} = Shard.handle_frame(frame(%{"op" => 9, "d" => false}), state)
    assert state.session_id == nil
    assert state.seq == nil

    assert {:reply, {:text, reply}, _state} = Shard.handle_info(:authenticate, state)
    assert %{"op" => 2} = Jason.decode!(reply)
  end

  test "网关要求重连时直接断开，由重连流程 Resume" do
    state = shard(session_id: "session-1")
    assert {:close, state} = Shard.handle_frame(frame(%{"op" => 7}), state)
    assert state.session_id == "session-1"
  end

  test "token 刷新后更新连接持有的凭据" do
    state = shard()
    token = %{access_token: "new-token", expires_in: 7_200}

    assert {:ok, state} = Shard.handle_info({:qq_token_updated, token}, state)
    assert state.token == token
  end
end
