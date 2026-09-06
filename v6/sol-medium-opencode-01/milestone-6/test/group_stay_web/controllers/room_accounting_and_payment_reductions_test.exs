defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "hotel-1",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 5_000},
          %{"room_id" => "b", "nightly_rate_cents" => 10_000},
          %{"room_id" => "c", "nightly_rate_cents" => 15_000}
        ]
      },
      overrides
    )
  end

  defp pay(group_id, operation_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp submit(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{operations: operations})

  defp group(conn, group_id),
    do:
      get(recycle(conn), "/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")

  defp statement(conn, payment_id),
    do:
      get(recycle(conn), "/api/v1/payments/#{payment_id}")
      |> json_response(200)
      |> Map.fetch!("data")

  test "exposes room accounting and fills rooms in funding-operation order", %{conn: conn} do
    conn =
      submit(conn, [
        open("g"),
        pay("g", "later-date", 1_500, %{"occurred_on" => "2027-01-01"}),
        pay("g", "earlier-date", 2_000, %{"occurred_on" => "2026-01-01"})
      ])

    data = group(conn, "g")

    assert data["rooms"] == [
             %{
               "room_id" => "a",
               "nightly_rate_cents" => 5_000,
               "status" => "active",
               "deposit_due_cents" => 1_000,
               "cash_paid_cents" => 1_000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "b",
               "nightly_rate_cents" => 10_000,
               "status" => "active",
               "deposit_due_cents" => 2_000,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "c",
               "nightly_rate_cents" => 15_000,
               "status" => "active",
               "deposit_due_cents" => 3_000,
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 0
             }
           ]

    assert data["lodging_total_cents"] == 30_000
    assert data["deposit_due_cents"] == 6_000
    assert data["outstanding_deposit_cents"] == 2_500
  end

  test "cancels selected rooms atomically in original order and only reports active totals", %{
    conn: conn
  } do
    cancellation = %{
      "operation_id" => "cancel-rooms",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-01",
      "group_id" => "g",
      "room_ids" => ["c", "a"]
    }

    invalid = %{cancellation | "operation_id" => "invalid", "room_ids" => ["b", "missing"]}
    conn = submit(conn, [open("g"), pay("g", "pay", 3_500), invalid, cancellation])
    assert %{"results" => [_, _, rejected, result]} = json_response(conn, 200)
    assert rejected["code"] == "invalid_rooms"
    assert result["cancelled_room_ids"] == ["a", "c"]
    assert result["refunded_cents"] == 1_500

    data = group(conn, "g")
    assert data["status"] == "active"
    assert data["revision"] == 3
    assert data["lodging_total_cents"] == 10_000
    assert data["deposit_due_cents"] == 2_000
    assert data["cash_paid_cents"] == 2_000
    assert Enum.map(data["rooms"], & &1["status"]) == ["cancelled", "active", "cancelled"]
    assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [0, 2_000, 0]

    duplicate = %{cancellation | "operation_id" => "duplicate", "room_ids" => ["b", "b"]}
    already = %{cancellation | "operation_id" => "already", "room_ids" => ["a"]}
    conn = submit(recycle(conn), [duplicate, already])
    assert %{"results" => [duplicate_result, already_result]} = json_response(conn, 200)
    assert duplicate_result["code"] == "invalid_rooms"
    assert already_result["code"] == "invalid_rooms"
  end

  test "computes one credit bonus for selected rooms and full cancellation settles the rest", %{
    conn: conn
  } do
    tiny =
      open("tiny", %{
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 25},
          %{"room_id" => "b", "nightly_rate_cents" => 25},
          %{"room_id" => "c", "nightly_rate_cents" => 25}
        ]
      })

    partial = %{
      "operation_id" => "partial",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-01",
      "group_id" => "tiny",
      "room_ids" => ["a", "b"],
      "refund_method" => "hotel_credit"
    }

    rest = %{
      "operation_id" => "rest",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "tiny"
    }

    conn = submit(conn, [tiny, pay("tiny", "tiny-pay", 15), partial, rest])
    assert %{"results" => [_, _, partial_result, rest_result]} = json_response(conn, 200)
    assert partial_result["credit_issued_cents"] == 11
    assert partial_result["refunded_cents"] == 0
    assert rest_result["refunded_cents"] == 5

    data = group(conn, "tiny")
    assert data["status"] == "cancelled"
    assert data["deposit_due_cents"] == 0
    assert data["deposit_paid_cents"] == 0
    assert Enum.all?(data["rooms"], &(&1["status"] == "cancelled"))
    assert Enum.all?(data["rooms"], &(&1["cash_paid_cents"] == 0))

    payment = statement(conn, "tiny-pay")
    assert payment["converted_to_credit_cents"] == 10
    assert payment["refunded_cents"] == 5
  end

  test "reduces only target held cash in reverse fill order and preserves original result", %{
    conn: conn
  } do
    first = pay("g", "pay-1", 2_500)
    second = pay("g", "pay-2", 1_500)

    reduction = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-03",
      "payment_operation_id" => "pay-1",
      "amount_cents" => 1_200,
      "expected_revision" => 3
    }

    conn = submit(conn, [open("g"), first, second, reduction, first, reduction])

    assert %{"results" => [_, original, _, reduced, replayed_payment, replayed_reduction]} =
             json_response(conn, 200)

    assert original == replayed_payment
    assert reduced == replayed_reduction
    assert reduced["outstanding_deposit_cents"] == 3_200
    assert reduced["revision"] == 4

    data = group(conn, "g")
    assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [1_000, 800, 1_000]

    assert statement(conn, "pay-1") == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "g",
             "recorded_cents" => 2_500,
             "held_cents" => 1_300,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 1_200,
             "charged_back_cents" => 0
           }

    assert statement(conn, "pay-2")["held_cents"] == 1_500
    ledger = get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 2_800
    assert ledger["cash_reduced_cents"] == 1_200
  end

  test "uses precise reduction and reconciliation rejection contracts", %{conn: conn} do
    rejected_payment = pay("missing", "rejected-pay", 10)
    conn = submit(conn, [open("g"), pay("g", "pay", 100), rejected_payment])

    operations = [
      %{
        "operation_id" => "zero",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-03",
        "payment_operation_id" => "pay",
        "amount_cents" => 0
      },
      %{
        "operation_id" => "too-much",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-03",
        "payment_operation_id" => "pay",
        "amount_cents" => 101
      },
      %{
        "operation_id" => "missing",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-03",
        "payment_operation_id" => "no-such-payment",
        "amount_cents" => 1
      },
      %{
        "operation_id" => "wrong-kind",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-03",
        "payment_operation_id" => "open-g",
        "amount_cents" => 1
      },
      %{
        "operation_id" => "rejected-kind",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-03",
        "payment_operation_id" => "rejected-pay",
        "amount_cents" => 1
      }
    ]

    conn = submit(recycle(conn), operations)
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.map(results, & &1["code"]) == [
             "invalid_amount",
             "reduction_exceeds_held_cash",
             "operation_not_found",
             "payment_not_reducible",
             "payment_not_reducible"
           ]

    assert json_response(get(recycle(conn), "/api/v1/payments/no-such-payment"), 404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    assert json_response(get(recycle(conn), "/api/v1/payments/open-g"), 422) ==
             %{"error" => %{"code" => "payment_not_reconcilable"}}

    assert json_response(get(recycle(conn), "/api/v1/payments/rejected-pay"), 422) ==
             %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "checks the derived payment group revision before reduction validation", %{conn: conn} do
    stale = %{
      "operation_id" => "stale-reduction",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-03",
      "payment_operation_id" => "pay",
      "amount_cents" => -1,
      "expected_revision" => 99
    }

    conn = submit(conn, [open("g"), pay("g", "pay", 100), stale])
    result = get_in(json_response(conn, 200), ["results", Access.at(2)])

    assert result == %{
             "operation_id" => "stale-reduction",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "g",
             "expected_revision" => 99,
             "actual_revision" => 2
           }

    assert statement(conn, "pay")["held_cents"] == 100
  end

  test "charges back held, refunded, and retained cash", %{conn: conn} do
    chargeback = fn operation_id, payment_id ->
      %{
        "operation_id" => operation_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2027-01-02",
        "payment_operation_id" => payment_id
      }
    end

    refundable_cancel = %{
      "operation_id" => "cancel-refund",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "refund"
    }

    retained_cancel = %{
      "operation_id" => "cancel-retained",
      "type" => "cancel_group",
      "occurred_on" => "2027-03-01",
      "group_id" => "retained"
    }

    conn =
      submit(conn, [
        open("held"),
        pay("held", "pay-held", 1_500),
        open("refund"),
        pay("refund", "pay-refund", 1_000),
        refundable_cancel,
        open("retained"),
        pay("retained", "pay-retained", 500),
        retained_cancel,
        chargeback.("cb-held", "pay-held"),
        chargeback.("cb-refund", "pay-refund"),
        chargeback.("cb-retained", "pay-retained")
      ])

    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.take(Enum.reverse(results), 3) |> Enum.all?(&(&1["status"] == "applied"))
    assert group(conn, "held")["outstanding_deposit_cents"] == 6_000
    assert statement(conn, "pay-held")["charged_back_cents"] == 1_500
    assert statement(conn, "pay-refund")["charged_back_cents"] == 1_000
    assert statement(conn, "pay-retained")["charged_back_cents"] == 500

    ledger = get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 3_000

    conn = submit(recycle(conn), [chargeback.("again", "pay-held")])

    assert get_in(json_response(conn, 200), ["results", Access.at(0), "code"]) ==
             "payment_not_chargeable"
  end

  test "claws converted entitlement back from available and applied credit", %{conn: conn} do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "source",
      "refund_method" => "hotel_credit"
    }

    apply_credit = %{
      "operation_id" => "apply-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-02",
      "group_id" => "target",
      "amount_cents" => 1_000
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-03",
      "payment_operation_id" => "pay-source"
    }

    conn =
      submit(conn, [
        open("source"),
        pay("source", "pay-source", 1_000),
        convert,
        open("target", %{"occurred_on" => "2027-01-01"}),
        apply_credit,
        chargeback
      ])

    assert get_in(json_response(conn, 200), ["results", Access.at(5), "charged_back_cents"]) ==
             1_000

    assert statement(conn, "pay-source")["converted_to_credit_cents"] == 0
    assert statement(conn, "pay-source")["charged_back_cents"] == 1_000

    ledger =
      get(recycle(conn), ~p"/api/v1/ledger?on=2027-01-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 1_000
    assert ledger["credit_shortfall_cents"] == 1_000
    assert ledger["cash_converted_to_credit_cents"] == 0

    cancel_target = %{
      "operation_id" => "cancel-target",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-04",
      "group_id" => "target"
    }

    conn = submit(recycle(conn), [cancel_target])
    ledger = get(recycle(conn), ~p"/api/v1/ledger?on=2027-01-04") |> json_response(200)
    assert ledger["data"]["credit_shortfall_cents"] == 0
    assert ledger["data"]["credit_liability_cents"] == 0

    assert get_in(
             json_response(
               get(recycle(conn), "/api/v1/guests/guest-1/credit?on=2027-01-04"),
               200
             ),
             ["data", "available_cents"]
           ) == 0
  end
end
