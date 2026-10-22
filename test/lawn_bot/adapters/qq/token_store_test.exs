defmodule LawnBot.Adapters.QQ.TokenStoreTest do
  use ExUnit.Case, async: true

  alias LawnBot.Adapters.QQ.TokenStore

  test "creates many tables for different adapters" do
    tid_1 = TokenStore.new()
    tid_2 = TokenStore.new()

    assert tid_1 !== tid_2

    assert TokenStore.put(tid_1, "QQBot first")
    assert TokenStore.put(tid_2, "QQBot second")

    assert TokenStore.get(tid_1) == "QQBot first"
    assert TokenStore.get(tid_2) == "QQBot second"
  end

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
