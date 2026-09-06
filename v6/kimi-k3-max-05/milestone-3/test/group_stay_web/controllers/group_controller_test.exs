defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op do
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
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  test "returns the group with identifiers, dates, rooms in order, and totals", %{conn: conn} do
    conn = post_batch(conn, %{"operations" => [open_op()]})
    conn = get(conn, ~p"/api/v1/groups/group-81")

    assert %{"data" => group} = json_response(conn, 200)

    assert group == %{
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
  end

  test "tracks paid and outstanding amounts as payments land", %{conn: conn} do
    operations_with_payment = [
      open_op(),
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_000
      }
    ]

    conn = post_batch(conn, %{"operations" => operations_with_payment})
    conn = get(conn, ~p"/api/v1/groups/group-81")

    assert %{"data" => group} = json_response(conn, 200)
    assert group["deposit_paid_cents"] == 9_000
    assert group["outstanding_deposit_cents"] == 10_500
    assert group["revision"] == 2
  end

  test "keeps the paid history and clears the outstanding deposit when cancelled",
       %{conn: conn} do
    operations = [
      open_op(),
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_000
      },
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81"
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})
    conn = get(conn, ~p"/api/v1/groups/group-81")

    assert %{"data" => group} = json_response(conn, 200)
    assert group["status"] == "cancelled"
    assert group["deposit_paid_cents"] == 9_000
    assert group["outstanding_deposit_cents"] == 0
  end

  test "returns 404 for a missing group", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/groups/group-missing")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
