defmodule GroupStay.DepositsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Deposits

  test "rounds an exact half cent upward" do
    assert Deposits.rounded_percent(1, 50) == 1
    assert Deposits.rounded_percent(5, 50) == 3
    assert Deposits.rounded_percent(3, 50) == 2
    assert Deposits.rounded_percent(2, 50) == 1
  end

  test "rounds 20 percent of lodging to the nearest cent" do
    assert Deposits.rounded_percent(1, 20) == 0
    assert Deposits.rounded_percent(2, 20) == 0
    assert Deposits.rounded_percent(3, 20) == 1
    assert Deposits.rounded_percent(5, 20) == 1
    assert Deposits.rounded_percent(8, 20) == 2
  end

  test "quotes flexible deposits per room before summing" do
    rooms = [
      %{nightly_rate_cents: 3},
      %{nightly_rate_cents: 3}
    ]

    assert Deposits.quote(rooms, 1, "flexible") == %{
             lodging_total_cents: 6,
             deposit_due_cents: 2
           }
  end

  test "quotes flexible deposit from nights times rate, rounded once" do
    rooms = [%{nightly_rate_cents: 3}]

    assert Deposits.quote(rooms, 2, "flexible") == %{
             lodging_total_cents: 6,
             deposit_due_cents: 1
           }
  end

  test "quotes advance purchase as the full lodging amount" do
    rooms = [
      %{nightly_rate_cents: 3},
      %{nightly_rate_cents: 7}
    ]

    assert Deposits.quote(rooms, 2, "advance_purchase") == %{
             lodging_total_cents: 20,
             deposit_due_cents: 20
           }
  end
end
