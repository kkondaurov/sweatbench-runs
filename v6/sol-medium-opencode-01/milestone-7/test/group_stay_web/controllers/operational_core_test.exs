defmodule GroupStayWeb.OperationalCoreTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
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
      },
      overrides
    )
  end

  defp submit(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{operations: operations})

  test "opens a group and returns its ordered read model", %{conn: conn} do
    conn = submit(conn, [open_operation()])

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = json_response(conn, 200)

    conn = get(recycle(conn), ~p"/api/v1/groups/group-81")

    assert %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           } = json_response(conn, 200)
  end

  test "processes operations in order and continues after rejection", %{conn: conn} do
    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 5_000,
      "expected_revision" => 1
    }

    excessive = %{
      payment
      | "operation_id" => "pay-2",
        "amount_cents" => 20_000,
        "expected_revision" => 2
    }

    later = %{
      payment
      | "operation_id" => "pay-3",
        "amount_cents" => 1_000,
        "expected_revision" => 2
    }

    conn = submit(conn, [open_operation(), payment, excessive, later])

    assert %{"results" => [opened, paid, rejected, paid_later]} = json_response(conn, 200)
    assert opened["revision"] == 1

    assert paid == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_500,
             "revision" => 2
           }

    assert rejected == %{
             "operation_id" => "pay-2",
             "status" => "rejected",
             "code" => "payment_exceeds_outstanding",
             "group_id" => "group-81"
           }

    assert paid_later["revision"] == 3
    assert paid_later["outstanding_deposit_cents"] == 13_500
  end

  test "rounds each flexible room deposit separately", %{conn: conn} do
    operation =
      open_operation(%{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 3},
          %{"room_id" => "room-b", "nightly_rate_cents" => 3}
        ]
      })

    conn = submit(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["deposit_due_cents"] == 2
  end

  test "validates payment amount and group existence", %{conn: conn} do
    missing = %{
      "operation_id" => "missing-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "missing",
      "amount_cents" => -1
    }

    invalid = %{missing | "operation_id" => "invalid-payment", "group_id" => "group-81"}
    conn = submit(conn, [open_operation(), missing, invalid])
    assert %{"results" => [_, missing_result, invalid_result]} = json_response(conn, 200)
    assert missing_result["code"] == "group_not_found"
    assert invalid_result["code"] == "invalid_amount"
  end

  test "rejects stale revisions before other domain validation", %{conn: conn} do
    stale = %{
      "operation_id" => "stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => -10,
      "expected_revision" => 9
    }

    conn = submit(conn, [open_operation(), stale])

    assert %{"results" => [_, result]} = json_response(conn, 200)

    assert result == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 9,
             "actual_revision" => 1
           }
  end

  test "reschedules without changing duration or price", %{conn: conn} do
    reschedule = %{
      "operation_id" => "move-1",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "new_arrival_on" => "2027-01-05"
    }

    conn = submit(conn, [open_operation(), reschedule])

    assert %{"results" => [_, result]} = json_response(conn, 200)
    assert result["new_arrival_on"] == "2027-01-05"
    assert result["new_departure_on"] == "2027-01-08"
    assert result["revision"] == 2
  end

  test "reschedule resolves existence and revision before validating the new stay", %{conn: conn} do
    missing = %{
      "operation_id" => "missing-move",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "missing",
      "new_arrival_on" => 123
    }

    stale =
      Map.merge(missing, %{
        "operation_id" => "stale-move",
        "group_id" => "group-81",
        "expected_revision" => 9
      })

    invalid = %{missing | "operation_id" => "invalid-move", "group_id" => "group-81"}
    conn = submit(conn, [open_operation(), missing, stale, invalid])

    assert %{"results" => [_, missing_result, stale_result, invalid_result]} =
             json_response(conn, 200)

    assert missing_result["code"] == "group_not_found"
    assert stale_result["code"] == "stale_revision"
    assert invalid_result["code"] == "invalid_stay"
  end

  test "refunds flexible cash at the fourteen-day boundary", %{conn: conn} do
    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }

    cancellation = %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => "group-81"
    }

    conn = submit(conn, [open_operation(), payment, cancellation])

    assert %{"results" => [_, _, result]} = json_response(conn, 200)
    assert result["refunded_cents"] == 5_000
    assert result["retained_cents"] == 0
    assert result["revision"] == 3

    conn = get(recycle(conn), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "retains late flexible cash and advance-purchase cash", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-flex",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "cancel-flex",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81"
      },
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance-1",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 100}]
      }),
      %{
        "operation_id" => "pay-advance",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "advance-1",
        "amount_cents" => 300
      },
      %{
        "operation_id" => "cancel-advance",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "advance-1"
      }
    ]

    conn = submit(conn, operations)
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.at(results, 2)["retained_cents"] == 1_000
    assert Enum.at(results, 5)["retained_cents"] == 300

    conn = get(recycle(conn), ~p"/api/v1/ledger")
    assert get_in(json_response(conn, 200), ["data", "cash_retained_cents"]) == 1_300
  end

  test "validates opening rules without creating partial groups", %{conn: conn} do
    operations = [
      open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "bad-rooms", "rooms" => []}),
      open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "mystery"}),
      open_operation(%{
        "operation_id" => "duplicate-room",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 2}
        ]
      })
    ]

    conn = submit(conn, operations)

    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.map(results, & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan",
             "invalid_rooms"
           ]

    conn = get(recycle(conn), ~p"/api/v1/groups/group-81")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "rejects values that cannot be represented without aborting the batch", %{conn: conn} do
    malformed_date = open_operation(%{"operation_id" => "bad-date", "occurred_on" => 123})

    oversized =
      open_operation(%{
        "operation_id" => "oversized",
        "rooms" => [
          %{"room_id" => "huge", "nightly_rate_cents" => 9_223_372_036_854_775_807}
        ]
      })

    conn = submit(conn, [malformed_date, oversized, open_operation()])
    assert %{"results" => [bad_date, too_large, applied]} = json_response(conn, 200)
    assert bad_date["code"] == "invalid_operation"
    assert too_large["code"] == "invalid_rooms"
    assert applied["status"] == "applied"
  end

  test "rejects duplicate groups and operations against inactive groups", %{conn: conn} do
    cancellation = %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-01",
      "group_id" => "group-81"
    }

    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-02",
      "group_id" => "group-81",
      "amount_cents" => 1
    }

    conn =
      submit(conn, [
        open_operation(),
        open_operation(%{"operation_id" => "duplicate"}),
        cancellation,
        payment
      ])

    assert %{"results" => [_, duplicate, _, inactive]} = json_response(conn, 200)
    assert duplicate["code"] == "group_already_exists"
    assert inactive["code"] == "group_not_active"
  end

  test "returns invalid batch and invalid operation errors", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/partner-batches", %{"wrong" => []})
    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

    conn = submit(recycle(conn), [%{"operation_id" => "unknown", "type" => "other"}, "bad"])
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.map(results, & &1["code"]) == ["invalid_operation", "invalid_operation"]
  end

  test "reports an empty ledger and a missing group", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }

    conn = get(recycle(conn), ~p"/api/v1/groups/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end
end
