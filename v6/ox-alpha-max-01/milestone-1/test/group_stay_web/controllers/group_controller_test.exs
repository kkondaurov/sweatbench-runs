defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  test "renders the full group document with rooms in their original order", %{conn: conn} do
    rooms = [
      %{"room_id" => "room-zebra", "nightly_rate_cents" => 12_000},
      %{"room_id" => "room-alpha", "nightly_rate_cents" => 9_500}
    ]

    conn
    |> post_operations([open_operation(%{"group_id" => "ordered-group", "rooms" => rooms})])
    |> json_response(200)

    conn = get_group(conn, "ordered-group")

    assert json_response(conn, 200) == %{
             "data" => %{
               "group_id" => "ordered-group",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-zebra", "nightly_rate_cents" => 12_000},
                 %{"room_id" => "room-alpha", "nightly_rate_cents" => 9_500}
               ],
               "lodging_total_cents" => 64_500,
               "deposit_due_cents" => 12_900,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 12_900
             }
           }
  end

  test "returns 404 for a missing group", %{conn: conn} do
    conn = get_group(conn, "no-such-group")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
