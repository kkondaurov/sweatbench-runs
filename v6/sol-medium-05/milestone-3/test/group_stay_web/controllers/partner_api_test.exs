defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
        ]
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

  test "rejects invalid batches but accepts an empty operation array", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn
             |> post("/api/v1/partner-batches", %{})
             |> json_response(422)

    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => nil})
             |> json_response(422)

    assert [] == submit(conn, [])
  end

  test "opens and reads a flexible group with per-room rounding and original room order", %{
    conn: conn
  } do
    assert [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_502,
               "revision" => 1
             }
           ] = submit(conn, [open_operation()])

    assert %{
             "data" => %{
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
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
               ],
               "lodging_total_cents" => 97_509,
               "deposit_due_cents" => 19_502,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_502
             }
           } =
             conn
             |> get("/api/v1/groups/group-81")
             |> json_response(200)
  end

  test "advance purchase requires the full lodging amount and zero rates remain valid", %{
    conn: conn
  } do
    operation =
      open_operation(%{
        "group_id" => "advance",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "comp", "nightly_rate_cents" => 0}]
      })

    assert [%{"status" => "applied", "deposit_due_cents" => 0}] = submit(conn, [operation])
  end

  test "rejects each open-group domain error without creating a partial group", %{conn: conn} do
    operations = [
      open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "strict"}),
      open_operation(%{
        "operation_id" => "bad-rooms",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 100},
          %{"room_id" => "same", "nightly_rate_cents" => 200}
        ]
      }),
      Map.delete(open_operation(%{"operation_id" => "missing"}), "property_id")
    ]

    assert [
             %{"operation_id" => "bad-stay", "code" => "invalid_stay"},
             %{"operation_id" => "bad-plan", "code" => "invalid_rate_plan"},
             %{"operation_id" => "bad-rooms", "code" => "invalid_rooms"},
             %{"operation_id" => "missing", "code" => "invalid_operation"}
           ] = submit(conn, operations)

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(404)
  end

  test "malformed nested rooms reject without aborting the rest of the batch", %{conn: conn} do
    assert [
             %{"operation_id" => "malformed-room", "code" => "invalid_rooms"},
             %{"operation_id" => "too-large", "code" => "invalid_rooms"},
             %{"operation_id" => "open-1", "status" => "applied"}
           ] =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "malformed-room",
                 "rooms" => ["not-a-room"]
               }),
               open_operation(%{
                 "operation_id" => "too-large",
                 "rooms" => [
                   %{"room_id" => "huge", "nightly_rate_cents" => 9_223_372_036_854_775_807}
                 ]
               }),
               open_operation()
             ])
  end

  test "batch processing is ordered, continues after rejections, and updates revisions once", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 2_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 20_000,
        "expected_revision" => 2
      },
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20",
        "expected_revision" => 2
      }
    ]

    assert [
             %{"status" => "applied", "revision" => 1},
             %{
               "status" => "applied",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 17_502,
               "revision" => 2
             },
             %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
             %{
               "status" => "applied",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 3
             }
           ] = submit(conn, operations)
  end

  test "stale revisions win over domain errors and leave group and ledger unchanged", %{
    conn: conn
  } do
    submit(conn, [open_operation()])

    assert [
             %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 1
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "stale",
                 "type" => "record_cash_payment",
                 "occurred_on" => "not-a-date",
                 "group_id" => "group-81",
                 "amount_cents" => -1,
                 "expected_revision" => 9
               }
             ])

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "missing groups are resolved before revisions and payment validation", %{conn: conn} do
    assert [
             %{
               "operation_id" => "missing",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "absent"
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "missing",
                 "type" => "record_cash_payment",
                 "occurred_on" => "bad",
                 "group_id" => "absent",
                 "amount_cents" => -1,
                 "expected_revision" => 44
               }
             ])
  end

  test "a non-positive integer expected revision is a stale mismatch", %{conn: conn} do
    submit(conn, [open_operation()])

    assert [
             %{
               "code" => "stale_revision",
               "expected_revision" => 0,
               "actual_revision" => 1
             }
           ] =
             submit(conn, [
               Map.put(payment("zero-revision", "group-81", 1), "expected_revision", 0)
             ])
  end

  test "a valid no-op reschedule increments revision", %{conn: conn} do
    submit(conn, [open_operation()])

    assert [
             %{
               "status" => "applied",
               "new_arrival_on" => "2026-12-10",
               "new_departure_on" => "2026-12-13",
               "revision" => 2
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "same",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-12-09",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-10"
               }
             ])
  end

  test "invalid amounts and reschedule dates do not revise, while an exact final payment applies",
       %{
         conn: conn
       } do
    submit(conn, [open_operation()])

    assert [
             %{"code" => "invalid_amount"},
             %{"code" => "invalid_stay"},
             %{
               "status" => "applied",
               "amount_cents" => 19_502,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             },
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             submit(conn, [
               payment("zero", "group-81", 0),
               %{
                 "operation_id" => "bad-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-11-01"
               },
               payment("full", "group-81", 19_502),
               payment("after-full", "group-81", 1)
             ])

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 19_502}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "flexible cancellation at fourteen days refunds held cash and closes outstanding", %{
    conn: conn
  } do
    submit(conn, [
      open_operation(),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      }
    ])

    assert %{"data" => %{"cash_held_cents" => 4_000}} =
             conn |> get("/api/v1/ledger") |> json_response(200)

    assert [
             %{
               "status" => "applied",
               "refunded_cents" => 4_000,
               "retained_cents" => 0,
               "revision" => 3
             }
           ] =
             submit(conn, [
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group-81",
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 3,
               "deposit_due_cents" => 19_502,
               "deposit_paid_cents" => 4_000,
               "outstanding_deposit_cents" => 0
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 4_000,
               "cash_retained_cents" => 0
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)

    assert [%{"code" => "group_not_active"}] =
             submit(conn, [
               %{
                 "operation_id" => "again",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-27",
                 "group_id" => "group-81"
               }
             ])
  end

  test "late flexible and advance-purchase cancellations retain cash", %{conn: conn} do
    flexible = open_operation(%{"group_id" => "flex"})

    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    operations = [
      flexible,
      advance,
      payment("pay-flex", "flex", 1_000),
      payment("pay-advance", "advance", 2_000),
      cancellation("cancel-flex", "flex", "2026-11-27"),
      cancellation("cancel-advance", "advance", "2026-10-10")
    ]

    assert [_, _, _, _, %{"retained_cents" => 1_000}, %{"retained_cents" => 2_000}] =
             submit(conn, operations)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3_000
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "all mutations of a cancelled group reject without changing its revision", %{conn: conn} do
    submit(conn, [open_operation(), cancellation("cancel", "group-81", "2026-11-27")])

    assert [
             %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2},
             %{"code" => "group_not_active"},
             %{"code" => "group_not_active"},
             %{"code" => "group_not_active"}
           ] =
             submit(conn, [
               Map.put(payment("stale-pay", "group-81", -1), "expected_revision", 1),
               payment("late-pay", "group-81", 1),
               %{
                 "operation_id" => "late-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-28",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-01-01"
               },
               cancellation("again", "group-81", "2026-11-28")
             ])

    assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "unknown and malformed operations reject individually and processing continues", %{
    conn: conn
  } do
    assert [
             %{"operation_id" => "wat", "status" => "rejected", "code" => "invalid_operation"},
             %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"},
             %{"operation_id" => "open-1", "status" => "applied"}
           ] =
             submit(conn, [
               %{"operation_id" => "wat", "type" => "mystery"},
               "not-an-operation",
               open_operation()
             ])
  end

  test "duplicate group identifiers reject without changing the original", %{conn: conn} do
    assert [
             %{"status" => "applied"},
             %{"status" => "rejected", "code" => "group_already_exists"}
           ] =
             submit(conn, [
               open_operation(),
               open_operation(%{"operation_id" => "duplicate", "guest_id" => "other"})
             ])

    assert %{"data" => %{"guest_id" => "guest-22", "revision" => 1}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancellation(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end
end
