defmodule LawnBot.Adapters.QQ.CoordinatorTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.QQ.Coordinator
  alias LawnBot.TestReqStub
  alias LawnBot.TokenStore

  @moduletag capture_log: true

  @bot :CoordinatorTestBot
  @token_path "/app/getAppAccessToken"
  @gateway_path "/gateway/bot"
  @persistent_keys [:app_id, :client_secret, :shards]

  setup do
    ensure_token_store()
    TokenStore.put(@bot, "QQBot old-token")

    :persistent_term.put({@bot, :app_id}, "app")
    :persistent_term.put({@bot, :client_secret}, "secret")
    :persistent_term.put({@bot, :shards}, 1)

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    on_exit(fn ->
      Enum.each(@persistent_keys, fn key -> :persistent_term.erase({@bot, key}) end)

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

  defp state do
    %{name: @bot, attempt_number: 0, refresh_ref: nil}
  end

  defp stub(path, response) do
    Process.put({TestReqStub, path}, fn _request -> response end)
  end

  defp stub_with(path, fun) do
    Process.put({TestReqStub, path}, fun)
  end

  defp token_response(access_token, expires_in) do
    Req.Response.new(
      status: 200,
      body: %{"access_token" => access_token, "expires_in" => expires_in}
    )
  end

  test "creates a child spec keyed by module" do
    assert %{id: Coordinator, start: {Coordinator, :start_link, [:TestBot]}} =
             Coordinator.child_spec(:TestBot)
  end

  test "initializes with an asynchronous bootstrap continuation" do
    expected = state()

    assert {:ok, ^expected, {:continue, :bootstrap}} = Coordinator.init(@bot)
    assert expected.name == @bot
    assert expected.attempt_number == 0
    assert expected.refresh_ref == nil
  end

  test "builds its registry name" do
    assert {:via, Registry, {LawnBot.AdapterRegistry, {Coordinator, @bot}}} =
             Coordinator.via_tuple(@bot)
  end

  test "ignores unrelated messages" do
    coordinator_state = state()

    assert {:noreply, ^coordinator_state} = Coordinator.handle_info(:unrelated, coordinator_state)
  end

  describe "token refresh" do
    test "stores and schedules the refreshed token" do
      stub(@token_path, token_response("new-token", 7_200))

      assert {:noreply, updated} = Coordinator.handle_info(:refresh_token, state())

      assert TokenStore.get(@bot) == "QQBot new-token"
      assert updated.attempt_number == 0
      assert is_reference(updated.refresh_ref)

      Process.cancel_timer(updated.refresh_ref)
    end

    test "uses the returned expiry time for the next refresh" do
      stub(@token_path, token_response("new-token", 60))

      assert {:noreply, updated} = Coordinator.handle_info(:refresh_token, state())
      assert updated.attempt_number == 0
      assert is_reference(updated.refresh_ref)

      remaining = Process.read_timer(updated.refresh_ref)
      assert remaining > 29_000 and remaining <= 30_000

      Process.cancel_timer(updated.refresh_ref)
    end

    test "retries with exponential backoff on API errors" do
      stub(
        @token_path,
        Req.Response.new(
          status: 401,
          body: %{"err_code" => 11_244, "message" => "unauthorized"}
        )
      )

      coordinator_state = %{state() | attempt_number: 2}

      assert {:noreply, updated} = Coordinator.handle_info(:refresh_token, coordinator_state)

      assert updated.attempt_number == 3
      assert is_reference(updated.refresh_ref)
      assert TokenStore.get(@bot) == "QQBot old-token"

      Process.cancel_timer(updated.refresh_ref)
    end

    test "rejects an empty access token" do
      stub(@token_path, token_response("", 7_200))

      assert {:noreply, updated} = Coordinator.handle_info(:refresh_token, state())
      assert updated.attempt_number == 1
      assert is_reference(updated.refresh_ref)
      assert TokenStore.get(@bot) == "QQBot old-token"

      Process.cancel_timer(updated.refresh_ref)
    end

    test "rejects an invalid expiry time" do
      stub(@token_path, token_response("new-token", 0))

      assert {:noreply, updated} = Coordinator.handle_info(:refresh_token, state())
      assert updated.attempt_number == 1
      assert is_reference(updated.refresh_ref)
      assert TokenStore.get(@bot) == "QQBot old-token"

      Process.cancel_timer(updated.refresh_ref)
    end

    test "retries on transport errors" do
      stub_with(@token_path, fn _request -> %RuntimeError{message: "connection refused"} end)

      assert {:noreply, updated} = Coordinator.handle_info(:refresh_token, state())
      assert updated.attempt_number == 1
      assert is_reference(updated.refresh_ref)
      assert TokenStore.get(@bot) == "QQBot old-token"

      Process.cancel_timer(updated.refresh_ref)
    end
  end

  describe "bootstrap" do
    test "retries when fetching the token fails" do
      stub(
        @token_path,
        Req.Response.new(
          status: 500,
          body: %{"code" => 50_000, "message" => "internal error"}
        )
      )

      assert {:noreply, updated} = Coordinator.handle_continue(:bootstrap, state())
      assert updated.attempt_number == 1
      assert updated.refresh_ref == nil
    end

    test "retries when the gateway response is invalid" do
      stub(@token_path, token_response("access-token", 7_200))

      stub(
        @gateway_path,
        Req.Response.new(
          status: 200,
          body: %{"url" => "wss://gateway.example.com", "session_start_limit" => %{}}
        )
      )

      assert {:noreply, updated} = Coordinator.handle_continue(:bootstrap, state())
      assert updated.attempt_number == 1
      assert updated.refresh_ref == nil
    end
  end
end
