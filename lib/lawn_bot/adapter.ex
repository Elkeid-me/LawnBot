defmodule LawnBot.Adapter do
  @moduledoc false
  @callback validate_options(opts :: keyword()) ::
              {:ok, keyword()} | {:error, NimbleOptions.ValidationError.t()}
end
