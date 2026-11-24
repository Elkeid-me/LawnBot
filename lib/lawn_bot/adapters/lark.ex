defmodule LawnBot.Adapters.Lark do
  @moduledoc """
  The Lark (international) adapter.

  It uses the same long-connection protocol and OpenAPI shape as the Feishu
  adapter, with `https://open.larksuite.com` as the API base URL.
  """

  @behaviour LawnBot.Adapter

  alias LawnBot.Adapters.Lark.Base

  @base_url "https://open.larksuite.com"
  @accounts_url "https://accounts.larksuite.com"
  @label "Lark"

  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @spec accounts_url() :: String.t()
  def accounts_url, do: @accounts_url

  @spec label() :: String.t()
  def label, do: @label

  @impl LawnBot.Adapter
  def validate_options(opts), do: Base.validate_options(opts)

  @spec start_link(Base.options()) :: Supervisor.on_start()
  def start_link(opts), do: Base.start_link(opts, __MODULE__)

  @spec child_spec(Base.options()) :: Supervisor.child_spec()
  def child_spec(opts), do: Base.child_spec(opts, __MODULE__)
end
