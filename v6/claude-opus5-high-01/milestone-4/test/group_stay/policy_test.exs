defmodule GroupStay.PolicyTest do
  use ExUnit.Case, async: true

  alias GroupStay.Policy

  describe "version_for/2" do
    test "flexible groups booked before 2027 keep the 14-day window" do
      assert Policy.version_for("flexible", ~D[2026-10-03]) == "flex-14"
      assert Policy.version_for("flexible", ~D[2026-12-31]) == "flex-14"
    end

    test "flexible groups booked from 2027 use the 30-day window" do
      assert Policy.version_for("flexible", ~D[2027-01-01]) == "flex-30"
      assert Policy.version_for("flexible", ~D[2030-06-01]) == "flex-30"
    end

    test "advance purchase stays non-refundable whenever it is booked" do
      assert Policy.version_for("advance_purchase", ~D[2026-10-03]) == "advance-nonrefundable"
      assert Policy.version_for("advance_purchase", ~D[2027-01-01]) == "advance-nonrefundable"
    end
  end

  describe "refundable_until/2" do
    test "is the arrival date minus the cancellation window" do
      assert Policy.refundable_until("flex-14", ~D[2026-12-10]) == ~D[2026-11-26]
      assert Policy.refundable_until("flex-30", ~D[2027-12-10]) == ~D[2027-11-10]
    end

    test "is nil for a never-refundable policy" do
      assert Policy.refundable_until("advance-nonrefundable", ~D[2026-12-10]) == nil
    end
  end

  describe "refundable?/3" do
    test "cancelling on the last day of the window is still refundable" do
      assert Policy.refundable?("flex-14", ~D[2026-12-10], ~D[2026-11-26])
      refute Policy.refundable?("flex-14", ~D[2026-12-10], ~D[2026-11-27])

      assert Policy.refundable?("flex-30", ~D[2027-12-10], ~D[2027-11-10])
      refute Policy.refundable?("flex-30", ~D[2027-12-10], ~D[2027-11-11])
    end

    test "advance purchase is never refundable" do
      refute Policy.refundable?("advance-nonrefundable", ~D[2026-12-10], ~D[2020-01-01])
    end
  end
end
