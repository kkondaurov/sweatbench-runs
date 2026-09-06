defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: true

  @occurred_on "2026-10-03"

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp open_operation(group_id) do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp payment_operation(group_id, amount_cents) do
    %{
      "operation_id" => "op-pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id) do
    %{
      "operation_id" => "op-cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => @occurred_on,
      "group_id" => group_id
    }
  end

  test "returns the group with partner identifiers, dates, rooms, and totals" do
    conn = build_conn()
    submit!(conn, [open_operation("group-81")])
    submit!(conn, [payment_operation("group-81", 5000)])

    conn = get(build_conn(), "/api/v1/groups/group-81")

    assert json_response(conn, 200) == %{
             "data" => %{
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
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 5000,
               "cash_paid_cents" => 5000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 14_500
             }
           }
  end

  test "rooms keep their original order" do
    conn = build_conn()

    operation =
      open_operation("group-order")
      |> Map.put("rooms", [
        %{"room_id" => "room-z", "nightly_rate_cents" => 17500},
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-m", "nightly_rate_cents" => 16000}
      ])

    submit!(conn, [operation])

    conn = get(build_conn(), "/api/v1/groups/group-order")
    rooms = json_response(conn, 200)["data"]["rooms"]
    assert Enum.map(rooms, & &1["room_id"]) == ["room-z", "room-a", "room-m"]
  end

  test "a cancelled group shows its status and no outstanding deposit" do
    conn = build_conn()
    submit!(conn, [open_operation("group-done")])
    submit!(conn, [payment_operation("group-done", 5000)])
    submit!(conn, [cancel_operation("group-done")])

    conn = get(build_conn(), "/api/v1/groups/group-done")
    data = json_response(conn, 200)["data"]

    assert data["status"] == "cancelled"
    assert data["deposit_paid_cents"] == 5000
    assert data["outstanding_deposit_cents"] == 0
    assert data["revision"] == 3
  end

  test "returns 404 group_not_found for a missing group" do
    conn = get(build_conn(), "/api/v1/groups/nope")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
