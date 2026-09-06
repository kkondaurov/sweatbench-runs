defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "room-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [
          %{"room_id" => "first", "nightly_rate_cents" => 100},
          %{"room_id" => "second", "nightly_rate_cents" => 200}
        ]
      },
      overrides
    )
  end

  test "allocates funding by room order and settles only selected rooms", %{conn: conn} do
    operations = [
      open_operation("block"),
      %{
        "operation_id" => "cash-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "block",
        "amount_cents" => 150
      },
      %{
        "operation_id" => "cancel-first",
        "type" => "cancel_rooms",
        "occurred_on" => "2027-01-01",
        "group_id" => "block",
        "room_ids" => ["first"]
      }
    ]

    result = submit(conn, operations) |> json_response(200) |> get_in(["results", Access.at(2)])

    assert result["cancelled_room_ids"] == ["first"]
    assert result["retained_cents"] == 100
    assert result["revision"] == 3

    assert get(conn, "/api/v1/groups/block")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "group_id" => "block",
             "guest_id" => "room-guest",
             "property_id" => "ams-canal",
             "revision" => 3,
             "booked_on" => "2027-01-01",
             "arrival_on" => "2027-03-01",
             "departure_on" => "2027-03-02",
             "rate_plan" => "advance_purchase",
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil,
             "status" => "active",
             "rooms" => [
               %{
                 "room_id" => "first",
                 "nightly_rate_cents" => 100,
                 "status" => "cancelled",
                 "deposit_due_cents" => 100,
                 "cash_paid_cents" => 100,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "second",
                 "nightly_rate_cents" => 200,
                 "status" => "active",
                 "deposit_due_cents" => 200,
                 "cash_paid_cents" => 50,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 200,
             "deposit_due_cents" => 200,
             "deposit_paid_cents" => 50,
             "cash_paid_cents" => 50,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 150
           }
  end

  test "reduces and charges back a durable payment without rewriting it", %{conn: conn} do
    assert submit(conn, [open_operation("payment")]) |> json_response(200)

    payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => "payment",
      "amount_cents" => 150
    }

    original = submit(conn, [payment]) |> json_response(200) |> get_in(["results", Access.at(0)])

    reduction = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "payment-1",
      "amount_cents" => 25,
      "expected_revision" => 2
    }

    assert get_in(submit(conn, [reduction]) |> json_response(200), [
             "results",
             Access.at(0),
             "revision"
           ]) == 3

    chargeback = %{
      "operation_id" => "chargeback-1",
      "type" => "charge_back_payment",
      "payment_operation_id" => "payment-1",
      "expected_revision" => 3
    }

    assert get_in(submit(conn, [chargeback]) |> json_response(200), ["results", Access.at(0)]) ==
             %{
               "operation_id" => "chargeback-1",
               "status" => "applied",
               "payment_operation_id" => "payment-1",
               "group_id" => "payment",
               "charged_back_cents" => 125,
               "outstanding_deposit_cents" => 300,
               "revision" => 4
             }

    assert json_response(get(conn, "/api/v1/operations/payment-1"), 200) == %{"data" => original}

    assert json_response(get(conn, "/api/v1/payments/payment-1"), 200) == %{
             "data" => %{
               "payment_operation_id" => "payment-1",
               "original_group_id" => "payment",
               "recorded_cents" => 150,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 25,
               "charged_back_cents" => 125
             }
           }
  end

  test "claws back converted credit and lets a later restoration absorb the shortfall", %{
    conn: conn
  } do
    source_operations = [
      open_operation("source", %{
        "guest_id" => "credit-guest",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ]

    assert Enum.all?(
             submit(conn, source_operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    target_operations = [
      open_operation("target", %{"guest_id" => "credit-guest"}),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => "target",
        "amount_cents" => 110
      }
    ]

    assert Enum.all?(
             submit(conn, target_operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    chargeback = %{
      "operation_id" => "source-chargeback",
      "type" => "charge_back_payment",
      "payment_operation_id" => "source-payment",
      "expected_revision" => 3
    }

    assert get_in(submit(conn, [chargeback]) |> json_response(200), [
             "results",
             Access.at(0),
             "charged_back_cents"
           ]) == 100

    assert get_in(json_response(get(conn, "/api/v1/ledger"), 200), [
             "data",
             "credit_shortfall_cents"
           ]) == 110

    assert get_in(json_response(get(conn, "/api/v1/ledger"), 200), [
             "data",
             "credit_liability_cents"
           ]) == 110

    cancel_target = %{
      "operation_id" => "target-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "target"
    }

    assert get_in(submit(conn, [cancel_target]) |> json_response(200), [
             "results",
             Access.at(0),
             "refunded_cents"
           ]) == 0

    assert get_in(json_response(get(conn, "/api/v1/ledger"), 200), [
             "data",
             "credit_shortfall_cents"
           ]) == 0

    assert get_in(json_response(get(conn, "/api/v1/ledger"), 200), [
             "data",
             "credit_liability_cents"
           ]) == 0
  end

  test "uses target-specific reduction and chargeback rejection codes", %{conn: conn} do
    assert submit(conn, [open_operation("errors")]) |> json_response(200)

    payment = %{
      "operation_id" => "errors-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => "errors",
      "amount_cents" => 100
    }

    assert submit(conn, [payment]) |> json_response(200)

    reduction = %{
      "operation_id" => "errors-reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "errors-payment",
      "amount_cents" => 100
    }

    assert get_in(submit(conn, [reduction]) |> json_response(200), [
             "results",
             Access.at(0),
             "status"
           ]) == "applied"

    assert get_in(
             submit(conn, [
               Map.merge(reduction, %{
                 "operation_id" => "errors-reduce-again",
                 "amount_cents" => 1
               })
             ])
             |> json_response(200),
             ["results", Access.at(0)]
           ) == %{
             "operation_id" => "errors-reduce-again",
             "status" => "rejected",
             "code" => "payment_not_reducible"
           }

    chargeback = %{
      "operation_id" => "errors-chargeback",
      "type" => "charge_back_payment",
      "payment_operation_id" => "errors-payment"
    }

    assert get_in(submit(conn, [chargeback]) |> json_response(200), ["results", Access.at(0)]) ==
             %{
               "operation_id" => "errors-chargeback",
               "status" => "rejected",
               "code" => "payment_not_chargeable"
             }

    assert get_in(
             submit(conn, [
               %{
                 "operation_id" => "missing-payment-target",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => 123,
                 "amount_cents" => 1
               }
             ])
             |> json_response(200),
             ["results", Access.at(0)]
           ) == %{
             "operation_id" => "missing-payment-target",
             "status" => "rejected",
             "code" => "operation_not_found"
           }
  end

  test "telescopes credit entitlements in durable funding order", %{conn: conn} do
    source = [
      open_operation("ordered-source", %{
        "guest_id" => "ordered-credit-guest",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "payment-one",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "ordered-source",
        "amount_cents" => 2
      },
      %{
        "operation_id" => "payment-two",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-01",
        "group_id" => "ordered-source",
        "amount_cents" => 3
      },
      %{
        "operation_id" => "ordered-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "ordered-source",
        "refund_method" => "hotel_credit"
      }
    ]

    assert Enum.all?(
             submit(conn, source) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    target = [
      open_operation("ordered-target", %{"guest_id" => "ordered-credit-guest"}),
      %{
        "operation_id" => "ordered-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => "ordered-target",
        "amount_cents" => 6
      }
    ]

    assert Enum.all?(
             submit(conn, target) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(
             submit(conn, [
               %{
                 "operation_id" => "chargeback-one",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "payment-one",
                 "expected_revision" => 4
               }
             ])
             |> json_response(200),
             ["results", Access.at(0), "charged_back_cents"]
           ) == 2

    assert get_in(json_response(get(conn, "/api/v1/ledger"), 200), [
             "data",
             "credit_shortfall_cents"
           ]) == 2
  end
end
