defmodule LawnBot.Adapters.QQ.Utils do
  @moduledoc false
  @type api_error() ::
          {:error, {:qq_api, integer(), integer()}}
          | {:error, {:unexpected_response, integer(), term()}}
          | {:error, String.t()}

  @spec check_api_error({:ok, Req.Response.t()} | {:error, Exception.t()}) :: api_error()
  def check_api_error(response) do
    case response do
      {:ok, %Req.Response{status: http_status, body: %{"err_code" => api_err_code}}} ->
        {:error, {:qq_api, http_status, api_err_code}}

      {:ok, %Req.Response{status: http_status, body: response}} ->
        {:error, {:unexpected_response, http_status, response}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end
end
