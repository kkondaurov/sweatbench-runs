defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  test "opens a group and returns its calculated totals", %{conn: conn} do
    operation = open_group("open-1")

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
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

    assert %{
             "data" => %{
               "group_id" => "group-81",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 1,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "processes payment, rescheduling, cancellation, and ledger settlement in order", %{
    conn: conn
  } do
    operations = [
      open_group("open-1"),
      Map.merge(payment("payment-1", 5_000), %{"expected_revision" => 1}),
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-12",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "expected_revision" => 3
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               },
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-12",
                 "new_departure_on" => "2026-12-15",
                 "revision" => 3
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 4,
               "outstanding_deposit_cents" => 0
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "rejects stale revisions before domain validation and continues the batch", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open_group("open-1")]})

    operations = [
      Map.merge(payment("payment-1", 99_999), %{"expected_revision" => 0}),
      Map.merge(payment("payment-2", 5_000), %{"expected_revision" => 1})
    ]

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-1",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{"operation_id" => "payment-2", "status" => "applied", "revision" => 2}
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "returns stable errors for invalid batches and missing groups", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", Jason.encode!(%{}))
             |> json_response(422)

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/missing") |> json_response(404)
  end

  test "uses operation-specific validation codes without changing the group", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open_group("open-1")]})

    operations = [
      Map.drop(payment("missing-amount", 1), ["amount_cents"]),
      payment("invalid-amount", 0),
      payment("too-much", 99_999),
      %{
        "operation_id" => "invalid-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-10-03"
      },
      %{"operation_id" => "unknown", "type" => "unknown"}
    ]

    assert %{
             "results" => [
               %{"code" => "invalid_operation"},
               %{"code" => "invalid_amount"},
               %{"code" => "payment_exceeds_outstanding"},
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_operation"}
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0, "status" => "active"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "retains an advance-purchase payment on late cancellation", %{conn: conn} do
    operation =
      open_group("open-1")
      |> Map.put("rate_plan", "advance_purchase")
      |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])
      |> Map.put("departure_on", "2026-12-11")

    operations = [
      operation,
      Map.merge(payment("payment-1", 10_000), %{"expected_revision" => 1}),
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "expected_revision" => 2
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "deposit_due_cents" => 10_000},
               %{"status" => "applied", "outstanding_deposit_cents" => 0},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000}
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 10_000
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "rounds each flexible room deposit before summing", %{conn: conn} do
    operation =
      open_group("open-1")
      |> Map.put("arrival_on", "2026-12-10")
      |> Map.put("departure_on", "2026-12-11")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 2},
        %{"room_id" => "room-b", "nightly_rate_cents" => 2}
      ])

    assert %{
             "results" => [%{"status" => "applied", "deposit_due_cents" => 0, "revision" => 1}]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [operation]})
  end

  test "does not apply a duplicate open or invalid room data", %{conn: conn} do
    duplicate = open_group("duplicate")

    invalid_rooms =
      open_group("bad-rooms")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10},
        %{"room_id" => "room-a", "nightly_rate_cents" => 10}
      ])

    invalid_stay = Map.put(open_group("bad-stay"), "departure_on", "2026-12-10")
    invalid_rate_plan = Map.put(open_group("bad-rate"), "rate_plan", "nonrefundable")

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_already_exists"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_rate_plan"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 open_group("open-1"),
                 duplicate,
                 invalid_rooms,
                 invalid_stay,
                 invalid_rate_plan
               ]
             })

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/bad-rooms") |> json_response(404)
  end

  defp open_group(operation_id) do
    %{
      "operation_id" => operation_id,
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
    }
  end

  defp payment(operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
    |> json_response(200)
  end
end
