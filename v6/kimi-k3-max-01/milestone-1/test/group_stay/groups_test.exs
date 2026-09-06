defmodule GroupStay.GroupsTest do
  use GroupStay.DataCase, async: true

  alias GroupStay.Groups

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
end
