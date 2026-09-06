defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @group_path "/api/v1/groups"

  defp open_group_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "zeta", "nightly_rate_cents" => 15000},
          %{"room_id" => "alpha", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp open_group(conn, overrides \\ %{}) do
    conn = post(conn, @batch_path, %{operations: [open_group_op(overrides)]})
    assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]
    conn
  end

  test "returns the full group representation", %{conn: conn} do
    conn = open_group(conn)
    conn = get(conn, "#{@group_path}/group-81")

    assert json_response(conn, 200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "zeta", "nightly_rate_cents" => 15000},
                 %{"room_id" => "alpha", "nightly_rate_cents" => 17500}
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19500
             }
           }
  end

  test "keeps rooms in their original order", %{conn: conn} do
    conn = open_group(conn)
    conn = get(conn, "#{@group_path}/group-81")
    rooms = json_response(conn, 200)["data"]["rooms"]
    assert Enum.map(rooms, & &1["room_id"]) == ["zeta", "alpha"]
  end

  test "reflects payments in the deposit totals", %{conn: conn} do
    conn = open_group(conn)

    conn =
      post(conn, @batch_path, %{
        operations: [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 7000
          }
        ]
      })

    assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

    conn = get(conn, "#{@group_path}/group-81")
    data = json_response(conn, 200)["data"]
    assert data["deposit_paid_cents"] == 7000
    assert data["outstanding_deposit_cents"] == 12500
    assert data["revision"] == 2
  end

  test "shows a cancelled group with no outstanding deposit", %{conn: conn} do
    conn = open_group(conn)

    conn =
      post(conn, @batch_path, %{
        operations: [
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ]
      })

    assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

    conn = get(conn, "#{@group_path}/group-81")
    data = json_response(conn, 200)["data"]
    assert data["status"] == "cancelled"
    assert data["outstanding_deposit_cents"] == 0
  end

  test "returns 404 for a missing group", %{conn: conn} do
    conn = get(conn, "#{@group_path}/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "shows cash and credit funding separately", %{conn: conn} do
    conn = open_group(conn)

    conn =
      post(conn, @batch_path, %{
        operations: [
          %{
            "operation_id" => "op-open-90",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-90",
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rate_plan" => "flexible",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
          },
          %{
            "operation_id" => "op-pay-90",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-90",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-90",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-90",
            "refund_method" => "hotel_credit"
          }
        ]
      })

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             json_response(conn, 200)["results"]

    conn =
      post(conn, @batch_path, %{
        operations: [
          %{
            "operation_id" => "op-pay-81",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 7000
          },
          %{
            "operation_id" => "op-credit-81",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 3000
          }
        ]
      })

    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             json_response(conn, 200)["results"]

    conn = get(conn, "#{@group_path}/group-81")
    data = json_response(conn, 200)["data"]
    assert data["deposit_paid_cents"] == 10000
    assert data["cash_paid_cents"] == 7000
    assert data["credit_paid_cents"] == 3000
    assert data["outstanding_deposit_cents"] == 9500
    assert data["revision"] == 3
  end
end
