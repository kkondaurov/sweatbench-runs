defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: true

  import Phoenix.ConnTest

  test "opens a group, calculates each room deposit, and returns it in room order", %{conn: conn} do
    response = post_operations(conn, [open_group()])

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           }

    assert %{
             "data" => %{
               "group_id" => "group-1",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
  end

  test "processes a batch in order and keeps later operations after a rejection", %{conn: conn} do
    payment = %{
      "operation_id" => "payment-too-large",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 19_501
    }

    accepted_payment = %{payment | "operation_id" => "payment-accepted", "amount_cents" => 5_000}

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "payment-too-large",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "payment-accepted",
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           } = post_operations(conn, [open_group(), payment, accepted_payment])

    assert %{"data" => %{"deposit_paid_cents" => 5_000, "revision" => 2}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
  end

  test "returns structured stale revision errors before other domain validation", %{conn: conn} do
    payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 5_000,
      "expected_revision" => 1
    }

    stale_payment = %{
      "operation_id" => "payment-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "not-a-date",
      "group_id" => "group-1",
      "amount_cents" => -1,
      "expected_revision" => 1
    }

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "payment-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           } = post_operations(conn, [open_group(), payment, stale_payment])

    missing_group = %{stale_payment | "group_id" => "missing-group"}

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-stale",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           } = post_operations(build_conn(), [missing_group])
  end

  test "reschedules an active group and preserves its stay length", %{conn: conn} do
    reschedule = %{
      "operation_id" => "move-1",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "new_arrival_on" => "2026-12-20",
      "expected_revision" => 1
    }

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "move-1",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 2
               }
             ]
           } = post_operations(conn, [open_group(), reschedule])

    invalid_move = %{
      reschedule
      | "operation_id" => "move-invalid",
        "new_arrival_on" => "2026-10-04"
    }

    assert %{
             "results" => [
               %{
                 "operation_id" => "move-invalid",
                 "status" => "rejected",
                 "code" => "stale_revision"
               }
             ]
           } = post_operations(build_conn(), [invalid_move])

    assert %{"data" => %{"arrival_on" => "2026-12-20", "departure_on" => "2026-12-23"}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
  end

  test "cancellation settles cash and ledger totals distinguish held, refunded, and retained", %{
    conn: conn
  } do
    advance_group =
      open_group(%{
        "operation_id" => "open-advance",
        "group_id" => "group-advance",
        "rate_plan" => "advance_purchase"
      })

    late_flexible_group =
      open_group(%{
        "operation_id" => "open-late-flexible",
        "group_id" => "group-late-flexible"
      })

    payments_and_cancellations = [
      open_group(),
      advance_group,
      late_flexible_group,
      payment("payment-flex", "group-1", 5_000),
      payment("payment-advance", "group-advance", 10_000),
      payment("payment-late-flexible", "group-late-flexible", 7_000),
      cancel("cancel-flex", "group-1", "2026-11-26"),
      cancel("cancel-advance", "group-advance", "2026-10-04"),
      cancel("cancel-late-flexible", "group-late-flexible", "2026-11-27")
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "cancel-flex",
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 3
               },
               %{
                 "operation_id" => "cancel-advance",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 10_000,
                 "revision" => 3
               },
               %{
                 "operation_id" => "cancel-late-flexible",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 7_000,
                 "revision" => 3
               }
             ]
           } = post_operations(conn, payments_and_cancellations)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 17_000
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    assert %{
             "results" => [
               %{"operation_id" => "payment-after-cancel", "code" => "group_not_active"}
             ]
           } = post_operations(build_conn(), [payment("payment-after-cancel", "group-1", 1)])
  end

  test "rejects malformed operations and invalid rooms without creating a group", %{conn: conn} do
    invalid_rooms = %{
      open_group()
      | "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 2}
        ]
    }

    assert %{
             "results" => [
               %{"status" => "rejected", "code" => "invalid_operation"},
               %{"operation_id" => "open-1", "status" => "rejected", "code" => "invalid_rooms"}
             ]
           } =
             post_operations(conn, [
               %{"operation_id" => "unknown", "type" => "surprise"},
               invalid_rooms
             ])

    assert %{"error" => %{"code" => "group_not_found"}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(404)
  end

  test "uses stable validation codes for opening and rescheduling", %{conn: conn} do
    invalid_stay = %{open_group() | "arrival_on" => "not-a-date"}
    invalid_rate_plan = %{open_group() | "operation_id" => "bad-plan", "rate_plan" => "weekend"}
    valid_open = %{open_group() | "operation_id" => "open-valid"}
    duplicate_open = %{open_group() | "operation_id" => "open-duplicate"}

    assert %{
             "results" => [
               %{"operation_id" => "open-1", "code" => "invalid_stay"},
               %{"operation_id" => "bad-plan", "code" => "invalid_rate_plan"},
               %{"operation_id" => "open-valid", "status" => "applied", "revision" => 1},
               %{"operation_id" => "open-duplicate", "code" => "group_already_exists"}
             ]
           } =
             post_operations(conn, [invalid_stay, invalid_rate_plan, valid_open, duplicate_open])

    invalid_move = %{
      "operation_id" => "move-too-early",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "new_arrival_on" => "2026-10-04"
    }

    invalid_amount = payment("bad-amount", "group-1", 0)

    assert %{
             "results" => [
               %{"operation_id" => "move-too-early", "code" => "invalid_stay"},
               %{"operation_id" => "bad-amount", "code" => "invalid_amount"}
             ]
           } = post_operations(build_conn(), [invalid_move, invalid_amount])
  end

  test "reports zero ledger totals before any cash is recorded", %{conn: conn} do
    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "returns invalid_batch when operations is absent or not an array", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             post(conn, "/api/v1/partner-batches", %{}) |> json_response(422)

    assert %{"error" => %{"code" => "invalid_batch"}} =
             post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})
             |> json_response(422)
  end

  defp open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
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

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
