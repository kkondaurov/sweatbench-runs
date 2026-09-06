defmodule GroupStay.CreditTest do
  use ExUnit.Case, async: true

  alias GroupStay.Credit

  describe "bonus_value/1" do
    test "applies the standard half-up rounding rule to the 10% bonus" do
      assert Credit.bonus_value(6000) == 6600
      # 1 * 110% = 1.1 -> 1
      assert Credit.bonus_value(1) == 1
      # 5 * 110% = 5.5 -> 6: an exact half-cent rounds upward
      assert Credit.bonus_value(5) == 6
      # 15 * 110% = 16.5 -> 17
      assert Credit.bonus_value(15) == 17
      # 999 * 110% = 1098.9 -> 1099
      assert Credit.bonus_value(999) == 1099
    end
  end

  describe "availability window" do
    test "the lot is available through 365 days after cancellation and expires the following day" do
      assert Credit.availability_limit(~D[2026-11-20]) == ~D[2027-11-20]
      assert Credit.expires_on(~D[2026-11-20]) == ~D[2027-11-21]
    end

    test "a leap day inside the window shifts both dates accordingly" do
      assert Credit.availability_limit(~D[2027-07-01]) == ~D[2028-06-30]
      assert Credit.expires_on(~D[2027-07-01]) == ~D[2028-07-01]
    end
  end
end
