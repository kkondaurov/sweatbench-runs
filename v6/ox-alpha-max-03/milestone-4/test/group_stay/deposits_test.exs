defmodule GroupStay.DepositsTest do
  use ExUnit.Case, async: true

  import GroupStay.Deposits, only: [percentage_half_up: 2]

  describe "percentage_half_up/2" do
    test "rounds exact values without change" do
      assert percentage_half_up(45_000, 20) == 9_000
      assert percentage_half_up(52_500, 20) == 10_500
      assert percentage_half_up(10_000, 20) == 2_000
    end

    test "rounds fractional cents to the nearest cent" do
      # 20% of 103 = 20.6 -> 21
      assert percentage_half_up(103, 20) == 21
      # 20% of 101 = 20.2 -> 20
      assert percentage_half_up(101, 20) == 20
      # 20% of 102 = 20.4 -> 20
      assert percentage_half_up(102, 20) == 20
    end

    test "rounds an exact half-cent upward" do
      # 50% of 101 = 50.5 -> 51
      assert percentage_half_up(101, 50) == 51
      # 50% of 75 = 37.5 -> 38
      assert percentage_half_up(75, 50) == 38
      # 50% of 74 = 37.0 -> 37
      assert percentage_half_up(74, 50) == 37
    end

    test "never rounds a flexible deposit down past the half-cent boundary" do
      # 20% of 7 = 1.4 -> 1
      assert percentage_half_up(7, 20) == 1
      # 20% of 8 = 1.6 -> 2
      assert percentage_half_up(8, 20) == 2
    end
  end
end
