defmodule LawnBot.Adapters.QQ.Utils do
  @moduledoc false
  @type api_call_error() ::
          {:error, {:qq_api, integer(), integer(), String.t()}}
          | {:error, {:unexpected_response, integer(), term()}}
          | {:error, String.t()}

  @spec check_api_call_error({:ok, Req.Response.t()} | {:error, Exception.t()}) :: api_call_error()
  def check_api_call_error(response) do
    case response do
      {:ok, %Req.Response{status: http_status, body: %{"err_code" => code, "message" => message}}} ->
        {:error, {:qq_api, http_status, code, message}}

      {:ok, %Req.Response{status: http_status, body: %{"code" => code, "message" => message}}} ->
        {:error, {:qq_api, http_status, code, message}}

      {:ok, %Req.Response{status: http_status, body: response}} ->
        {:error, {:unexpected_response, http_status, response}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end
end
