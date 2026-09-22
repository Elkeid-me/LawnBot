defmodule LawnBotTest do
  use ExUnit.Case

  alias LawnBot.Adapters.QQ

  # Mix 配置边界使用 keyword list 表示配置项。
  test "loads platform settings from application config" do
    Application.put_env(:lawn_bot, :platform,
      adapter: QQ,
      config: [intents: 513],
      options: [event_handler: self()]
    )

    assert [adapter: QQ, config: [intents: 513], options: [event_handler: pid]] =
             Application.fetch_env!(:lawn_bot, :platform)

    assert pid == self()
  end

  # Identify 是 Gateway 收到 Hello 后发送的第一个平台鉴权数据包，必须携带分片参数。
  test "builds QQ identify payload with shard parameter" do
    payload = QQ.identify_payload("token", %{intents: 513}, [1, 4])

    assert payload["op"] == 2
    assert payload["d"]["token"] == "QQBot token"
    assert payload["d"]["intents"] == 513
    assert payload["d"]["shard"] == [1, 4]
  end

  # Resume 用于断线重连，携带 session_id 与最近的 seq 让网关补发事件。
  test "builds QQ resume payload" do
    payload = QQ.resume_payload("token", "session-1", 42)

    assert payload["op"] == 6
    assert payload["d"] == %{"token" => "QQBot token", "session_id" => "session-1", "seq" => 42}
  end

  # intents 是标记位掩码，可用原子列表订阅，未知意图会被忽略。
  test "computes intents mask from event names" do
    assert QQ.intents(%{}) == 1 + 2 + 1_073_741_824
    assert QQ.intents(%{intents: 513}) == 513
    assert QQ.intents(%{intents: [:guilds, :group_and_c2c]}) == 1 + 33_554_432
  end

  # /gateway/bot 返回网关地址、建议分片数以及会话创建限制。
  test "parses sharded gateway response" do
    body = %{
      "shards" => 4,
      "session_start_limit" => %{"max_concurrency" => 1, "remaining" => 1000}
    }

    assert QQ.parse_gateway("wss://api.bot.qq.com/websocket/", body, %{}) == %{
             url: "wss://api.bot.qq.com/websocket/",
             shards: 4,
             max_concurrency: 1,
             remaining: 1000
           }

    # 配置可以覆盖平台建议的分片数，缺省字段按 1 处理。
    assert QQ.parse_gateway("wss://example", %{}, %{shards: 2}) == %{
             url: "wss://example",
             shards: 2,
             max_concurrency: 1,
             remaining: nil
           }

    # 文档中的数字字段可能以字符串返回，也要能解析。
    assert QQ.parse_gateway(
             "wss://example",
             %{
               "shards" => "3",
               "session_start_limit" => %{"max_concurrency" => "2", "remaining" => "10"}
             },
             %{}
           ) == %{
             url: "wss://example",
             shards: 3,
             max_concurrency: 2,
             remaining: 10
           }
  end

  # 事件保留原始数据与所属分片，便于未来处理新增的 QQ 事件类型。
  test "normalizes QQ gateway events without handling message content" do
    event = QQ.event(%{"t" => "MESSAGE_CREATE", "d" => %{"id" => "1"}, "s" => 7}, [0, 4])

    assert event == %{
             platform: :qq,
             shard: [0, 4],
             type: "MESSAGE_CREATE",
             data: %{"id" => "1"},
             seq: 7,
             raw: %{"t" => "MESSAGE_CREATE", "d" => %{"id" => "1"}, "s" => 7}
           }
  end
end
