defmodule LawnBot.TokenStore do
  @moduledoc """
  Stores the access token in an ETS table for fast concurrent read access.

  All adapters share the same token store table, distinguished by the adapter name.

  The table is created and owned by the LawnBot root supervision tree, and its lifecycle
  covers all users, so it is assumed that the token always exists.
  """

  alias :ets, as: ETS

  @table_name :auth_tokens

  @type adapter() :: atom()

  @doc """
  Creates a new ETS table for storing the access token.

  The table is created and owned by the LawnBot root supervision tree, and its lifecycle covers all users.

  Always returns the new ETS table.
  """
  @spec new() :: ETS.table()
  def new, do: ETS.new(@table_name, [:set, :public, :named_table, read_concurrency: true])

  @doc """
  Stores the access token for the given adapter name.
  """
  @spec put(adapter(), String.t()) :: true
  def put(name, access_token), do: ETS.insert(@table_name, {name, access_token})

  @doc """
  Retrieves the access token for the given adapter name.
  """
  @spec get(adapter()) :: String.t()
  def get(name), do: ETS.lookup_element(@table_name, name, 2)
end
