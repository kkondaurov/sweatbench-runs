defmodule GroupStayWeb.GroupControllerTest do
  @moduledoc """
  Coverage of the group read endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  test "returns the documented group representation" do
    post_batch([open_group_operation("op-1001")])

    assert json_response(get_group("group-81"), 200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           }
  end

  test "a missing group returns 404 group_not_found" do
    conn = get_group("group-none")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "rooms keep their original order" do
    post_batch([
      open_group_operation("op-1", %{
        "rooms" => [
          %{"room_id" => "room-z", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 20_000},
          %{"room_id" => "room-m", "nightly_rate_cents" => 30_000}
        ]
      })
    ])

    rooms = json_response(get_group("group-81"), 200)["data"]["rooms"]

    assert Enum.map(rooms, & &1["room_id"]) == ["room-z", "room-a", "room-m"]
  end

  test "totals reflect recorded payments" do
    post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 7_000)])

    data = json_response(get_group("group-81"), 200)["data"]

    assert data["deposit_paid_cents"] == 7_000
    assert data["outstanding_deposit_cents"] == 12_500
    assert data["revision"] == 2
  end

  test "a cancelled group no longer has a due deposit and holds no cash" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 10_000),
      cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-26"})
    ])

    data = json_response(get_group("group-81"), 200)["data"]

    assert data["status"] == "cancelled"
    assert data["deposit_paid_cents"] == 0
    assert data["outstanding_deposit_cents"] == 0
    assert data["revision"] == 3
  end

  test "a rescheduled group reports its new stay dates" do
    post_batch([
      open_group_operation("op-1"),
      reschedule_operation("op-2", "group-81", "2026-12-20")
    ])

    data = json_response(get_group("group-81"), 200)["data"]

    assert data["arrival_on"] == "2026-12-20"
    assert data["departure_on"] == "2026-12-23"
  end
end
