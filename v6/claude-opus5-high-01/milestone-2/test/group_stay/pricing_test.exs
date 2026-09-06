defmodule GroupStay.PricingTest do
  use ExUnit.Case, async: true

  alias GroupStay.Pricing

  describe "percent_of/2" do
    test "rounds to the nearest cent" do
      assert Pricing.percent_of(1004, 20) == 201
      assert Pricing.percent_of(1014, 20) == 203
      assert Pricing.percent_of(13, 20) == 3
      assert Pricing.percent_of(12, 20) == 2
    end

    test "rounds an exact half cent upward" do
      assert Pricing.percent_of(25, 50) == 13
      assert Pricing.percent_of(75, 50) == 38
      assert Pricing.percent_of(1, 50) == 1
    end

    test "leaves exact amounts alone" do
      assert Pricing.percent_of(0, 20) == 0
      assert Pricing.percent_of(15_000, 20) == 3000
      assert Pricing.percent_of(97_500, 100) == 97_500
    end
  end

  describe "room_deposit_cents/2" do
    test "a flexible room owes a fifth of its lodging" do
      assert Pricing.room_deposit_cents("flexible", 45_000) == 9000
    end

    test "an advance purchase room owes all of it" do
      assert Pricing.room_deposit_cents("advance_purchase", 45_000) == 45_000
    end
  end

  describe "nights/2" do
    test "counts the nights of a stay" do
      assert Pricing.nights(~D[2026-12-10], ~D[2026-12-13]) == 3
      assert Pricing.nights(~D[2026-12-31], ~D[2027-01-01]) == 1
    end
  end
end
