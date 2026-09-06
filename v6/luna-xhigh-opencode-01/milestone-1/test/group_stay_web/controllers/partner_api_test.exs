defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  test "opens and reads a group with calculated totals and room order", %{conn: conn} do
    open = open_group("group-81", "2026-10-03")

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
           } = submit(conn, [open])

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
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           } = get_group(conn, "group-81")
  end

  test "rounds each flexible room deposit separately", %{conn: conn} do
    operation =
      open_group("group-rounding", "2026-10-03")
      |> Map.put("arrival_on", "2026-12-10")
      |> Map.put("departure_on", "2026-12-11")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 3},
        %{"room_id" => "room-b", "nightly_rate_cents" => 8}
      ])

    assert %{"results" => [%{"deposit_due_cents" => 3, "revision" => 1}]} =
             submit(conn, [operation])
  end

  test "processes operations in order and rejects stale revisions without changing state", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}]} = submit(conn, [open_group("group-81")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "pay-2",
                 "status" => "applied",
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               },
               %{
                 "operation_id" => "pay-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 2,
                 "actual_revision" => 3
               }
             ]
           } =
             submit(conn, [
               payment("pay-1", "group-81", 10_000, 1),
               payment("pay-2", "group-81", 9_500, 2),
               payment("pay-stale", "group-81", 1, 2)
             ])

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 19_500}} =
             get_group(conn, "group-81")
  end

  test "continues after rejected operations and preserves their state", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = submit(conn, [open_group("group-81")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "missing",
                 "status" => "rejected",
                 "code" => "group_not_found"
               },
               %{
                 "operation_id" => "bad-amount",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               },
               %{"operation_id" => "valid", "status" => "applied", "revision" => 2}
             ]
           } =
             submit(conn, [
               payment("missing", "does-not-exist", 1),
               payment("bad-amount", "group-81", 0),
               payment("valid", "group-81", 1)
             ])

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1}} =
             get_group(conn, "group-81")
  end

  test "reschedules by preserving the stay length and settles a refundable cancellation", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_group("group-81", "2026-10-01")])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [payment("pay-1", "group-81", 19_500)])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 3
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 19_500,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "move-1",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "expected_revision" => 2
               },
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-05",
                 "group_id" => "group-81",
                 "expected_revision" => 3
               }
             ])

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 4,
               "deposit_paid_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             }
           } = get_group(conn, "group-81")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 19_500,
               "cash_retained_cents" => 0
             }
           } =
             get_ledger(conn)
  end

  test "cancellation of an advance purchase reservation retains cash", %{conn: conn} do
    operation = Map.put(open_group("group-81"), "rate_plan", "advance_purchase")

    assert %{"results" => [%{"deposit_due_cents" => 97_500, "revision" => 1}]} =
             submit(conn, [operation])

    assert %{
             "results" => [
               %{"revision" => 2},
               %{"revision" => 3, "refunded_cents" => 0, "retained_cents" => 5_000}
             ]
           } =
             submit(conn, [
               payment("pay-1", "group-81", 5_000),
               cancel("cancel-1", "group-81", "2026-10-04", 2)
             ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000
             }
           } =
             get_ledger(conn)
  end

  test "returns domain validation codes without creating or changing groups", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = submit(conn, [open_group("group-81")])

    invalid_rooms = Map.put(open_group("bad-rooms"), "rooms", [])
    invalid_rate_plan = Map.put(open_group("bad-rate-plan"), "rate_plan", "unknown")

    assert %{
             "results" => [
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rate_plan"},
               %{"code" => "group_already_exists"}
             ]
           } = submit(conn, [invalid_rooms, invalid_rate_plan, open_group("group-81")])

    assert %{
             "results" => [
               %{"code" => "payment_exceeds_outstanding"},
               %{"code" => "invalid_stay"}
             ]
           } =
             submit(conn, [
               payment("too-much", "group-81", 20_000),
               %{
                 "operation_id" => "bad-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-10-03"
               }
             ])

    assert %{"data" => %{"revision" => 1, "status" => "active", "deposit_paid_cents" => 0}} =
             get_group(conn, "group-81")
  end

  test "rejects invalid batches and invalid operations", %{conn: conn} do
    invalid_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{}))

    assert %{"error" => %{"code" => "invalid_batch"}} = json_response(invalid_conn, 422)

    assert %{"results" => results} =
             submit(conn, [
               %{"operation_id" => "unknown", "type" => "not_supported"},
               Map.put(open_group("group-invalid"), "arrival_on", "2026-12-13")
             ])

    assert [%{"code" => "invalid_operation"}, %{"code" => "invalid_stay"}] = results
    assert %{"error" => %{"code" => "group_not_found"}} = get_group(conn, "group-invalid", 404)
  end

  defp open_group(group_id, booked_on \\ "2026-10-03") do
    %{
      "operation_id" => "open-1",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
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

  defp payment(operation_id, group_id, amount_cents, expected_revision \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }

    if expected_revision,
      do: Map.put(operation, "expected_revision", expected_revision),
      else: operation
  end

  defp cancel(operation_id, group_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_group(conn, group_id, status \\ 200) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(status)
  end

  defp get_ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
  end
end
