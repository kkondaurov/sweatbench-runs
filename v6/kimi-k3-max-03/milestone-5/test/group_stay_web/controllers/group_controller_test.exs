defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  test "GET /api/v1/groups/:group_id returns 404 for a missing group", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/groups/group-missing")

    assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
  end

  test "returns partner identifiers, dates, rooms, and totals" do
    post_batch([open_group_op()])
    conn = get(build_conn(), ~p"/api/v1/groups/group-81")

    assert %{
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
           } = json_response(conn, 200)
  end

  test "rooms stay in their original order" do
    op =
      open_group_op(%{
        "rooms" => [
          %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 20_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 30_000}
        ]
      })

    post_batch([op])
    conn = get(build_conn(), ~p"/api/v1/groups/group-81")

    assert %{"data" => %{"rooms" => rooms}} = json_response(conn, 200)
    assert Enum.map(rooms, & &1["room_id"]) == ["room-c", "room-a", "room-b"]
  end

  test "group totals aggregate active rooms only" do
    post_batch([
      open_group_op(),
      record_cash_payment_op(%{"amount_cents" => 12_000}),
      cancel_group_op(%{"occurred_on" => "2026-11-20"})
    ])

    conn = get(build_conn(), ~p"/api/v1/groups/group-81")

    assert %{
             "data" => %{
               "revision" => 3,
               "status" => "cancelled",
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           } = json_response(conn, 200)
  end
end
