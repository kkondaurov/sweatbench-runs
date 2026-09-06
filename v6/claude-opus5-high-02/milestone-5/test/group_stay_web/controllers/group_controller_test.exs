defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "returns the group, its rooms, and its totals" do
    submit([
      open_group(%{
        "rooms" => [room("room-z", 15_000), room("room-a", 17_500), room("room-m", 10_000)]
      }),
      record_cash_payment(%{"amount_cents" => 5_000})
    ])

    assert {200, %{"data" => group}} = read_group("group-81")

    assert group == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "revision" => 2,
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "rooms" => [
               %{
                 "room_id" => "room-z",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 5_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-m",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 6_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 127_500,
             "deposit_due_cents" => 25_500,
             "deposit_paid_cents" => 5_000,
             "cash_paid_cents" => 5_000,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 20_500
           }
  end

  test "returns partner identifiers unchanged" do
    submit_one(
      open_group(%{
        "group_id" => "Group.81_AMS",
        "guest_id" => "Guest~22",
        "rooms" => [room("Room.A-1", 10_000)]
      })
    )

    assert {200, %{"data" => group}} = read_group("Group.81_AMS")
    assert group["group_id"] == "Group.81_AMS"
    assert group["guest_id"] == "Guest~22"
    assert [%{"room_id" => "Room.A-1"}] = group["rooms"]
  end

  test "a missing group is reported as group_not_found" do
    assert {404, body} = read_group("group-404")
    assert body == %{"error" => %{"code" => "group_not_found"}}
  end

  test "a cancelled group holds no rooms and owes nothing" do
    submit([
      open_group(%{"rooms" => [room("room-a", 10_000)]}),
      record_cash_payment(%{"amount_cents" => 1_500}),
      cancel_group()
    ])

    assert {200, %{"data" => group}} = read_group("group-81")
    assert group["status"] == "cancelled"
    assert group["deposit_due_cents"] == 0
    assert group["deposit_paid_cents"] == 0
    assert group["outstanding_deposit_cents"] == 0
    assert group["revision"] == 3

    # The room it was opened with is still listed, cancelled, with the deposit it was priced at.
    assert [room] = group["rooms"]
    assert room["status"] == "cancelled"
    assert room["deposit_due_cents"] == 6_000
    assert room["cash_paid_cents"] == 0
  end
end
