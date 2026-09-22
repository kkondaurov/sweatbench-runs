defmodule GroupStay.CancellationMathTest do
  use ExUnit.Case, async: true

  alias GroupStay.Credits
  alias GroupStay.Policy

  test "adds a 10 percent bonus rounded to the nearest cent, half cents upward" do
    assert Credits.issued_amount(0) == 0
    assert Credits.issued_amount(1) == 1
    assert Credits.issued_amount(4) == 4
    assert Credits.issued_amount(5) == 6
    assert Credits.issued_amount(6) == 7
    assert Credits.issued_amount(14) == 15
    assert Credits.issued_amount(15) == 17
    assert Credits.issued_amount(25) == 28
    assert Credits.issued_amount(100) == 110
    assert Credits.issued_amount(5000) == 5500
  end

  test "fixes policy from the booking date and recomputes the refundable date from arrival" do
    old = %{rate_plan: "flexible", booked_on: ~D[2026-12-31], arrival_on: ~D[2027-06-01]}
    boundary = %{rate_plan: "flexible", booked_on: ~D[2027-01-01], arrival_on: ~D[2027-06-01]}
    later = %{rate_plan: "flexible", booked_on: ~D[2027-03-04], arrival_on: ~D[2027-08-15]}

    advance = %{
      rate_plan: "advance_purchase",
      booked_on: ~D[2027-02-01],
      arrival_on: ~D[2027-06-01]
    }

    assert Policy.for_group(old) == %{version: "flex-14", refundable_until: ~D[2027-05-18]}
    assert Policy.for_group(boundary) == %{version: "flex-30", refundable_until: ~D[2027-05-02]}
    assert Policy.for_group(later) == %{version: "flex-30", refundable_until: ~D[2027-07-16]}
    assert Policy.for_group(advance) == %{version: "advance-nonrefundable", refundable_until: nil}

    assert Policy.refundable?(old, ~D[2027-05-18])
    refute Policy.refundable?(old, ~D[2027-05-19])
    assert Policy.refundable?(boundary, ~D[2027-05-02])
    refute Policy.refundable?(boundary, ~D[2027-05-03])
    refute Policy.refundable?(advance, ~D[2026-01-01])
  end
end
