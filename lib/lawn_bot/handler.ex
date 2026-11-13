defmodule LawnBot.Handler do
  @moduledoc false
  @callback handle_event(event :: LawnBot.Event.t()) :: LawnBot.Response.t()
end
