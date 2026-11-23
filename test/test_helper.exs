defmodule LawnBot.TestReqStub do
  @moduledoc false

  # A Req adapter used in tests. Stubs can be registered in the process dictionary
  # (for synchronous calls) or in persistent_term (for calls made from tasks).

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    path = request.url.path
    stub = :persistent_term.get({__MODULE__, path}, nil) || Process.get({__MODULE__, path})

    case stub do
      nil ->
        {request, %RuntimeError{message: "unexpected request to #{path}"}}

      fun when is_function(fun, 1) ->
        case fun.(request) do
          %Req.Response{} = response -> {request, response}
          exception -> {request, exception}
        end
    end
  end
end

ExUnit.start()
