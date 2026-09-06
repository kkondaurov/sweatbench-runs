defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  test "funds rooms in order and atomically cancels selected rooms in original order", %{
    conn: conn
  } do
    operations = [
      open("group", "guest", ["r1", "r2", "r3"]),
      operation("pay", "record_cash_payment", %{"group_id" => "group", "amount_cents" => 1_500}),
      operation("cancel-selected", "cancel_rooms", %{
        "group_id" => "group",
        "room_ids" => ["r3", "r1"],
        "expected_revision" => 2
      }),
      operation("cancel-selected", "cancel_rooms", %{
        "group_id" => "group",
        "room_ids" => ["r3", "r1"],
        "expected_revision" => 2
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, cancellation, repeated]} = json_response(conn, 200)
    assert repeated == cancellation

    assert cancellation == %{
             "operation_id" => "cancel-selected",
             "status" => "applied",
             "group_id" => "group",
             "cancelled_room_ids" => ["r1", "r3"],
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    conn = get(build_conn(), ~p"/api/v1/groups/group")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["status"] == "active"
    assert data["lodging_total_cents"] == 5_000
    assert data["deposit_due_cents"] == 1_000
    assert data["cash_paid_cents"] == 500
    assert data["outstanding_deposit_cents"] == 500

    assert Enum.map(data["rooms"], &Map.take(&1, ["room_id", "status", "cash_paid_cents"])) == [
             %{"room_id" => "r1", "status" => "cancelled", "cash_paid_cents" => 0},
             %{"room_id" => "r2", "status" => "active", "cash_paid_cents" => 500},
             %{"room_id" => "r3", "status" => "cancelled", "cash_paid_cents" => 0}
           ]

    invalid =
      operation("duplicate-room", "cancel_rooms", %{
        "group_id" => "group",
        "room_ids" => ["r2", "r2"],
        "expected_revision" => 3
      })

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [invalid]})
    assert %{"results" => [%{"code" => "invalid_rooms"}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/group")
    assert %{"data" => %{"revision" => 3, "status" => "active"}} = json_response(conn, 200)
  end

  test "reductions compose, unwind only their payment in reverse fill order, and reconcile exactly",
       %{
         conn: conn
       } do
    operations = [
      open("reduce-group", "guest", ["r1", "r2"]),
      operation("pay-one", "record_cash_payment", %{
        "group_id" => "reduce-group",
        "amount_cents" => 1_500
      }),
      operation("pay-two", "record_cash_payment", %{
        "group_id" => "reduce-group",
        "amount_cents" => 500
      }),
      operation("reduce-one", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-one",
        "amount_cents" => 600,
        "expected_revision" => 3
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, _, reduction]} = json_response(conn, 200)
    assert reduction["outstanding_deposit_cents"] == 600
    assert reduction["revision"] == 4

    conn = get(build_conn(), ~p"/api/v1/groups/reduce-group")
    assert %{"data" => %{"rooms" => rooms}} = json_response(conn, 200)
    assert Enum.map(rooms, & &1["cash_paid_cents"]) == [900, 500]

    conn = get(build_conn(), ~p"/api/v1/payments/pay-one")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-one",
               "original_group_id" => "reduce-group",
               "recorded_cents" => 1_500,
               "held_cents" => 900,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 600,
               "charged_back_cents" => 0
             }
           }

    finish =
      operation("reduce-rest", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-one",
        "amount_cents" => 900,
        "expected_revision" => 4
      })

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [finish, finish]})
    assert %{"results" => [first, second]} = json_response(conn, 200)
    assert first == second
    assert first["outstanding_deposit_cents"] == 1_500

    conn = get(build_conn(), ~p"/api/v1/ledger")
    assert %{"data" => ledger} = json_response(conn, 200)
    assert ledger["cash_held_cents"] == 500
    assert ledger["cash_reduced_cents"] == 1_500
  end

  test "chargeback revokes converted credit, reports shortfall, and absorbs restoration", %{
    conn: conn
  } do
    operations = [
      open("source", "same-guest", ["source-room"]),
      operation("source-payment", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      operation("source-convert", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open("target", "same-guest", ["target-one", "target-two"], "open-target"),
      operation("use-credit", "apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 1_100
      }),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "source-payment",
        "expected_revision" => 3
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.at(results, 5)["charged_back_cents"] == 1_000
    assert Enum.at(results, 5)["revision"] == 4

    conn = get(build_conn(), ~p"/api/v1/groups/target")

    assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 1_100}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/ledger?on=2026-10-03")
    assert %{"data" => ledger} = json_response(conn, 200)
    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 1_000
    assert ledger["credit_liability_cents"] == 1_100
    assert ledger["credit_shortfall_cents"] == 1_100

    cancel_target =
      operation("cancel-target", "cancel_group", %{
        "group_id" => "target",
        "expected_revision" => 2
      })

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [cancel_target]})
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/ledger?on=2026-10-03")
    assert %{"data" => ledger} = json_response(conn, 200)
    assert ledger["credit_liability_cents"] == 0
    assert ledger["credit_shortfall_cents"] == 0
  end

  test "selected-room hotel credit computes one combined bonus", %{conn: conn} do
    operations = [
      open("bonus", "guest", ["r1", "r2"]),
      operation("tiny-payment", "record_cash_payment", %{
        "group_id" => "bonus",
        "amount_cents" => 10
      }),
      operation("convert-both", "cancel_rooms", %{
        "group_id" => "bonus",
        "room_ids" => ["r1", "r2"],
        "refund_method" => "hotel_credit"
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, result]} = json_response(conn, 200)
    assert result["credit_issued_cents"] == 11
    assert result["status"] == "applied"
  end

  test "chargeback reclassifies a payment split between refunded and held cash", %{conn: conn} do
    operations = [
      open("mixed", "guest", ["r1", "r2"]),
      operation("mixed-payment", "record_cash_payment", %{
        "group_id" => "mixed",
        "amount_cents" => 1_500
      }),
      operation("refund-first", "cancel_rooms", %{
        "group_id" => "mixed",
        "room_ids" => ["r1"]
      }),
      operation("charge-mixed", "charge_back_payment", %{
        "payment_operation_id" => "mixed-payment",
        "expected_revision" => 3
      }),
      operation("charge-mixed", "charge_back_payment", %{
        "payment_operation_id" => "mixed-payment",
        "expected_revision" => 3
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => [_, _, _, chargeback, repeated]} = json_response(conn, 200)
    assert repeated == chargeback
    assert chargeback["charged_back_cents"] == 1_500
    assert chargeback["outstanding_deposit_cents"] == 1_000

    conn = get(build_conn(), ~p"/api/v1/payments/mixed-payment")
    assert %{"data" => payment} = json_response(conn, 200)
    assert payment["refunded_cents"] == 0
    assert payment["held_cents"] == 0
    assert payment["charged_back_cents"] == 1_500

    conn = get(build_conn(), ~p"/api/v1/ledger")
    assert %{"data" => ledger} = json_response(conn, 200)
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 1_500
  end

  test "payment reads distinguish missing and non-payment operations", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/payments/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [open("not-payment", "guest", ["r1"])]
      })

    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/open-not-payment")
    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "targeted-payment errors and stale revision precedence are stable", %{conn: conn} do
    operations = [
      open("errors", "guest", ["r1"]),
      operation("small-payment", "record_cash_payment", %{
        "group_id" => "errors",
        "amount_cents" => 100
      }),
      operation("stale-invalid", "reduce_cash_payment", %{
        "payment_operation_id" => "small-payment",
        "amount_cents" => 0,
        "expected_revision" => 1
      }),
      operation("invalid-reduction", "reduce_cash_payment", %{
        "payment_operation_id" => "small-payment",
        "amount_cents" => 0,
        "expected_revision" => 2
      }),
      operation("large-reduction", "reduce_cash_payment", %{
        "payment_operation_id" => "small-payment",
        "amount_cents" => 101,
        "expected_revision" => 2
      }),
      operation("missing-target", "reduce_cash_payment", %{
        "payment_operation_id" => "missing",
        "amount_cents" => 1
      }),
      operation("not-payment", "charge_back_payment", %{
        "payment_operation_id" => "open-errors"
      }),
      operation("malformed-target", "charge_back_payment", %{
        "payment_operation_id" => 17
      })
    ]

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.map(Enum.drop(results, 2), & &1["code"]) == [
             "stale_revision",
             "invalid_amount",
             "reduction_exceeds_held_cash",
             "operation_not_found",
             "payment_not_chargeable",
             "invalid_operation"
           ]

    assert Enum.at(results, 2)["actual_revision"] == 2
  end

  defp open(group_id, guest_id, room_ids, operation_id \\ nil) do
    %{
      "operation_id" => operation_id || "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => Enum.map(room_ids, &%{"room_id" => &1, "nightly_rate_cents" => 5_000})
    }
  end

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{"operation_id" => operation_id, "type" => type, "occurred_on" => "2026-10-03"},
      fields
    )
  end
end
