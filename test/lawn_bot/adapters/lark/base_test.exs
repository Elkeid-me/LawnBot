defmodule LawnBot.Adapters.Lark.BaseTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.Feishu
  alias LawnBot.Adapters.Lark
  alias LawnBot.Adapters.Lark.Coordinator
  alias LawnBot.Adapters.Lark.Worker
  alias LawnBot.TestReqStub
  alias LawnBot.TokenStore

  @moduletag capture_log: true

  @bot :LarkBaseTestBot
  @options [app_id: "cli-app", app_secret: "secret", name: @bot]

  setup do
    if Process.whereis(LawnBot.Finch) == nil do
      start_supervised!({Finch, name: LawnBot.Finch})
    end

    on_exit(fn ->
      :persistent_term.erase(@bot)
      :persistent_term.erase({@bot, :app_id})
      :persistent_term.erase({@bot, :app_secret})
      :persistent_term.erase({@bot, :permissions})
    end)

    :ok
  end

  test "both adapters expose their API URLs and label" do
    assert Lark.base_url() == "https://open.larksuite.com"
    assert Lark.accounts_url() == "https://accounts.larksuite.com"
    assert Lark.token_url() == "https://accounts.larksuite.com/oauth/v3/token"
    assert Lark.ws_endpoint_url() == "https://open.larksuite.com/callback/ws/endpoint"
    assert Lark.messages_url() == "https://open.larksuite.com/open-apis/im/v1/messages"
    assert Lark.upload_image_url() == "https://open.larksuite.com/open-apis/im/v1/images"
    assert Lark.upload_file_url() == "https://open.larksuite.com/open-apis/im/v1/files"
    assert Lark.reply_message_url("om-1") =~ "/open-apis/im/v1/messages/om-1/reply"
    assert Lark.message_resource_url("om-1", "key", "image") =~ "?type=image"
    assert Lark.label() == "Lark"
    assert Lark.coordinator_module() == Coordinator
    assert Lark.worker_module() == Worker

    assert Feishu.base_url() == "https://open.feishu.cn"
    assert Feishu.accounts_url() == "https://accounts.feishu.cn"
    assert Feishu.token_url() == "https://accounts.feishu.cn/oauth/v3/token"
    assert Feishu.ws_endpoint_url() == "https://open.feishu.cn/callback/ws/endpoint"
    assert Feishu.messages_url() == "https://open.feishu.cn/open-apis/im/v1/messages"
    assert Feishu.label() == "Feishu"
    assert Feishu.coordinator_module() == Feishu.Coordinator
    assert Feishu.worker_module() == Feishu.Worker
  end

  test "validates options with default handler and permissions" do
    assert {:ok, options} = Lark.validate_options(@options)
    assert options[:app_id] == "cli-app"
    assert options[:app_secret] == "secret"
    assert options[:name] == @bot
    assert options[:handler] == LawnBot.ExampleHandler
    assert options[:permissions] == ["im:message", "im:resource"]
    assert options[:workers] == 1
  end

  test "accepts custom token scopes" do
    permissions = ["im:message:send_as_bot", "im:message.urgent:app_send"]

    assert {:ok, options} = Lark.validate_options(Keyword.put(@options, :permissions, permissions))
    assert options[:permissions] == permissions

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :permissions, [:message_receive]))
  end

  test "accepts a custom worker count" do
    assert {:ok, options} = Lark.validate_options(Keyword.put(@options, :workers, 4))
    assert options[:workers] == 4

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :workers, 0))
  end

  test "rejects missing credentials or non-keyword options" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.delete(@options, :app_id))

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :app_secret, ""))

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :app_id, 12_345))

    assert {:error, %NimbleOptions.ValidationError{message: "Expected a keyword list"}} =
             Feishu.validate_options(%{})
  end

  test "builds child specs per adapter and bot name" do
    assert %{id: {Lark, @bot}, start: {Lark, :start_link, [@options]}} =
             Lark.child_spec(@options)

    assert %{id: {Feishu, @bot}, start: {Feishu, :start_link, [@options]}} =
             Feishu.child_spec(@options)
  end

  test "stores configuration and builds the supervision tree" do
    assert {:ok, opts} = Lark.validate_options(@options)

    assert {:ok, {%{strategy: :rest_for_one, intensity: 3, period: 30}, children}} =
             Lark.init(opts)

    assert length(children) == 4

    assert %{id: {LawnBot.AdapterRegistry, {Worker, {:task_supervisor, @bot}}}} =
             Enum.at(children, 0)

    assert %{id: {Finch.Pool.Supervisor, _pool_name}, start: {Finch.Pool.Supervisor, _, _}} =
             Enum.at(children, 1)

    assert_pool_size(Enum.at(children, 1), 16)

    assert %{id: {LawnBot.AdapterRegistry, {Worker, {:worker_supervisor, @bot}}}} =
             Enum.at(children, 2)

    assert %{id: Coordinator, start: {Coordinator, :start_link, [{@bot, 1}]}} =
             Enum.at(children, 3)

    assert :persistent_term.get({@bot, :app_id}) == "cli-app"
    assert :persistent_term.get({@bot, :app_secret}) == "secret"
    assert :persistent_term.get({@bot, :permissions}) == ["im:message", "im:resource"]
    assert is_function(:persistent_term.get(@bot), 1)
  end

  test "scales the Finch pool size with the worker count" do
    assert {:ok, opts} = Lark.validate_options(Keyword.put(@options, :workers, 3))

    assert {:ok, {_flags, children}} =
             Lark.init(opts)

    assert_pool_size(Enum.at(children, 1), 48)
  end

  test "starts the supervision tree and bootstraps workers" do
    assert {:ok, opts} = Lark.validate_options(@options)

    start_registry()
    ensure_token_store()

    previous_req_options = Elixir.Application.fetch_env(:req, :default_options)
    Elixir.Application.put_env(:req, :default_options, adapter: TestReqStub)

    on_exit(fn ->
      :persistent_term.erase({TestReqStub, "/oauth/v3/token"})
      :persistent_term.erase({TestReqStub, "/callback/ws/endpoint"})

      case previous_req_options do
        {:ok, options} -> Elixir.Application.put_env(:req, :default_options, options)
        :error -> Elixir.Application.delete_env(:req, :default_options)
      end
    end)

    :persistent_term.put({TestReqStub, "/oauth/v3/token"}, fn _request ->
      Req.Response.new(
        status: 200,
        body: %{"code" => 0, "access_token" => "t-token", "expires_in" => 7200}
      )
    end)

    :persistent_term.put({TestReqStub, "/callback/ws/endpoint"}, fn _request ->
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

    assert {:ok, _pid} = start_supervised({Feishu, opts})

    assert [_] = Registry.lookup(LawnBot.AdapterRegistry, {Feishu, @bot})
    assert [_] = Registry.lookup(LawnBot.AdapterRegistry, {Feishu.Coordinator, @bot})

    assert [_] =
             Registry.lookup(LawnBot.AdapterRegistry, {Feishu.Worker, {:task_supervisor, @bot}})

    assert [_] =
             Registry.lookup(LawnBot.AdapterRegistry, {Feishu.Worker, {:worker_supervisor, @bot}})

    wait_until(fn -> Registry.lookup(LawnBot.AdapterRegistry, {Feishu.Worker, {@bot, 1}}) != [] end)
    assert TokenStore.get(@bot) == "t-token"
  end

  test "the stored handler delegates to the configured module" do
    assert {:ok, opts} = Lark.validate_options(@options)
    assert {:ok, _spec} = Lark.init(opts)

    handler = :persistent_term.get(@bot)

    event = %LawnBot.Event{
      content: "hello",
      message_id: "om-message",
      session_id: "oc-chat",
      session_type: :group
    }

    assert %LawnBot.Response{action: :reply, text: "hello"} = handler.(event)
  end

  test "the worker child spec is keyed by worker module, bot name and index" do
    worker = %Worker{name: @bot, url: "wss://example.com/ws", service_id: 1}
    second = %{worker | index: 2}

    assert %{id: {Worker, @bot, 1}, start: {Worker, :start_link, [^worker]}} =
             Worker.child_spec(worker)

    assert %{id: {Worker, @bot, 2}, start: {Worker, :start_link, [^second]}} =
             Worker.child_spec(second)
  end

  defp assert_pool_size(pool_spec, expected_size) do
    assert %{
             start:
               {Finch.Pool.Supervisor, :start_link,
                [
                  {{:via, Registry, {_registry, _pool_name, {_mod, _count}}},
                   {LawnBot.Finch, %Finch.Pool{}, %{size: ^expected_size}, false}}
                ]}
           } = pool_spec
  end

  defp start_registry do
    if Process.whereis(LawnBot.AdapterRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: LawnBot.AdapterRegistry})
    end

    :ok
  end

  defp ensure_token_store do
    case :ets.whereis(:auth_tokens) do
      :undefined -> TokenStore.new()
      _table -> :ok
    end
  end

  defp wait_until(fun, timeout \\ 2_000)
  defp wait_until(_fun, timeout) when timeout <= 0, do: flunk("condition was not met in time")

  defp wait_until(fun, timeout) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, timeout - 20)
    end
  end
end
