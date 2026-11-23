defmodule LawnBot.Adapters.QQTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ

  @moduletag capture_log: true

  @valid_options [app_id: "app", client_secret: "secret", name: :TestBot]

  describe "validate_options/1" do
    test "fills in the documented defaults" do
      assert {:ok, options} = QQ.validate_options(@valid_options)

      assert options[:app_id] == "app"
      assert options[:client_secret] == "secret"
      assert options[:name] == :TestBot
      assert options[:handler] == LawnBot.ExampleHandler
      assert options[:os] == to_string(elem(:os.type(), 1))
      assert options[:browser] == "LawnBot"
      assert options[:device] == "LawnBot"
      assert options[:permissions] == [:guilds, :guild_members, :public_guild_messages]
      assert options[:shards] == 1
    end

    test "keeps explicitly configured values" do
      options =
        Keyword.merge(@valid_options,
          handler: LawnBot.ExampleHandler,
          os: "linux",
          browser: "browser",
          device: "device",
          permissions: [:group_and_c2c, :interaction],
          shards: 4
        )

      assert {:ok, validated} = QQ.validate_options(options)

      assert validated[:os] == "linux"
      assert validated[:browser] == "browser"
      assert validated[:device] == "device"
      assert validated[:permissions] == [:group_and_c2c, :interaction]
      assert validated[:shards] == 4
    end

    test "requires app_id, client_secret and name" do
      for key <- [:app_id, :client_secret, :name] do
        assert {:error, %NimbleOptions.ValidationError{}} =
                 QQ.validate_options(Keyword.delete(@valid_options, key))
      end
    end

    test "rejects empty credentials" do
      assert {:error, %NimbleOptions.ValidationError{message: message}} =
               QQ.validate_options(Keyword.put(@valid_options, :app_id, ""))

      assert message =~ "non-empty"

      assert {:error, %NimbleOptions.ValidationError{message: message}} =
               QQ.validate_options(Keyword.put(@valid_options, :client_secret, ""))

      assert message =~ "non-empty"
    end

    test "rejects invalid types" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               QQ.validate_options(Keyword.put(@valid_options, :name, "TestBot"))

      assert {:error, %NimbleOptions.ValidationError{}} =
               QQ.validate_options(Keyword.put(@valid_options, :shards, 0))

      assert {:error, %NimbleOptions.ValidationError{}} =
               QQ.validate_options(Keyword.put(@valid_options, :permissions, [:unknown]))
    end

    test "rejects non-keyword options" do
      assert {:error, %NimbleOptions.ValidationError{message: "Expected a keyword list"}} =
               QQ.validate_options(%{})

      assert {:error, %NimbleOptions.ValidationError{message: "Expected a keyword list"}} =
               QQ.validate_options([:app_id])
    end
  end

  test "builds a child spec keyed by adapter name" do
    options = @valid_options

    assert %{id: {QQ, :TestBot}, start: {QQ, :start_link, [^options]}} = QQ.child_spec(options)
  end

  describe "init/1" do
    @init_options [
      app_id: "app",
      client_secret: "secret",
      name: :QQInitTestBot,
      handler: LawnBot.ExampleHandler,
      permissions: [:guilds, :group_and_c2c],
      shards: 2
    ]

    setup do
      if Process.whereis(LawnBot.Finch) == nil do
        start_supervised!({Finch, name: LawnBot.Finch})
      end

      on_exit(fn ->
        for key <- [:app_id, :client_secret, :shards, :os, :browser, :device, :permissions] do
          :persistent_term.erase({:QQInitTestBot, key})
        end

        :persistent_term.erase(:QQInitTestBot)
      end)

      :ok
    end

    defp init do
      {:ok, options} = QQ.validate_options(@init_options)
      QQ.init(options)
    end

    test "stores the adapter configuration in persistent_term" do
      assert {:ok, {_flags, _children}} = init()

      assert :persistent_term.get({:QQInitTestBot, :app_id}) == "app"
      assert :persistent_term.get({:QQInitTestBot, :client_secret}) == "secret"
      assert :persistent_term.get({:QQInitTestBot, :shards}) == 2
      assert :persistent_term.get({:QQInitTestBot, :os}) == to_string(elem(:os.type(), 1))
      assert :persistent_term.get({:QQInitTestBot, :browser}) == "LawnBot"
      assert :persistent_term.get({:QQInitTestBot, :device}) == "LawnBot"

      # :guilds | :group_and_c2c
      assert :persistent_term.get({:QQInitTestBot, :permissions}) == 33_554_433
    end

    test "registers a handler function that delegates to the handler module" do
      assert {:ok, {_flags, _children}} = init()

      handler = :persistent_term.get(:QQInitTestBot)
      event = %LawnBot.Event{content: "hello", session_id: "session", message_id: "message"}

      assert %LawnBot.Response{action: :reply, text: "hello"} = handler.(event)
    end

    test "starts a rest-for-one supervisor with shard, task and coordinator children" do
      assert {:ok, {%{strategy: :rest_for_one, intensity: 3, period: 30}, children}} =
               init()

      assert [task_supervisor, finch_pool, shard_supervisor, coordinator] = children

      assert {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.TaskSupervisor, :QQInitTestBot}} =
               task_supervisor.id

      assert {LawnBot.AdapterRegistry, {LawnBot.Adapters.QQ.ShardSupervisor, :QQInitTestBot}} =
               shard_supervisor.id

      assert {Finch.Pool.Supervisor, {_scheme, "api.bot.qq.com", 443, :QQInitTestBot}} =
               finch_pool.id

      assert coordinator.id == LawnBot.Adapters.QQ.Coordinator
    end
  end
end
