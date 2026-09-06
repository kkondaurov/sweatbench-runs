defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  test "a missing group returns 404 with group_not_found", %{conn: conn} do
    conn = get(conn, "/api/v1/groups/ghost-group")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "returns the full group view", %{conn: conn} do
    open_group!(conn)

    assert json_response(get(conn, "/api/v1/groups/group-81"), 200) == %{
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
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15_000,
                   "status" => "active",
                   "deposit_due_cents" => 9_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17_500,
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           }
  end

  test "rooms keep their original order", %{conn: conn} do
    rooms = [
      %{"room_id" => "zeta", "nightly_rate_cents" => 10_000},
      %{"room_id" => "beta", "nightly_rate_cents" => 20_000},
      %{"room_id" => "mika", "nightly_rate_cents" => 30_000}
    ]

    open_group!(conn, %{"rooms" => rooms})

    data = json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]
    assert Enum.map(data["rooms"], & &1["room_id"]) == ~w(zeta beta mika)
  end
end
