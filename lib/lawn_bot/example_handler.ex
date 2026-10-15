defmodule LawnBot.ExampleHandler do
  @moduledoc false
  @behaviour LawnBot.Handler

  require Logger

  @impl true
  @spec handle_event(LawnBot.Event.t()) :: LawnBot.Reply.t()
  def handle_event(event) do
    # 在这里处理事件并返回回复
    Logger.info("Received event: #{inspect(event)}")
    %LawnBot.Reply{action: :ignore, event: nil}
  end
end
