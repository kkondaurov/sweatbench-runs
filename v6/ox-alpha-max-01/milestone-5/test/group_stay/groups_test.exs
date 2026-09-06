defmodule GroupStay.GroupsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Groups

  describe "percent_of/2" do
    test "rounds to the nearest cent with an exact half-cent rounding upward" do
      assert Groups.percent_of(97_500, 20) == 19_500
      assert Groups.percent_of(33_333, 20) == 6_667
      # 5 * 50% = 2.5 cents -> 3
      assert Groups.percent_of(5, 50) == 3
      assert Groups.percent_of(1, 10) == 0
      assert Groups.percent_of(15, 10) == 2
    end
  end

  describe "deposit_due_cents/3" do
    @nights 2

    test "flexible sums each room's separately rounded 20% deposit" do
      rooms = [
        %{room_id: "room-a", nightly_rate_cents: 11_111},
        %{room_id: "room-b", nightly_rate_cents: 11_112}
      ]

      # Lodging: 22222 and 22224; deposits: 4444.4 -> 4444 and 4444.8 -> 4445.
      assert Groups.deposit_due_cents("flexible", rooms, @nights) == 8_889
    end

    test "advance_purchase requires the full lodging amount" do
      rooms = [
        %{room_id: "room-a", nightly_rate_cents: 12_345},
        %{room_id: "room-b", nightly_rate_cents: 1}
      ]

      assert Groups.deposit_due_cents("advance_purchase", rooms, @nights) == 24_692
    end
  end
end
