defmodule LawnBot.Utils do
  @moduledoc false

  @doc ~S"""
  Check if the given value is a non-empty string.

  ## Examples

      iex> LawnBot.Utils("Hello")
      {:ok, "Hello"}

      iex> LawnBot.Utils("")
      {:error, "must be a non-empty string"}
  """
  @spec check_empty_string(any()) :: {:ok, String.t()} | {:error, String.t()}
  def check_empty_string(value) when is_binary(value) and value != "", do: {:ok, value}
  def check_empty_string(_value), do: {:error, "must be a non-empty string"}

  @doc ~S"""
  Check if the given value is a positive integer. String is allowed, and will be converted to integer.

  ## Examples

      iex> LawnBot.Utils.check_pos_int(5)
      {:ok, 5}

      iex> LawnBot.Utils.check_pos_int("10")
      {:ok, 10}

      iex> LawnBot.Utils.check_non_neg_int(0)
      {:ok, "must be a positive integer"}

      iex> LawnBot.Utils.check_pos_int(-1)
      {:error, "must be a positive integer"}

      iex> LawnBot.Utils.check_pos_int("Hello")
      {:error, "must be a positive integer"}


      iex> LawnBot.Utils.check_pos_int("5Hello")
      {:error, "must be a positive integer"}
  """
  @spec check_pos_int(any()) :: {:ok, pos_integer()} | {:error, String.t()}
  def check_pos_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  def check_pos_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} when int_value > 0 -> {:ok, int_value}
      _ -> {:error, "must be a positive integer"}
    end
  end

  def check_pos_int(_value), do: {:error, "must be a positive integer"}

  @doc ~S"""
  Check if the given value is a non-negative integer. String is allowed, and will be converted to integer.

  ## Examples

      iex> LawnBot.Utils.check_non_neg_int(0)
      {:ok, 0}

      iex> LawnBot.Utils.check_non_neg_int(5)
      {:ok, 5}

      iex> LawnBot.Utils.check_non_neg_int("10")
      {:ok, 10}

      iex> LawnBot.Utils.check_non_neg_int(-1)
      {:error, "must be a non-negative integer"}

      iex> LawnBot.Utils.check_non_neg_int("Hello")
      {:error, "must be a non-negative integer"}

      iex> LawnBot.Utils.check_non_neg_int("5Hello")
      {:error, "must be a non-negative integer"}
  """
  @spec check_non_neg_int(any()) :: {:ok, pos_integer()} | {:error, String.t()}
  def check_non_neg_int(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def check_non_neg_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} when int_value >= 0 -> {:ok, int_value}
      _ -> {:error, "must be a non-negative integer"}
    end
  end

  def check_non_neg_int(_value), do: {:error, "must be a non-negative integer"}
end
