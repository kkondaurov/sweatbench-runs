defmodule GroupStay.PoliciesTest do
  use ExUnit.Case, async: true

  alias GroupStay.Policies

  describe "policy_version/2" do
    test "flexible stays before the 2027 cutover keep the fourteen-day policy" do
      assert Policies.policy_version("flexible", ~D[2026-12-31]) == "flex-14"
    end

    test "flexible stays on or after the 2027 cutover use the thirty-day policy" do
      assert Policies.policy_version("flexible", ~D[2027-01-01]) == "flex-30"
    end

    test "advance purchase stays are non-refundable" do
      assert Policies.policy_version("advance_purchase", ~D[2027-06-01]) ==
               "advance-nonrefundable"
    end
  end

  describe "refundable_until/2" do
    test "is the arrival date minus the cancellation window" do
      assert Policies.refundable_until("flex-14", ~D[2026-12-10]) == ~D[2026-11-26]
      assert Policies.refundable_until("flex-30", ~D[2027-03-10]) == ~D[2027-02-08]
    end

    test "is nil for advance purchase" do
      assert Policies.refundable_until("advance-nonrefundable", ~D[2026-12-10]) == nil
    end
  end

  describe "refundable?/3" do
    test "is refundable through the refundable date, inclusive" do
      assert Policies.refundable?("flex-14", ~D[2026-12-10], ~D[2026-11-26])
      refute Policies.refundable?("flex-14", ~D[2026-12-10], ~D[2026-11-27])
      assert Policies.refundable?("flex-30", ~D[2027-03-10], ~D[2027-02-08])
      refute Policies.refundable?("flex-30", ~D[2027-03-10], ~D[2027-02-09])
    end

    test "advance purchase is never refundable" do
      refute Policies.refundable?("advance-nonrefundable", ~D[2027-03-10], ~D[2027-01-01])
    end
  end
end
