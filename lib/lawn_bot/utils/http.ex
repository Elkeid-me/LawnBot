defmodule LawnBot.Utils.HTTP do
  @moduledoc """
  供平台适配器使用的 HTTPS JSON 请求客户端。
  """

  @doc """
  发送 HTTP 请求并返回 JSON 响应。
  """
  @spec request(method, url, head) :: {:ok, map()} | {:error, term()}
        when method: :head | :get | :put | :patch | :post | :trace | :options | :delete,
             url: String.t(),
             head: [{String.t(), String.t()}]
  def request(method, url, headers \\ []) do
    case :httpc.request(
           method,
           {String.to_charlist(url), headers_to_charlist(headers)},
           [timeout: 10_000, connect_timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        decode(response_body)

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_status, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  发送 HTTP 请求并返回 JSON 响应，支持请求体为 JSON。
  """
  @spec json_request(method, url, head, map()) ::
          {:ok, map()} | {:error, term()}
        when method: :head | :get | :put | :patch | :post | :trace | :options | :delete,
             url: String.t(),
             head: [{String.t(), String.t()}]
  def json_request(method, url, headers, payload) do
    case :httpc.request(
           method,
           {String.to_charlist(url), headers_to_charlist(headers), ~c"application/json",
            Jason.encode!(payload)},
           [timeout: 10_000, connect_timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        decode(response_body)

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_status, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, payload} -> {:error, {:invalid_json_shape, payload}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp headers_to_charlist(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end
end
