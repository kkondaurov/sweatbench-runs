defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group(operation_id, group_id, rooms, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "room-accounting-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rate_plan" => "flexible",
        "rooms" => rooms
      },
      extra
    )
  end

  defp room(id, rate \\ 1_000), do: %{"room_id" => id, "nightly_rate_cents" => rate}

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  test "allocates funding by room order and cancels only selected active rooms", %{conn: conn} do
    opening = open_group("open-rooms", "rooms", [room("a"), room("b"), room("c")])

    cancel_rooms = %{
      "operation_id" => "cancel-both",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-03",
      "group_id" => "rooms",
      "room_ids" => ["b", "a"]
    }

    assert [
             _,
             %{"revision" => 2, "outstanding_deposit_cents" => 300},
             %{
               "status" => "applied",
               "group_id" => "rooms",
               "cancelled_room_ids" => ["a", "b"],
               "refunded_cents" => 300,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ] =
             submit(conn, [opening, payment("pay-rooms", "rooms", 300), cancel_rooms])

    assert %{"data" => group} = conn |> get("/api/v1/groups/rooms") |> json_response(200)
    assert group["lodging_total_cents"] == 1_000
    assert group["deposit_due_cents"] == 200
    assert group["deposit_paid_cents"] == 0
    assert group["cash_paid_cents"] == 0

    assert group["rooms"] == [
             %{
               "room_id" => "a",
               "nightly_rate_cents" => 1_000,
               "lodging_total_cents" => 1_000,
               "status" => "cancelled",
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "b",
               "nightly_rate_cents" => 1_000,
               "lodging_total_cents" => 1_000,
               "status" => "cancelled",
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "c",
               "nightly_rate_cents" => 1_000,
               "lodging_total_cents" => 1_000,
               "status" => "active",
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert %{"data" => statement} =
             conn |> get("/api/v1/payments/pay-rooms") |> json_response(200)

    assert statement == %{
             "payment_operation_id" => "pay-rooms",
             "original_group_id" => "rooms",
             "recorded_cents" => 300,
             "held_cents" => 0,
             "refunded_cents" => 300,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert [%{"status" => "rejected", "code" => "invalid_rooms"}] =
             submit(conn, [
               %{
                 "operation_id" => "bad-room-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "rooms",
                 "room_ids" => ["c", "c"]
               }
             ])
  end

  test "reductions and chargebacks preserve original retry results and reconcile cash", %{
    conn: conn
  } do
    opening =
      open_group("open-adjust", "adjust", [room("a", 2_500), room("b", 2_500)])

    original_payment = payment("pay-adjust", "adjust", 800)

    reduction = %{
      "operation_id" => "reduce-adjust",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay-adjust",
      "amount_cents" => 300,
      "expected_revision" => 2
    }

    assert [_, payment_result, reduction_result] =
             submit(conn, [opening, original_payment, reduction])

    assert payment_result["status"] == "applied"

    assert reduction_result == %{
             "operation_id" => "reduce-adjust",
             "status" => "applied",
             "payment_operation_id" => "pay-adjust",
             "group_id" => "adjust",
             "amount_cents" => 300,
             "outstanding_deposit_cents" => 500,
             "revision" => 3
           }

    assert %{"data" => group_after_reduction} =
             conn |> get("/api/v1/groups/adjust") |> json_response(200)

    assert Enum.map(group_after_reduction["rooms"], & &1["cash_paid_cents"]) == [500, 0]
    assert group_after_reduction["deposit_paid_cents"] == 500

    assert [%{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 3}] =
             submit(conn, [
               %{
                 "operation_id" => "stale-reduction",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-adjust",
                 "amount_cents" => 0,
                 "expected_revision" => 2
               }
             ])

    assert [%{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}] =
             submit(conn, [
               %{
                 "operation_id" => "excessive-reduction",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-adjust",
                 "amount_cents" => 501,
                 "expected_revision" => 3
               }
             ])

    assert [^reduction_result] = submit(conn, [reduction])
    assert [^payment_result] = submit(conn, [original_payment])

    chargeback = %{
      "operation_id" => "chargeback-adjust",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-adjust",
      "expected_revision" => 3
    }

    assert [
             chargeback_result = %{
               "charged_back_cents" => 500,
               "revision" => 4,
               "outstanding_deposit_cents" => 1_000
             }
           ] =
             submit(conn, [chargeback])

    assert [^chargeback_result] = submit(conn, [chargeback])

    assert [%{"status" => "rejected", "code" => "payment_not_reducible"}] =
             submit(conn, [
               %{
                 "operation_id" => "reduce-after-chargeback",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-adjust",
                 "amount_cents" => 1
               }
             ])

    assert [%{"status" => "rejected", "code" => "payment_not_chargeable"}] =
             submit(conn, [
               %{
                 "operation_id" => "second-chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-adjust"
               }
             ])

    assert %{"data" => group} = conn |> get("/api/v1/groups/adjust") |> json_response(200)
    assert group["cash_paid_cents"] == 0
    assert group["deposit_paid_cents"] == 0

    assert %{"data" => statement} =
             conn |> get("/api/v1/payments/pay-adjust") |> json_response(200)

    assert statement == %{
             "payment_operation_id" => "pay-adjust",
             "original_group_id" => "adjust",
             "recorded_cents" => 800,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 300,
             "charged_back_cents" => 500
           }

    assert %{"data" => ledger} = conn |> get("/api/v1/ledger") |> json_response(200)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_reduced_cents"] == 300
    assert ledger["cash_charged_back_cents"] == 500
  end

  test "credit chargeback creates a shortfall that restoration absorbs", %{conn: conn} do
    source = open_group("open-credit-source", "credit-source", [room("source", 5_000)])
    target = open_group("open-credit-target", "credit-target", [room("target", 5_000)])

    use_credit = %{
      "operation_id" => "apply-source-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-04",
      "group_id" => "credit-target",
      "amount_cents" => 110
    }

    cancel_source = %{
      "operation_id" => "cancel-credit-source",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "credit-source",
      "refund_method" => "hotel_credit"
    }

    assert [_, _, %{"credit_issued_cents" => 110}, %{"revision" => 1}] =
             submit(conn, [
               source,
               payment("pay-credit-source", "credit-source", 100),
               cancel_source,
               target
             ])

    assert [%{"status" => "applied", "revision" => 2}] = submit(conn, [use_credit])

    chargeback = %{
      "operation_id" => "chargeback-credit-source",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-credit-source"
    }

    assert [%{"group_id" => "credit-source", "charged_back_cents" => 100, "revision" => 4}] =
             submit(conn, [chargeback])

    assert %{"data" => ledger} = conn |> get("/api/v1/ledger?on=2027-01-04") |> json_response(200)
    assert ledger["credit_liability_cents"] == 110
    assert ledger["credit_shortfall_cents"] == 110

    assert %{"data" => target_group} =
             conn |> get("/api/v1/groups/credit-target") |> json_response(200)

    assert target_group["revision"] == 2
    assert target_group["credit_paid_cents"] == 110

    cancel_target = %{
      "operation_id" => "cancel-credit-target",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-05",
      "group_id" => "credit-target"
    }

    assert [%{"revision" => 3}] = submit(conn, [cancel_target])
    assert %{"data" => ledger} = conn |> get("/api/v1/ledger?on=2027-01-05") |> json_response(200)
    assert ledger["credit_liability_cents"] == 0
    assert ledger["credit_shortfall_cents"] == 0
  end

  test "room cancellation calculates one bonus on combined cash and restores lots once", %{
    conn: conn
  } do
    opening = open_group("open-small-rooms", "small-rooms", [room("a", 25), room("b", 25)])

    cancellation = %{
      "operation_id" => "cancel-small-rooms",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-03",
      "group_id" => "small-rooms",
      "room_ids" => ["b", "a"],
      "refund_method" => "hotel_credit"
    }

    assert [_, _, %{"credit_issued_cents" => 11, "cancelled_room_ids" => ["a", "b"]}] =
             submit(conn, [opening, payment("pay-small-rooms", "small-rooms", 10), cancellation])

    assert %{"data" => %{"available_cents" => 11}} =
             conn
             |> get("/api/v1/guests/room-accounting-guest/credit?on=2027-01-03")
             |> json_response(200)

    assert %{"data" => statement} =
             conn |> get("/api/v1/payments/pay-small-rooms") |> json_response(200)

    assert statement["converted_to_credit_cents"] == 10
    assert statement["held_cents"] == 0
  end

  test "telescopes credit bonus entitlements across payment commit order", %{conn: conn} do
    source = open_group("open-telescope", "telescope", [room("r", 3_000)])

    cancellation = %{
      "operation_id" => "cancel-telescope",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-03",
      "group_id" => "telescope",
      "refund_method" => "hotel_credit"
    }

    assert [_, _, _, %{"credit_issued_cents" => 226, "revision" => 4}] =
             submit(conn, [
               source,
               payment("pay-telescope-first", "telescope", 101),
               payment("pay-telescope-second", "telescope", 104),
               cancellation
             ])

    chargeback_first = %{
      "operation_id" => "chargeback-telescope-first",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-telescope-first"
    }

    assert [%{"charged_back_cents" => 101, "revision" => 5}] =
             submit(conn, [chargeback_first])

    assert %{"data" => %{"available_cents" => 115}} =
             conn
             |> get("/api/v1/guests/room-accounting-guest/credit?on=2027-01-03")
             |> json_response(200)

    chargeback_second = %{
      "operation_id" => "chargeback-telescope-second",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-telescope-second"
    }

    assert [%{"charged_back_cents" => 104, "revision" => 6}] =
             submit(conn, [chargeback_second])

    assert %{"data" => %{"available_cents" => 0}} =
             conn
             |> get("/api/v1/guests/room-accounting-guest/credit?on=2027-01-03")
             |> json_response(200)

    assert %{"data" => ledger} = conn |> get("/api/v1/ledger?on=2027-01-03") |> json_response(200)
    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 205
    assert ledger["credit_liability_cents"] == 0
  end

  test "payment reconciliation distinguishes absent and non-payment operation ids", %{conn: conn} do
    assert [%{"status" => "applied"}] =
             submit(conn, [open_group("open-reconcile", "reconcile", [room("r")])])

    assert %{"error" => %{"code" => "operation_not_found"}} =
             conn |> get("/api/v1/payments/missing") |> json_response(404)

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             conn |> get("/api/v1/payments/open-reconcile") |> json_response(422)
  end
end
