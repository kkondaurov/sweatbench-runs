defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  test "allocates funding by room, cancels selected rooms, and leaves the rest active", %{
    conn: conn
  } do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "revision" => 3,
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "refunded_cents" => 200
               }
             ]
           } =
             post_batch(conn, [
               open("rooms-1"),
               cash_payment("rooms-pay", "rooms-1", 220, 1),
               cancel_rooms("rooms-cancel", "rooms-1", ["room-b", "room-a"], 2)
             ])

    assert %{
             "data" => %{
               "status" => "active",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 20,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 100},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 100},
                 %{"room_id" => "room-c", "status" => "active", "cash_paid_cents" => 20}
               ]
             }
           } = json_response(get(conn, "/api/v1/groups/rooms-1"), 200)
  end

  test "reduces and charges back a recorded payment without rewriting its result", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [open("cash-1"), cash_payment("cash-pay", "cash-1", 100, 1)])

    original =
      post_batch(conn, [
        %{
          "operation_id" => "cash-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "cash-pay",
          "amount_cents" => 40,
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"amount_cents" => 40, "revision" => 3}]} = original

    assert %{"results" => [%{"charged_back_cents" => 60, "revision" => 4}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cash-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "cash-pay",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => statement} = json_response(get(conn, "/api/v1/payments/cash-pay"), 200)

    assert statement == %{
             "payment_operation_id" => "cash-pay",
             "original_group_id" => "cash-1",
             "recorded_cents" => 100,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 40,
             "charged_back_cents" => 60
           }

    assert %{"results" => [replayed]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cash-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "cash-1",
                 "amount_cents" => 100,
                 "expected_revision" => 1
               }
             ])

    assert replayed["revision"] == 2

    assert %{"data" => %{"cash_reduced_cents" => 40, "cash_charged_back_cents" => 60}} =
             json_response(get(conn, "/api/v1/ledger"), 200)
  end

  test "clawbacks credit entitlement and reports the current shortfall", %{conn: conn} do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"revision" => 3},
               %{"revision" => 4}
             ]
           } =
             post_batch(conn, [
               open("credit-source"),
               cash_payment("credit-pay-1", "credit-source", 50, 1),
               cash_payment("credit-pay-2", "credit-source", 50, 2),
               cancel_rooms_with_method(
                 "credit-cancel",
                 "credit-source",
                 ["room-a"],
                 3,
                 "hotel_credit"
               )
             ])

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open("credit-target"),
               %{
                 "operation_id" => "credit-use",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "credit-target",
                 "amount_cents" => 80,
                 "expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"charged_back_cents" => 50, "revision" => 5}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "credit-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2027-01-03",
                 "payment_operation_id" => "credit-pay-1",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => %{"credit_shortfall_cents" => 25, "credit_liability_cents" => 80}} =
             json_response(get(conn, "/api/v1/ledger?on=2027-01-03"), 200)
  end

  test "distinguishes missing, non-payment, and unreconcilable payment targets", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open("target-errors")])

    assert %{"results" => [%{"code" => "operation_not_found"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "missing-target",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "payment_operation_id" => "missing-payment",
                 "amount_cents" => 1
               }
             ])

    assert %{"results" => [%{"code" => "payment_not_reducible"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "open-reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "payment_operation_id" => "open-target-errors",
                 "amount_cents" => 1
               }
             ])

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "open-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-04",
                 "payment_operation_id" => "open-target-errors"
               }
             ])

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             json_response(get(conn, "/api/v1/payments/open-target-errors"), 422)
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 500},
        %{"room_id" => "room-b", "nightly_rate_cents" => 500},
        %{"room_id" => "room-c", "nightly_rate_cents" => 500}
      ]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => revision
    }
  end

  defp cancel_rooms(operation_id, group_id, room_ids, revision) do
    cancel_rooms_with_method(operation_id, group_id, room_ids, revision, nil)
  end

  defp cancel_rooms_with_method(operation_id, group_id, room_ids, revision, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "room_ids" => room_ids,
      "expected_revision" => revision
    }
    |> maybe_refund_method(refund_method)
  end

  defp maybe_refund_method(operation, nil), do: operation
  defp maybe_refund_method(operation, method), do: Map.put(operation, "refund_method", method)
end
