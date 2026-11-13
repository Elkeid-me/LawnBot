defmodule LawnBot.Utils do
  @moduledoc """
  Utility functions for LawnBot. For example, checking if a value is a non-empty string.
  """

  import Bitwise

  @max_backoff_ms 64_000

  @doc ~S"""
  Check if the given value is a non-empty string.

  ## Examples

      iex> LawnBot.Utils("Hello")
      {:ok, "Hello"}

      iex> LawnBot.Utils("")
      {:error, "must be a non-empty string"}
  """
  @spec check_empty_string(term()) :: {:ok, String.t()} | {:error, String.t()}
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
  @spec check_pos_int(term()) :: {:ok, pos_integer()} | {:error, String.t()}
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
  @spec check_non_neg_int(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def check_non_neg_int(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def check_non_neg_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} when int_value >= 0 -> {:ok, int_value}
      _ -> {:error, "must be a non-negative integer"}
    end
  end

  def check_non_neg_int(_value), do: {:error, "must be a non-negative integer"}

  @doc ~S"""
  Exponential backoff with jitter. The delay is calculated as `(2^attempt) * 500 + random(1, 1000)`, capped at 64 seconds.

  ## Examples

      iex> LawnBot.Utils.exp_backoff(1)
      1000..2000

      iex> LawnBot.Utils.exp_backoff(2)
      2000..3000

      iex> LawnBot.Utils.exp_backoff(3)
      4000..5000

      iex> LawnBot.Utils.exp_backoff(4)
      8000..9000

      iex> LawnBot.Utils.exp_backoff(5)
      16000..17000

      iex> LawnBot.Utils.exp_backoff(6)
      32000..33000

      iex> LawnBot.Utils.exp_backoff(7)
      64000

      iex> LawnBot.Utils.exp_backoff(8)
      64000
  """
  @spec exp_backoff(pos_integer()) :: pos_integer()
  def exp_backoff(attempt) when is_integer(attempt) and attempt > 0 do
    base_delay_ms = (1 <<< attempt) * 500
    jitter_ms = :rand.uniform(1000)
    min(base_delay_ms + jitter_ms, @max_backoff_ms)
  end

  def exp_backoff(_), do: @max_backoff_ms
end
