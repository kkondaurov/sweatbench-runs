defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  @open %{
    "operation_id" => "op-1001",
    "type" => "open_group",
    "occurred_on" => "2026-10-03",
    "group_id" => "group-81",
    "guest_id" => "guest-22",
    "property_id" => "ams-canal",
    "arrival_on" => "2026-12-10",
    "departure_on" => "2026-12-13",
    "rate_plan" => "flexible",
    "rooms" => [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
    ]
  }

  defp open_group(conn, op \\ @open) do
    post(conn, "/api/v1/partner-batches", %{"operations" => [op]})
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns a group with identifiers, dates, status, rooms in order, and totals", %{
      conn: conn
    } do
      conn = open_group(conn)
      assert Jason.decode!(conn.resp_body)["results"] |> hd() |> Map.get("status") == "applied"

      assert json_response(get(conn, "/api/v1/groups/group-81"), 200) == %{
               "data" => %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "revision" => 1,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             }
    end

    test "tracks payments and cancellation state", %{conn: conn} do
      open_group(conn)

      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "op-p",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10_000
          }
        ]
      })

      data = json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 10_000
      assert data["cash_paid_cents"] == 10_000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 9_500

      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "op-c",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          }
        ]
      })

      data = json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]
      assert data["status"] == "cancelled"
      assert data["revision"] == 3
      assert data["deposit_due_cents"] == 0
      assert data["deposit_paid_cents"] == 10_000
      assert data["outstanding_deposit_cents"] == 0
    end

    test "returns 404 group_not_found for an unknown group", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/groups/group-nope"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end
end
