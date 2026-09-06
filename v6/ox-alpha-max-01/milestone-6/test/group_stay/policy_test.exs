defmodule GroupStay.PolicyTest do
  use ExUnit.Case, async: true

  alias GroupStay.Policy

  describe "version_for/2" do
    test "flexible bookings before 2027-01-01 use the 14-day window" do
      assert Policy.version_for("flexible", ~D[2026-12-31]) == "flex-14"
      assert Policy.version_for("flexible", ~D[2020-01-01]) == "flex-14"
    end

    test "flexible bookings on or after 2027-01-01 use the 30-day window" do
      assert Policy.version_for("flexible", ~D[2027-01-01]) == "flex-30"
      assert Policy.version_for("flexible", ~D[2030-06-15]) == "flex-30"
    end

    test "advance purchase is always non-refundable" do
      assert Policy.version_for("advance_purchase", ~D[2026-01-01]) == "advance-nonrefundable"
      assert Policy.version_for("advance_purchase", ~D[2027-01-01]) == "advance-nonrefundable"
    end
  end

  describe "window_days/1" do
    test "maps each policy version to its window" do
      assert Policy.window_days("flex-14") == 14
      assert Policy.window_days("flex-30") == 30
      assert Policy.window_days("advance-nonrefundable") == nil
    end
  end

  describe "refundable_until/2" do
    test "is the arrival minus the policy window for flexible versions" do
      assert Policy.refundable_until("flex-14", ~D[2026-12-10]) == ~D[2026-11-26]
      assert Policy.refundable_until("flex-30", ~D[2027-03-10]) == ~D[2027-02-08]
    end

    test "is null for advance purchase" do
      assert Policy.refundable_until("advance-nonrefundable", ~D[2026-12-10]) == nil
    end
  end

  describe "refundable?/3" do
    test "cancellation on the horizon date itself is refundable" do
      assert Policy.refundable?("flex-14", ~D[2026-12-10], ~D[2026-11-26])
      refute Policy.refundable?("flex-14", ~D[2026-12-10], ~D[2026-11-27])
    end

    test "advance purchase is never refundable regardless of notice" do
      refute Policy.refundable?("advance-nonrefundable", ~D[2026-12-10], ~D[2026-01-01])
    end
  end
end
