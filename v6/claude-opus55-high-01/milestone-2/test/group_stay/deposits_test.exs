defmodule GroupStay.DepositsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Deposits

  describe "percentage_cents/2" do
    test "rounds to the nearest cent" do
      assert Deposits.percentage_cents(10_001, 20) == 2000
      assert Deposits.percentage_cents(10_004, 20) == 2001
    end

    test "rounds an exact half-cent upward" do
      assert Deposits.percentage_cents(1, 50) == 1
      assert Deposits.percentage_cents(5, 10) == 1
      assert Deposits.percentage_cents(25, 10) == 3
      assert Deposits.percentage_cents(15, 10) == 2
    end

    test "rounds 20% of room amounts to the nearest cent" do
      # 20% of 12_346 is 2469.2; 20% of 12_348 is 2469.6
      assert Deposits.percentage_cents(12_345, 20) == 2469
      assert Deposits.percentage_cents(12_346, 20) == 2469
      assert Deposits.percentage_cents(12_348, 20) == 2470
      assert Deposits.percentage_cents(0, 20) == 0
    end
  end

  test "flexible rooms require 20% and advance purchase rooms the full lodging amount" do
    assert Deposits.room_deposit_cents("flexible", 45_000) == 9000
    assert Deposits.room_deposit_cents("advance_purchase", 45_000) == 45_000
  end
end
