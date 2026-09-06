defmodule GroupStay.GroupsTest do
  use GroupStay.DataCase, async: true

  alias GroupStay.Groups
  alias GroupStay.Groups.Group

  describe "totals/3" do
    test "sums nightly rates across the nights of the stay" do
      rooms = [
        %{room_id: "room-a", nightly_rate_cents: 15000},
        %{room_id: "room-b", nightly_rate_cents: 17500}
      ]

      totals = Groups.totals("flexible", rooms, 3)

      assert totals.lodging_total_cents == 97_500
      assert totals.deposit_due_cents == 19_500
    end

    test "advance_purchase requires the full lodging amount" do
      rooms = [%{room_id: "room-a", nightly_rate_cents: 15000}]

      totals = Groups.totals("advance_purchase", rooms, 3)

      assert totals.deposit_due_cents == 45_000
    end

    test "flexible deposits round each room separately" do
      rooms = [
        %{room_id: "room-a", nightly_rate_cents: 101},
        %{room_id: "room-b", nightly_rate_cents: 102}
      ]

      totals = Groups.totals("flexible", rooms, 1)

      assert totals.lodging_total_cents == 203
      assert totals.deposit_due_cents == 40
    end
  end

  describe "round_half_up/2" do
    test "rounds to the nearest integer" do
      assert Groups.round_half_up(2020, 100) == 20
      assert Groups.round_half_up(2040, 100) == 20
      assert Groups.round_half_up(2060, 100) == 21
    end

    test "rounds an exact half upward" do
      assert Groups.round_half_up(2050, 100) == 21
      assert Groups.round_half_up(1, 2) == 1
      assert Groups.round_half_up(3, 2) == 2
    end

    test "handles exact divisions" do
      assert Groups.round_half_up(2000, 100) == 20
      assert Groups.round_half_up(0, 100) == 0
    end
  end

  describe "policy_version/2" do
    test "advance purchase is always non-refundable" do
      assert Groups.policy_version("advance_purchase", ~D[2026-06-01]) == "advance-nonrefundable"
      assert Groups.policy_version("advance_purchase", ~D[2027-06-01]) == "advance-nonrefundable"
    end

    test "flexible bookings before 2027-01-01 keep the 14-day window" do
      assert Groups.policy_version("flexible", ~D[2026-12-31]) == "flex-14"
    end

    test "flexible bookings on or after 2027-01-01 use the 30-day window" do
      assert Groups.policy_version("flexible", ~D[2027-01-01]) == "flex-30"
      assert Groups.policy_version("flexible", ~D[2028-03-01]) == "flex-30"
    end
  end

  describe "refundable_until/1 and refundable?/2" do
    test "flexible groups are refundable through arrival minus the window" do
      flex_14 = %Group{policy_version: "flex-14", arrival_on: ~D[2026-12-10]}
      assert Groups.refundable_until(flex_14) == ~D[2026-11-26]
      assert Groups.refundable?(flex_14, ~D[2026-11-26])
      refute Groups.refundable?(flex_14, ~D[2026-11-27])

      flex_30 = %Group{policy_version: "flex-30", arrival_on: ~D[2027-06-10]}
      assert Groups.refundable_until(flex_30) == ~D[2027-05-11]
      assert Groups.refundable?(flex_30, ~D[2027-05-11])
      refute Groups.refundable?(flex_30, ~D[2027-05-12])
    end

    test "advance-purchase groups are never refundable" do
      group = %Group{policy_version: "advance-nonrefundable", arrival_on: ~D[2027-06-10]}
      assert Groups.refundable_until(group) == nil
      refute Groups.refundable?(group, ~D[2025-01-01])
    end
  end
end
