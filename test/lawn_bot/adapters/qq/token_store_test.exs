defmodule LawnBot.Adapters.QQ.TokenStoreTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.TokenStore

  test "returns the most recently stored token" do
    tid = TokenStore.new()

    assert TokenStore.put(tid, "QQBot first")
    assert TokenStore.get(tid) == "QQBot first"

    assert TokenStore.put(tid, "QQBot second")
    assert TokenStore.get(tid) == "QQBot second"
  end

  test "keeps the tables of different adapters isolated" do
    first = TokenStore.new()
    second = TokenStore.new()

    TokenStore.put(first, "QQBot first")
    TokenStore.put(second, "QQBot second")

    assert TokenStore.get(first) == "QQBot first"
    assert TokenStore.get(second) == "QQBot second"
  end
end
