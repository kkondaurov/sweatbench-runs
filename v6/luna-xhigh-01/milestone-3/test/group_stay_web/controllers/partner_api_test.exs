defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  test "opens, funds, reschedules, cancels, and reports the ledger", %{conn: conn} do
    open = open_operation()

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
           } = post_batch(conn, [open])

    assert %{
             "data" => %{
               "group_id" => "group-81",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "status" => "active"
             }
           } = json_response(get(conn, "/api/v1/groups/group-81"), 200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           } = post_batch(conn, [payment("pay-1", 5_000, 1)])

    assert %{
             "results" => [
               %{
                 "operation_id" => "move-1",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-12",
                 "new_departure_on" => "2026-12-15",
                 "revision" => 3
               }
             ]
           } = post_batch(conn, [reschedule("move-1", "2026-10-04", "2026-12-12", 2)])

    assert %{
             "results" => [
               %{
                 "operation_id" => "cancel-1",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 5_000,
                 "revision" => 4
               }
             ]
           } = post_batch(conn, [cancel("cancel-1", "2026-12-01", 3)])

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 4,
               "deposit_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 0
             }
           } = json_response(get(conn, "/api/v1/groups/group-81"), 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000
             }
           } = json_response(get(conn, "/api/v1/ledger"), 200)
  end

  test "rejects one operation without stopping later operations", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation(),
        payment("too-much", 20_000, 1),
        payment("pay-2", 19_500, 1)
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "too-much",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "pay-2",
                 "status" => "applied",
                 "outstanding_deposit_cents" => 0,
                 "revision" => 2
               }
             ]
           } = results

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 19_500}} =
             json_response(get(conn, "/api/v1/groups/group-81"), 200)
  end

  test "checks revisions before other validation and keeps stale changes out", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open_operation()])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "revision" => 2
               }
             ]
           } = post_batch(conn, [payment("pay-3", 1_000, 1)])

    assert %{
             "results" => [
               %{
                 "operation_id" => "bad-revision",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "bad-revision",
                 "type" => "record_cash_payment",
                 "occurred_on" => "not-a-date",
                 "group_id" => "group-81",
                 "amount_cents" => -1,
                 "expected_revision" => 1
               }
             ])

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             json_response(get(conn, "/api/v1/groups/group-81"), 200)
  end

  test "returns the documented errors for invalid batches and missing groups", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", Jason.encode!(%{}))
             |> json_response(422)

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing"}]} =
             post_batch(conn, [payment("missing-payment", 1, nil, "missing")])

    assert %{"error" => %{"code" => "group_not_found"}} =
             json_response(get(conn, "/api/v1/groups/missing"), 404)
  end

  test "validates stays, rooms, rate plans, and rounds each flexible room deposit", %{conn: conn} do
    assert %{
             "results" => [
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rate_plan"},
               %{
                 "status" => "applied",
                 "group_id" => "rounded",
                 "deposit_due_cents" => 2
               }
             ]
           } =
             post_batch(conn, [
               open_operation("bad-stay", "2026-12-10", "2026-12-10", "flexible", rooms()),
               open_operation("bad-rooms", "2026-12-10", "2026-12-11", "flexible", [
                 %{"room_id" => "same", "nightly_rate_cents" => 10},
                 %{"room_id" => "same", "nightly_rate_cents" => 20}
               ]),
               open_operation("bad-rate", "2026-12-10", "2026-12-11", "nonexistent", rooms()),
               open_operation("rounded", "2026-12-10", "2026-12-11", "flexible", [
                 %{"room_id" => "one", "nightly_rate_cents" => 3},
                 %{"room_id" => "two", "nightly_rate_cents" => 3}
               ])
             ])

    assert %{"error" => %{"code" => "group_not_found"}} =
             json_response(get(conn, "/api/v1/groups/bad-stay"), 404)
  end

  test "refunds flexible deposits at the fourteen-day cutoff and never refunds advance purchase",
       %{
         conn: conn
       } do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"refunded_cents" => 0, "retained_cents" => 100, "revision" => 3},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"refunded_cents" => 100, "retained_cents" => 0, "revision" => 3}
             ]
           } =
             post_batch(conn, [
               open_operation("advance", "2026-12-20", "2026-12-21", "advance_purchase", [
                 %{"room_id" => "advance-room", "nightly_rate_cents" => 100}
               ]),
               payment("advance-pay", 100, 1, "advance"),
               cancel_for("advance-cancel", "2026-12-19", 2, "advance"),
               open_operation("flexible", "2026-12-20", "2026-12-21", "flexible", [
                 %{"room_id" => "flex-room", "nightly_rate_cents" => 500}
               ]),
               payment("flex-pay", 100, 1, "flexible"),
               cancel_for("flex-cancel", "2026-12-06", 2, "flexible")
             ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 100,
               "cash_retained_cents" => 100
             }
           } = json_response(get(conn, "/api/v1/ledger"), 200)
  end

  test "does not apply operations after cancellation", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [open_operation(), cancel("cancel-now", "2026-10-04", 1)])

    assert %{
             "results" => [
               %{"operation_id" => "late-pay", "code" => "group_not_active"},
               %{"operation_id" => "late-move", "code" => "group_not_active"},
               %{"operation_id" => "late-cancel", "code" => "group_not_active"}
             ]
           } =
             post_batch(conn, [
               payment("late-pay", 1, nil),
               reschedule("late-move", "2026-10-04", "2026-12-12", nil),
               cancel("late-cancel", "2026-10-04", nil)
             ])

    assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} =
             json_response(get(conn, "/api/v1/groups/group-81"), 200)
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation do
    open_operation("group-81", "2026-12-10", "2026-12-13", "flexible", rooms(), "open-1")
  end

  defp open_operation(group_id, arrival_on, departure_on, rate_plan, rooms) do
    open_operation(group_id, arrival_on, departure_on, rate_plan, rooms, "open-#{group_id}")
  end

  defp open_operation(group_id, arrival_on, departure_on, rate_plan, rooms, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => departure_on,
      "rate_plan" => rate_plan,
      "rooms" => rooms
    }
  end

  defp rooms do
    [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
    ]
  end

  defp payment(operation_id, amount_cents, expected_revision, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
    |> maybe_expected_revision(expected_revision)
  end

  defp reschedule(operation_id, occurred_on, new_arrival_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => occurred_on,
      "new_arrival_on" => new_arrival_on,
      "group_id" => "group-81"
    }
    |> maybe_expected_revision(expected_revision)
  end

  defp cancel(operation_id, occurred_on, expected_revision) do
    cancel_for(operation_id, occurred_on, expected_revision, "group-81")
  end

  defp cancel_for(operation_id, occurred_on, expected_revision, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_expected_revision(expected_revision)
  end

  defp maybe_expected_revision(operation, nil), do: operation

  defp maybe_expected_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)
end
