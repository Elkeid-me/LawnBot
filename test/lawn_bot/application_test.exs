defmodule LawnBot.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    previous_gateways = Elixir.Application.get_env(:lawn_bot, :gateways)
    Elixir.Application.delete_env(:lawn_bot, :gateways)

    on_exit(fn ->
      if previous_gateways do
        Elixir.Application.put_env(:lawn_bot, :gateways, previous_gateways)
      else
        Elixir.Application.delete_env(:lawn_bot, :gateways)
      end
    end)
  end

  test "refuses to start without gateways" do
    assert {:error, :no_gateways_configured} = LawnBot.Application.start(:normal, [])
  end
end
