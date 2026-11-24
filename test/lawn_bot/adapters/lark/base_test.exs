defmodule LawnBot.Adapters.Lark.BaseTest do
  use ExUnit.Case, async: false

  alias LawnBot.Adapters.Feishu
  alias LawnBot.Adapters.Lark
  alias LawnBot.Adapters.Lark.BaseCoordinator
  alias LawnBot.Adapters.Lark.BaseWorker

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

  test "both adapters expose their API base URL, accounts URL and label" do
    assert Lark.base_url() == "https://open.larksuite.com"
    assert Lark.accounts_url() == "https://accounts.larksuite.com"
    assert Lark.label() == "Lark"
    assert Feishu.base_url() == "https://open.feishu.cn"
    assert Feishu.accounts_url() == "https://accounts.feishu.cn"
    assert Feishu.label() == "Feishu"
  end

  test "validates options with a default handler and no explicit scopes" do
    assert {:ok, options} = Lark.validate_options(@options)
    assert options[:app_id] == "cli-app"
    assert options[:app_secret] == "secret"
    assert options[:name] == @bot
    assert options[:handler] == LawnBot.ExampleHandler
    assert options[:permissions] == []
    assert options[:connections] == 1
  end

  test "accepts custom token scopes" do
    permissions = ["im:message:send_as_bot", "im:message.urgent:app_send"]

    assert {:ok, options} = Lark.validate_options(Keyword.put(@options, :permissions, permissions))
    assert options[:permissions] == permissions

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :permissions, [:message_receive]))
  end

  test "accepts a custom connection count" do
    assert {:ok, options} = Lark.validate_options(Keyword.put(@options, :connections, 4))
    assert options[:connections] == 4

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :connections, 0))
  end

  test "rejects missing credentials or non-keyword options" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.delete(@options, :app_id))

    assert {:error, %NimbleOptions.ValidationError{}} =
             Lark.validate_options(Keyword.put(@options, :app_secret, ""))

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
             LawnBot.Adapters.Lark.Base.init(Keyword.put(opts, :adapter, Lark))

    assert length(children) == 4

    assert %{id: {LawnBot.AdapterRegistry, {LawnBot.Adapters.Lark.TaskSupervisor, {Lark, @bot}}}} =
             Enum.at(children, 0)

    assert %{id: {Finch.Pool.Supervisor, _pool_name}, start: {Finch.Pool.Supervisor, _, _}} =
             Enum.at(children, 1)

    assert_pool_size(Enum.at(children, 1), 16)

    assert %{
             id: {LawnBot.AdapterRegistry, {LawnBot.Adapters.Lark.WorkerSupervisor, {Lark, @bot}}}
           } = Enum.at(children, 2)

    assert %{id: BaseCoordinator, start: {BaseCoordinator, :start_link, [{Lark, @bot, 1}]}} =
             Enum.at(children, 3)

    assert :persistent_term.get({@bot, :app_id}) == "cli-app"
    assert :persistent_term.get({@bot, :app_secret}) == "secret"
    assert :persistent_term.get({@bot, :permissions}) == []
    assert is_function(:persistent_term.get(@bot), 1)
  end

  test "scales the Finch pool size with the connection count" do
    assert {:ok, opts} = Lark.validate_options(Keyword.put(@options, :connections, 3))

    assert {:ok, {_flags, children}} =
             LawnBot.Adapters.Lark.Base.init(Keyword.put(opts, :adapter, Lark))

    assert_pool_size(Enum.at(children, 1), 48)
  end

  test "the stored handler delegates to the configured module" do
    assert {:ok, opts} = Lark.validate_options(@options)
    assert {:ok, _spec} = LawnBot.Adapters.Lark.Base.init(Keyword.put(opts, :adapter, Lark))

    handler = :persistent_term.get(@bot)

    event = %LawnBot.Event{
      content: "hello",
      message_id: "om-message",
      session_id: "oc-chat",
      session_type: :group
    }

    assert %LawnBot.Response{action: :reply, text: "hello"} = handler.(event)
  end

  test "the worker child spec is keyed by adapter, bot name and connection" do
    worker = %BaseWorker{adapter: Lark, name: @bot, url: "wss://example.com/ws", service_id: 1}
    second = %{worker | index: 2}

    assert %{id: {BaseWorker, Lark, @bot, 1}, start: {BaseWorker, :start_link, [^worker]}} =
             BaseWorker.child_spec(worker)

    assert %{id: {BaseWorker, Lark, @bot, 2}, start: {BaseWorker, :start_link, [^second]}} =
             BaseWorker.child_spec(second)
  end

  defp assert_pool_size(pool_spec, expected_size) do
    assert %{
             start:
               {Finch.Pool.Supervisor, :start_link,
                [
                  {{:via, Registry,
                    {_registry, _pool_name, {_mod, _count, %{size: ^expected_size}}}},
                   {LawnBot.Finch, %Finch.Pool{}, %{size: ^expected_size}, false}}
                ]}
           } = pool_spec
  end
end
