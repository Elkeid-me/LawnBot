defmodule LawnBot.Handler do
  @moduledoc "LawnBot.Handler defines the behavior for handling events in LawnBot adapters."
  @callback handle_event(event :: LawnBot.Event.t()) :: LawnBot.Response.t()
end
