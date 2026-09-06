defmodule GroupStayWeb.OperationsControllerTest do
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

  defp operation(type, id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "rejects a body without an operations array", %{conn: conn} do
    response = conn |> post("/api/v1/partner-batches", %{}) |> json_response(422)
    assert response == %{"error" => %{"code" => "invalid_batch"}}

    response =
      conn |> post("/api/v1/partner-batches", %{"operations" => %{}}) |> json_response(422)

    assert response == %{"error" => %{"code" => "invalid_batch"}}
  end

  test "opens and reads a group with calculated totals and original room order", %{conn: conn} do
    assert submit(conn, [open_operation()]) == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    data = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert data == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "revision" => 1,
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }
  end

  test "rounds each flexible room deposit separately and fully deposits advance purchases", %{
    conn: conn
  } do
    rounded =
      open_operation(%{
        "group_id" => "rounded",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 2},
          %{"room_id" => "b", "nightly_rate_cents" => 3}
        ],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11"
      })

    advance =
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 10_001}],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12"
      })

    assert [rounded_result, advance_result] = submit(conn, [rounded, advance])
    assert rounded_result["deposit_due_cents"] == 1
    assert advance_result["deposit_due_cents"] == 20_002
  end

  test "processes operations in order and a rejection does not stop or undo the batch", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      operation("record_cash_payment", "pay-too-much", %{"amount_cents" => 20_000}),
      operation("record_cash_payment", "pay-1", %{
        "amount_cents" => 5_000,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", "pay-stale", %{
        "amount_cents" => -1,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", "pay-2", %{
        "amount_cents" => 14_500,
        "expected_revision" => 2
      })
    ]

    assert [opened, excessive, paid, stale, paid_rest] = submit(conn, operations)
    assert opened["status"] == "applied"
    assert excessive["code"] == "payment_exceeds_outstanding"

    assert paid == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_500,
             "revision" => 2
           }

    assert stale == %{
             "operation_id" => "pay-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert paid_rest["revision"] == 3
    assert paid_rest["outstanding_deposit_cents"] == 0

    ledger = conn |> get("/api/v1/ledger") |> json_response(200)

    assert ledger == %{
             "data" => %{
               "cash_held_cents" => 19_500,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "reschedules by preserving stay length and validates against the operation date", %{
    conn: conn
  } do
    assert [_, moved, invalid] =
             submit(conn, [
               open_operation(),
               operation("reschedule_group", "move-1", %{
                 "new_arrival_on" => "2027-01-20",
                 "expected_revision" => 1
               }),
               operation("reschedule_group", "move-2", %{"new_arrival_on" => "2026-10-04"})
             ])

    assert moved == %{
             "operation_id" => "move-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2027-01-20",
             "new_departure_on" => "2027-01-23",
             "revision" => 2
           }

    assert invalid["code"] == "invalid_stay"

    data = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert data["revision"] == 2
    assert data["lodging_total_cents"] == 97_500
  end

  test "refunds flexible cash at the 14 day boundary and updates ledger totals", %{conn: conn} do
    assert [_, _, cancelled] =
             submit(conn, [
               open_operation(),
               operation("record_cash_payment", "pay", %{"amount_cents" => 10_000}),
               operation("cancel_group", "cancel", %{
                 "occurred_on" => "2026-11-26",
                 "expected_revision" => 2
               })
             ])

    assert cancelled == %{
             "operation_id" => "cancel",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 10_000,
             "retained_cents" => 0,
             "revision" => 3
           }

    assert conn |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0
             }
           }

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["outstanding_deposit_cents"] == 0

    assert [inactive] =
             submit(conn, [operation("record_cash_payment", "late-pay", %{"amount_cents" => 1})])

    assert inactive["code"] == "group_not_active"
    assert inactive["actual_revision"] == nil
  end

  test "retains late flexible and all advance-purchase cash", %{conn: conn} do
    late = open_operation(%{"group_id" => "late"})

    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    operations = [
      late,
      operation("record_cash_payment", "pay-late", %{"group_id" => "late", "amount_cents" => 100}),
      operation("cancel_group", "cancel-late", %{
        "group_id" => "late",
        "occurred_on" => "2026-11-27"
      }),
      advance,
      operation("record_cash_payment", "pay-advance", %{
        "group_id" => "advance",
        "amount_cents" => 200
      }),
      operation("cancel_group", "cancel-advance", %{
        "group_id" => "advance",
        "occurred_on" => "2026-10-04"
      })
    ]

    results = submit(conn, operations)
    assert Enum.at(results, 2)["retained_cents"] == 100
    assert Enum.at(results, 5)["retained_cents"] == 200

    assert conn |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 300
             }
           }
  end

  test "rejects invalid opens without creating partial records", %{conn: conn} do
    invalid_operations = [
      open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "bad-rooms", "rooms" => []}),
      open_operation(%{
        "operation_id" => "duplicate-rooms",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 2}
        ]
      }),
      open_operation(%{"operation_id" => "bad-rate", "rate_plan" => "mystery"})
    ]

    assert Enum.map(submit(conn, invalid_operations), & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rooms",
             "invalid_rate_plan"
           ]

    assert conn |> get("/api/v1/groups/group-81") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "uses stable errors for duplicates, missing groups, and malformed operations", %{
    conn: conn
  } do
    assert [_, duplicate, missing, unknown, malformed, invalid_id] =
             submit(conn, [
               open_operation(),
               open_operation(%{"operation_id" => "duplicate"}),
               operation("cancel_group", "missing", %{
                 "group_id" => "absent",
                 "expected_revision" => 99
               }),
               operation("unknown", "unknown"),
               %{"operation_id" => "malformed", "type" => "record_cash_payment"},
               operation("cancel_group", "invalid-id", %{"group_id" => 123})
             ])

    assert duplicate["code"] == "group_already_exists"
    assert missing["code"] == "group_not_found"
    assert unknown["code"] == "invalid_operation"
    assert malformed["code"] == "invalid_operation"
    assert invalid_id["code"] == "invalid_operation"
  end

  test "returns an empty ledger and a stable missing-group response", %{conn: conn} do
    assert conn |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end
end
