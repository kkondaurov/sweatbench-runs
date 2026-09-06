defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group with identifiers, dates, rooms, and totals", %{conn: conn} do
      open_group!(conn)

      group = get_group!(fresh_conn(), "group-81")

      assert group == %{
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
                   "nightly_rate_cents" => 15000,
                   "status" => "active",
                   "deposit_due_cents" => 9_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17500,
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
    end

    test "keeps rooms in their original order", %{conn: conn} do
      open_group!(conn, %{
        "rooms" => [
          %{"room_id" => "room-c", "nightly_rate_cents" => 9000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 11000}
        ]
      })

      group = get_group!(fresh_conn(), "group-81")
      assert Enum.map(group["rooms"], & &1["room_id"]) == ["room-c", "room-a", "room-b"]
    end

    test "reflects payments in the totals", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 12_000})
      ])

      group = get_group!(fresh_conn(), "group-81")
      assert group["deposit_paid_cents"] == 12_000
      assert group["outstanding_deposit_cents"] == 7_500
      assert group["revision"] == 2
    end

    test "returns 404 for a missing group", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/groups/no-such-group")
        |> json_response(404)

      assert response == %{"error" => %{"code" => "group_not_found"}}
    end
  end
end
