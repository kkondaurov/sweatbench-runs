defmodule GroupStay.CancellationPolicyTest do
  use ExUnit.Case, async: true

  alias GroupStay.CancellationPolicy

  test "flexible groups booked before 2027 keep the 14-day window" do
    assert CancellationPolicy.version_for("flexible", ~D[2026-12-31]) == "flex-14"
    assert CancellationPolicy.version_for("flexible", ~D[2027-01-01]) == "flex-30"
    assert CancellationPolicy.version_for("flexible", ~D[2031-06-15]) == "flex-30"
  end

  test "advance purchase is non-refundable whenever it was booked" do
    for booked_on <- [~D[2026-12-31], ~D[2027-01-01]] do
      assert CancellationPolicy.version_for("advance_purchase", booked_on) ==
               "advance-nonrefundable"
    end

    assert CancellationPolicy.refundable_until("advance-nonrefundable", ~D[2027-03-01]) == nil
    refute CancellationPolicy.refundable?("advance-nonrefundable", ~D[2027-03-01], ~D[2026-01-01])
  end

  test "refundable_until is the arrival minus the window and is itself refundable" do
    assert CancellationPolicy.refundable_until("flex-14", ~D[2027-03-01]) == ~D[2027-02-15]
    assert CancellationPolicy.refundable_until("flex-30", ~D[2027-03-01]) == ~D[2027-01-30]

    assert CancellationPolicy.refundable?("flex-30", ~D[2027-03-01], ~D[2027-01-30])
    refute CancellationPolicy.refundable?("flex-30", ~D[2027-03-01], ~D[2027-01-31])
    assert CancellationPolicy.refundable?("flex-14", ~D[2027-03-01], ~D[2027-02-15])
    refute CancellationPolicy.refundable?("flex-14", ~D[2027-03-01], ~D[2027-02-16])
  end
end
