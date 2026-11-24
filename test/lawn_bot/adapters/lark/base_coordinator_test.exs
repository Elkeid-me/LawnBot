defmodule LawnBot.Adapters.Lark.BaseCoordinatorTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.Feishu
  alias LawnBot.Adapters.Lark.BaseCoordinator
  alias LawnBot.Adapters.Lark.Utils
  alias LawnBot.TestReqStub
  alias LawnBot.TokenStore

  @moduletag capture_log: true

  @bot :LarkCoordinatorTestBot
  @token_path "/oauth/v3/token"
  @endpoint_path "/callback/ws/endpoint"

  setup do
    ensure_token_store()
    TokenStore.put(@bot, "t-old-token")

    :persistent_term.put({@bot, :app_id}, "cli-app")
    :persistent_term.put({@bot, :app_secret}, "secret")

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    on_exit(fn ->
      :persistent_term.erase({@bot, :app_id})
      :persistent_term.erase({@bot, :app_secret})

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

  defp state do
    %{adapter: Feishu, name: @bot, connections: 1, attempt_number: 0, refresh_ref: nil}
  end

  defp stub(path, body) do
    Process.put({TestReqStub, path}, fn _request ->
      Req.Response.new(status: 200, body: body)
    end)
  end

  test "initializes with an asynchronous bootstrap continuation" do
    expected = state()

    assert {:ok, ^expected, {:continue, :bootstrap}} = BaseCoordinator.init({Feishu, @bot})

    assert {:ok, %{connections: 3}, {:continue, :bootstrap}} =
             BaseCoordinator.init({Feishu, @bot, 3})
  end

  test "builds its registry name per adapter and bot" do
    assert {:via, Registry, {LawnBot.AdapterRegistry, {BaseCoordinator, {Feishu, @bot}}}} =
             BaseCoordinator.via_tuple(Feishu, @bot)
  end

  test "starts one worker per configured connection" do
    start_registry()

    start_supervised!(
      {DynamicSupervisor,
       strategy: :one_for_one, name: Utils.worker_supervisor_via_tuple(Feishu, @bot)}
    )

    endpoint_requests = :counters.new(1, [])

    Process.put({TestReqStub, @token_path}, fn _request ->
      Req.Response.new(
        status: 200,
        body: %{"code" => 0, "access_token" => "t-token", "expires_in" => 7200}
      )
    end)

    Process.put({TestReqStub, @endpoint_path}, fn _request ->
      :counters.add(endpoint_requests, 1, 1)

      Req.Response.new(
        status: 200,
        body: %{
          "code" => 0,
          "data" => %{
            "URL" => "wss://127.0.0.1:1/ws?service_id=42",
            "ClientConfig" => %{"PingInterval" => 120}
          }
        }
      )
    end)

    assert {:noreply, updated, :hibernate} =
             BaseCoordinator.handle_continue(:bootstrap, %{state() | connections: 3})

    assert :counters.get(endpoint_requests, 1) == 3
    assert TokenStore.get(@bot) == "t-token"

    assert %{active: 3} =
             DynamicSupervisor.count_children(Utils.worker_supervisor_via_tuple(Feishu, @bot))

    Process.cancel_timer(updated.refresh_ref)
  end

  test "refreshes and stores the tenant access token" do
    stub(@token_path, %{"code" => 0, "access_token" => "t-new-token", "expires_in" => 7200})

    assert {:noreply, updated} = BaseCoordinator.handle_info(:refresh_token, state())
    assert TokenStore.get(@bot) == "t-new-token"
    assert updated.attempt_number == 0
    assert is_reference(updated.refresh_ref)

    Process.cancel_timer(updated.refresh_ref)
  end

  test "schedules the refresh before the token expires" do
    stub(@token_path, %{"code" => 0, "access_token" => "t-new-token", "expires_in" => 60})

    assert {:noreply, updated} = BaseCoordinator.handle_info(:refresh_token, state())

    remaining = Process.read_timer(updated.refresh_ref)
    assert remaining > 0 and remaining <= 1_000

    Process.cancel_timer(updated.refresh_ref)
  end

  test "retries token refresh with exponential backoff" do
    stub(@token_path, %{"code" => 10_003, "msg" => "invalid app_secret"})
    coordinator_state = %{state() | attempt_number: 2}

    assert {:noreply, updated} =
             BaseCoordinator.handle_info(:refresh_token, coordinator_state)

    assert updated.attempt_number == 3
    assert is_reference(updated.refresh_ref)
    assert TokenStore.get(@bot) == "t-old-token"

    Process.cancel_timer(updated.refresh_ref)
  end

  test "retries bootstrap when the token request fails" do
    stub(@token_path, %{"code" => 10_003, "msg" => "invalid app_secret"})

    assert {:noreply, updated} =
             BaseCoordinator.handle_continue(:bootstrap, state())

    assert updated.attempt_number == 1
    assert updated.refresh_ref == nil
  end

  test "retries bootstrap when the endpoint request fails" do
    stub(@token_path, %{"code" => 0, "access_token" => "t-token", "expires_in" => 7200})
    stub(@endpoint_path, %{"code" => 1, "msg" => "system busy"})

    assert {:noreply, updated} =
             BaseCoordinator.handle_continue(:bootstrap, state())

    assert updated.attempt_number == 1
    assert updated.refresh_ref == nil
  end

  test "ignores unrelated messages" do
    coordinator_state = state()

    assert {:noreply, ^coordinator_state} =
             BaseCoordinator.handle_info(:unrelated, coordinator_state)
  end
end
