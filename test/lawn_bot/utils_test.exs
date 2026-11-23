defmodule LawnBot.UtilsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias LawnBot.Utils

  describe "check_empty_string/1" do
    test "accepts a non-empty string" do
      assert Utils.check_empty_string("Hello") == {:ok, "Hello"}
      assert Utils.check_empty_string(" ") == {:ok, " "}
    end

    test "rejects an empty string" do
      assert Utils.check_empty_string("") == {:error, "must be a non-empty string"}
    end

    test "rejects non-string values" do
      assert Utils.check_empty_string(nil) == {:error, "must be a non-empty string"}
      assert Utils.check_empty_string(1) == {:error, "must be a non-empty string"}
      assert Utils.check_empty_string([:a]) == {:error, "must be a non-empty string"}
    end
  end

  describe "check_pos_int/1" do
    test "accepts positive integers" do
      assert Utils.check_pos_int(5) == {:ok, 5}
      assert Utils.check_pos_int(999_999) == {:ok, 999_999}
    end

    test "parses positive integer strings" do
      assert Utils.check_pos_int("10") == {:ok, 10}
      assert Utils.check_pos_int("0010") == {:ok, 10}
    end

    test "rejects zero, negative and malformed values" do
      assert Utils.check_pos_int(0) == {:error, "must be a positive integer"}
      assert Utils.check_pos_int(-1) == {:error, "must be a positive integer"}
      assert Utils.check_pos_int("0") == {:error, "must be a positive integer"}
      assert Utils.check_pos_int("-5") == {:error, "must be a positive integer"}
      assert Utils.check_pos_int("5Hello") == {:error, "must be a positive integer"}
      assert Utils.check_pos_int("Hello") == {:error, "must be a positive integer"}
      assert Utils.check_pos_int("") == {:error, "must be a positive integer"}
      assert Utils.check_pos_int(nil) == {:error, "must be a positive integer"}
      assert Utils.check_pos_int(1.5) == {:error, "must be a positive integer"}
    end
  end

  describe "check_non_neg_int/1" do
    test "accepts zero and positive integers" do
      assert Utils.check_non_neg_int(0) == {:ok, 0}
      assert Utils.check_non_neg_int(5) == {:ok, 5}
    end

    test "parses non-negative integer strings" do
      assert Utils.check_non_neg_int("0") == {:ok, 0}
      assert Utils.check_non_neg_int("10") == {:ok, 10}
    end

    test "rejects negative and malformed values" do
      assert Utils.check_non_neg_int(-1) == {:error, "must be a non-negative integer"}
      assert Utils.check_non_neg_int("-1") == {:error, "must be a non-negative integer"}
      assert Utils.check_non_neg_int("5Hello") == {:error, "must be a non-negative integer"}
      assert Utils.check_non_neg_int("Hello") == {:error, "must be a non-negative integer"}
      assert Utils.check_non_neg_int(nil) == {:error, "must be a non-negative integer"}
      assert Utils.check_non_neg_int(1.5) == {:error, "must be a non-negative integer"}
    end
  end

  describe "exp_backoff/1" do
    test "returns an exponentially growing delay with jitter" do
      for attempt <- 1..6 do
        base_delay = (1 <<< attempt) * 500

        assert Utils.exp_backoff(attempt) in (base_delay + 1)..(base_delay + 1_000)
      end
    end

    test "caps the delay at 64 seconds" do
      assert Utils.exp_backoff(7) == 64_000
      assert Utils.exp_backoff(8) == 64_000
      assert Utils.exp_backoff(100) == 64_000
    end

    test "falls back to the maximum delay for invalid attempts" do
      assert Utils.exp_backoff(0) == 64_000
      assert Utils.exp_backoff(-1) == 64_000
      assert Utils.exp_backoff("3") == 64_000
      assert Utils.exp_backoff(nil) == 64_000
    end
  end
end
