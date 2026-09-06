defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group, guest \\ "guest", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group,
        "guest_id" => guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 500},
          %{"room_id" => "b", "nightly_rate_cents" => 500},
          %{"room_id" => "c", "nightly_rate_cents" => 500}
        ]
      },
      overrides
    )
  end

  defp pay(id, group, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "funding fills rooms in order and selected cancellation preserves the other allocations",
       %{
         conn: conn
       } do
    assert [_, _, _] =
             submit(conn, [
               open("open", "group"),
               pay("pay-1", "group", 150),
               pay("pay-2", "group", 100)
             ])

    assert %{
             "data" => %{
               "rooms" => [
                 %{
                   "room_id" => "a",
                   "status" => "active",
                   "deposit_due_cents" => 100,
                   "cash_paid_cents" => 100,
                   "credit_paid_cents" => 0
                 },
                 %{"room_id" => "b", "status" => "active", "cash_paid_cents" => 100},
                 %{"room_id" => "c", "status" => "active", "cash_paid_cents" => 50}
               ]
             }
           } = get(conn, "/api/v1/groups/group") |> json_response(200)

    cancel = %{
      "operation_id" => "cancel-rooms",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-04-01",
      "group_id" => "group",
      "room_ids" => ["c", "b"]
    }

    assert [
             %{
               "status" => "applied",
               "cancelled_room_ids" => ["b", "c"],
               "refunded_cents" => 150,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }
           ] = submit(conn, [cancel])

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 500,
               "deposit_due_cents" => 100,
               "deposit_paid_cents" => 100,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "a", "status" => "active", "cash_paid_cents" => 100},
                 %{"room_id" => "b", "status" => "cancelled", "cash_paid_cents" => 0},
                 %{"room_id" => "c", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } = get(conn, "/api/v1/groups/group") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 100, "cash_refunded_cents" => 150}} =
             get(conn, "/api/v1/ledger") |> json_response(200)

    assert %{"data" => %{"held_cents" => 100, "refunded_cents" => 50}} =
             get(conn, "/api/v1/payments/pay-1") |> json_response(200)

    assert %{"data" => %{"held_cents" => 0, "refunded_cents" => 100}} =
             get(conn, "/api/v1/payments/pay-2") |> json_response(200)

    assert [%{"code" => "invalid_rooms"}, %{"code" => "invalid_rooms"}] =
             submit(conn, [
               %{cancel | "operation_id" => "duplicate", "room_ids" => ["a", "a"]},
               %{cancel | "operation_id" => "already-cancelled", "room_ids" => ["b"]}
             ])
  end

  test "cash reductions reverse the target payment fill and reconcile all dispositions", %{
    conn: conn
  } do
    submit(conn, [open("open", "group"), pay("pay", "group", 250)])

    reduce = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "amount_cents" => 60,
      "expected_revision" => 2
    }

    assert [
             %{
               "status" => "applied",
               "group_id" => "group",
               "payment_operation_id" => "pay",
               "amount_cents" => 60,
               "outstanding_deposit_cents" => 110,
               "revision" => 3
             }
           ] = submit(conn, [reduce])

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "a", "cash_paid_cents" => 100},
                 %{"room_id" => "b", "cash_paid_cents" => 90},
                 %{"room_id" => "c", "cash_paid_cents" => 0}
               ]
             }
           } = get(conn, "/api/v1/groups/group") |> json_response(200)

    assert %{
             "data" => %{
               "payment_operation_id" => "pay",
               "original_group_id" => "group",
               "recorded_cents" => 250,
               "held_cents" => 190,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 60,
               "charged_back_cents" => 0
             }
           } = get(conn, "/api/v1/payments/pay") |> json_response(200)

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             submit(conn, [%{reduce | "operation_id" => "stale", "amount_cents" => -1}])

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             submit(conn, [
               %{
                 reduce
                 | "operation_id" => "too-much",
                   "expected_revision" => 3,
                   "amount_cents" => 191
               }
             ])

    assert [%{"status" => "applied", "amount_cents" => 190, "revision" => 4}] =
             submit(conn, [
               %{
                 reduce
                 | "operation_id" => "reduce-rest",
                   "expected_revision" => 3,
                   "amount_cents" => 190
               }
             ])

    assert [%{"code" => "payment_not_reducible"}] =
             submit(conn, [
               %{
                 reduce
                 | "operation_id" => "nothing-left",
                   "expected_revision" => 4,
                   "amount_cents" => 1
               }
             ])

    assert %{"data" => %{"cash_reduced_cents" => 250, "cash_held_cents" => 0}} =
             get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "chargebacks reclassify converted cash, claw back fungible credit, and track shortfall", %{
    conn: conn
  } do
    submit(conn, [
      open("source-open", "source", "guest", %{
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 500},
          %{"room_id" => "b", "nightly_rate_cents" => 500}
        ]
      }),
      pay("pay-1", "source", 100),
      pay("pay-2", "source", 100),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("target-open", "target"),
      %{
        "operation_id" => "use-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-04-02",
        "group_id" => "target",
        "amount_cents" => 150
      }
    ])

    chargeback = %{
      "operation_id" => "charge-1",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-1",
      "expected_revision" => 4
    }

    assert [%{"charged_back_cents" => 100, "group_id" => "source", "revision" => 5}] =
             submit(conn, [chargeback])

    assert %{"data" => %{"revision" => 2}} =
             get(conn, "/api/v1/groups/target") |> json_response(200)

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 100,
               "cash_charged_back_cents" => 100,
               "credit_liability_cents" => 150,
               "credit_shortfall_cents" => 40
             }
           } = get(conn, "/api/v1/ledger?on=2027-04-02") |> json_response(200)

    assert %{"data" => %{"charged_back_cents" => 100, "converted_to_credit_cents" => 0}} =
             get(conn, "/api/v1/payments/pay-1") |> json_response(200)

    submit(conn, [
      %{
        "operation_id" => "return-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-03",
        "group_id" => "target"
      }
    ])

    assert %{"data" => %{"available_cents" => 110}} =
             get(conn, "/api/v1/guests/guest/credit?on=2027-04-03") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 110, "credit_shortfall_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2027-04-03") |> json_response(200)

    assert [%{"charged_back_cents" => 100, "revision" => 6}] =
             submit(conn, [
               %{
                 chargeback
                 | "operation_id" => "charge-2",
                   "payment_operation_id" => "pay-2",
                   "expected_revision" => 5
               }
             ])

    assert %{"data" => %{"credit_liability_cents" => 0, "cash_charged_back_cents" => 200}} =
             get(conn, "/api/v1/ledger?on=2027-04-03") |> json_response(200)
  end

  test "target validation, reconciliation errors, and new operations remain durably idempotent",
       %{conn: conn} do
    open_op = open("open", "group")
    submit(conn, [open_op, pay("rejected-pay", "missing", 1)])

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(conn, "/api/v1/payments/absent") |> json_response(404)

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             get(conn, "/api/v1/payments/open") |> json_response(422)

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             get(conn, "/api/v1/payments/rejected-pay") |> json_response(422)

    assert [
             %{"code" => "operation_not_found"},
             %{"code" => "payment_not_reducible"},
             %{"code" => "payment_not_chargeable"},
             %{"code" => "payment_not_reducible"}
           ] =
             submit(conn, [
               %{
                 "operation_id" => "reduce-missing",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "absent",
                 "amount_cents" => 1
               },
               %{
                 "operation_id" => "reduce-open",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "open",
                 "amount_cents" => 1
               },
               %{
                 "operation_id" => "charge-open",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "open"
               },
               %{
                 "operation_id" => "reduce-no-amount",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "rejected-pay"
               }
             ])

    pay_op = pay("pay", "group", 100)
    submit(conn, [pay_op])

    assert [%{"code" => "invalid_operation"}, %{"code" => "invalid_operation"}] =
             submit(conn, [
               %{
                 "operation_id" => "valid-pay-no-amount",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay"
               },
               %{
                 "operation_id" => "invalid-revision",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay",
                 "expected_revision" => "two"
               }
             ])

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "amount_cents" => 25
    }

    assert [first] = submit(conn, [reduction])
    submit(conn, [%{reduction | "operation_id" => "later", "amount_cents" => 10}])
    assert [^first] = submit(conn, [reduction])

    assert %{"data" => %{"amount_cents" => 100, "revision" => 2}} =
             get(conn, "/api/v1/operations/pay") |> json_response(200)
  end
end
