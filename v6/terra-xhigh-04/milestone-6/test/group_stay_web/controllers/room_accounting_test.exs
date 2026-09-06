defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: true

  import Phoenix.ConnTest

  test "cancels selected rooms in room order and keeps the remaining room funded", %{conn: conn} do
    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 2_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             post_operations(conn, [
               open_group("open-rooms", "rooms"),
               cash_payment("pay-rooms", "rooms", 8_000),
               cancel_rooms("cancel-room-b", "rooms", ["room-b"])
             ])

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 30_000,
               "deposit_due_cents" => 6_000,
               "cash_paid_cents" => 6_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "active",
                   "lodging_total_cents" => 30_000,
                   "deposit_due_cents" => 6_000,
                   "cash_paid_cents" => 6_000,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "cancelled",
                   "lodging_total_cents" => 30_000,
                   "deposit_due_cents" => 6_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = get(build_conn(), "/api/v1/groups/rooms") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 6_000,
               "cash_refunded_cents" => 2_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-01-03") |> json_response(200)
  end

  test "reductions reopen active room deposits and chargebacks reclassify every remaining disposition",
       %{conn: conn} do
    post_operations(conn, [
      open_group("open-payments", "payments"),
      cash_payment("pay-reduced", "payments", 8_000),
      cancel_rooms("cancel-payment-room", "payments", ["room-b"])
    ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-reduced",
                 "group_id" => "payments",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 1_000,
                 "revision" => 4
               },
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-reduced",
                 "group_id" => "payments",
                 "charged_back_cents" => 7_000,
                 "outstanding_deposit_cents" => 6_000,
                 "revision" => 5
               }
             ]
           } =
             post_operations(build_conn(), [
               reduce_cash("reduce-pay", "pay-reduced", 1_000, 3),
               charge_back("charge-pay", "pay-reduced", 4)
             ])

    assert %{
             "data" => %{
               "payment_operation_id" => "pay-reduced",
               "original_group_id" => "payments",
               "recorded_cents" => 8_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 7_000
             }
           } = get(build_conn(), "/api/v1/payments/pay-reduced") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_reduced_cents" => 1_000,
               "cash_charged_back_cents" => 7_000
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-01-03") |> json_response(200)

    assert %{"results" => [%{"code" => "payment_not_chargeable", "status" => "rejected"}]} =
             post_operations(build_conn(), [charge_back("charge-pay-again", "pay-reduced", 5)])

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-reduced",
                 "status" => "applied",
                 "amount_cents" => 8_000,
                 "outstanding_deposit_cents" => 4_000,
                 "revision" => 2
               },
               %{
                 "operation_id" => "reduce-pay",
                 "status" => "applied",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 1_000,
                 "revision" => 4
               }
             ]
           } =
             post_operations(build_conn(), [
               cash_payment("pay-reduced", "payments", 8_000),
               reduce_cash("reduce-pay", "pay-reduced", 1_000, 3)
             ])
  end

  test "chargeback revokes converted credit and reports the applied-credit shortfall", %{
    conn: conn
  } do
    post_operations(conn, [
      open_group("open-source", "source"),
      cash_payment("pay-source", "source", 1_000),
      cancel_group("cancel-source", "source", "hotel_credit"),
      open_group("open-target", "target"),
      hotel_credit("apply-source-credit", "target", 1_100)
    ])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 1_000,
                 "group_id" => "source",
                 "revision" => 4
               }
             ]
           } = post_operations(build_conn(), [charge_back("charge-source", "pay-source", 3)])

    assert %{
             "data" => %{
               "cash_charged_back_cents" => 1_000,
               "credit_liability_cents" => 1_100,
               "credit_shortfall_cents" => 1_100
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-02-02") |> json_response(200)

    assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 1_100}} =
             get(build_conn(), "/api/v1/groups/target") |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             post_operations(build_conn(), [cancel_group("cancel-target", "target", "cash")])

    assert %{
             "data" => %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-02-03") |> json_response(200)
  end

  test "rejects unknown and non-payment payment statements", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(conn, "/api/v1/payments/missing") |> json_response(404)

    post_operations(build_conn(), [open_group("open-not-payment", "not-payment")])

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             get(build_conn(), "/api/v1/payments/open-not-payment") |> json_response(422)
  end

  defp open_group(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-04-10",
      "departure_on" => "2027-04-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
      ]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_rooms(operation_id, group_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-03",
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp cancel_group(operation_id, group_id, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2027-02-01",
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp hotel_credit(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-02-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_cash(operation_id, payment_operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
