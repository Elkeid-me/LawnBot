defmodule LawnBot.Adapters.QQTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ

  @config %{app_id: "app", client_secret: "secret"}

  test "ignores configuration without credentials" do
    assert :ignore = QQ.start_link(%{})
    assert :ignore = QQ.start_link(%{app_id: "", client_secret: "secret"})
    assert :ignore = QQ.start_link(%{app_id: "app", client_secret: ""})
  end

  test "names the bot after the configured name or app id" do
    assert QQ.bot_name(@config) == "QQ Bot: app"
    assert QQ.bot_name(Map.put(@config, :name, "LawnBot")) == "QQ Bot: LawnBot"
  end

  test "converts a group message into an event" do
    payload = %{
      "t" => "GROUP_AT_MESSAGE_CREATE",
      "d" => %{
        "id" => "message-1",
        "group_openid" => "group-1",
        "content" => "hello",
        "message_type" => 0,
        "author" => %{"member_openid" => "member-1"}
      }
    }

    assert %LawnBot.Event{
             session_type: :group,
             session_id: "group-1",
             message_type: :normal,
             message_id: "message-1",
             author_id: "member-1",
             content: "hello"
           } = QQ.to_event(payload)
  end

  test "converts a c2c message into an event" do
    payload = %{
      "t" => "C2C_MESSAGE_CREATE",
      "d" => %{
        "id" => "message-2",
        "content" => "hi",
        "message_type" => 0,
        "author" => %{"user_openid" => "user-1"}
      }
    }

    assert %LawnBot.Event{session_type: :c2c, session_id: "user-1", author_id: "user-1"} =
             QQ.to_event(payload)
  end

  test "initializes a rest-for-one supervisor with restart limits" do
    start_finch()

    assert {:ok, {%{strategy: :rest_for_one, intensity: 3, period: 30}, _children}} =
             QQ.init(@config)
  end

  # `QQ.init/1` 会为 `LawnBot.Finch` 建一个 pool 子进程，需要 Finch 实例已经存在。
  # 正常启动时由 `LawnBot.Application` 负责，`mix test --no-start` 下则由这里兜底。
  defp start_finch do
    case Finch.start_link(name: LawnBot.Finch) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
