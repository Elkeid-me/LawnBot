defmodule LawnBot.TokenStoreTest do
  use ExUnit.Case, async: false

  alias LawnBot.TokenStore

  setup do
    if :ets.whereis(:auth_tokens) != :undefined do
      :ets.delete(:auth_tokens)
    end

    on_exit(fn ->
      if :ets.whereis(:auth_tokens) != :undefined do
        :ets.delete(:auth_tokens)
      end
    end)
  end

  test "creates a public, named ETS table" do
    assert TokenStore.new() == :auth_tokens
    assert :ets.info(:auth_tokens, :type) == :set
    assert :ets.info(:auth_tokens, :protection) == :public
    assert :ets.info(:auth_tokens, :named_table)
  end

  test "stores and retrieves a token by adapter name" do
    TokenStore.new()

    assert TokenStore.put(:FirstBot, "QQBot first")
    assert TokenStore.get(:FirstBot) == "QQBot first"
  end

  test "overwrites the token of an adapter" do
    TokenStore.new()

    assert TokenStore.put(:FirstBot, "QQBot first")
    assert TokenStore.get(:FirstBot) == "QQBot first"

    assert TokenStore.put(:FirstBot, "QQBot second")
    assert TokenStore.get(:FirstBot) == "QQBot second"
  end

  test "keeps the tokens of different adapters isolated" do
    TokenStore.new()

    TokenStore.put(:FirstBot, "QQBot first")
    TokenStore.put(:SecondBot, "QQBot second")

    assert TokenStore.get(:FirstBot) == "QQBot first"
    assert TokenStore.get(:SecondBot) == "QQBot second"
  end

  test "raises when the adapter has no token" do
    TokenStore.new()

    assert_raise ArgumentError, fn -> TokenStore.get(:MissingBot) end
  end
end
