defmodule LawnBot.ResponseTest do
  use ExUnit.Case, async: true

  alias LawnBot.Response

  test "response fields default to nil" do
    assert %Response{
             action: nil,
             session_id: nil,
             reply_message_id: nil,
             session_type: nil,
             text: nil,
             attachment: nil,
             reference_message_id: nil
           } = %Response{}
  end
end
