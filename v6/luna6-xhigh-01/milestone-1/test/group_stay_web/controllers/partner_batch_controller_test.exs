defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides) do
    Map.merge(
      %{
        operation_id: "open-1",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-1",
        guest_id: "guest-1",
        property_id: "hotel-1",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 10000}]
      },
      overrides
    )
  end

  defp operation(type, id, overrides) do
    Map.merge(
      %{
        operation_id: id,
        type: type,
        occurred_on: "2026-10-04",
        group_id: "group-1"
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  test "opens a group and calculates each flexible room deposit separately", %{conn: conn} do
    op =
      open_operation(%{
        departure_on: "2026-12-11",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 1003},
          %{room_id: "room-b", nightly_rate_cents: 1003}
        ]
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 402,
                 "revision" => 1
               }
             ]
           } = json_response(submit(conn, [op]), 200)

    assert %{
             "data" => %{
               "group_id" => "group-1",
               "guest_id" => "guest-1",
               "property_id" => "hotel-1",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-11",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 1003},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 1003}
               ],
               "lodging_total_cents" => 2006,
               "deposit_due_cents" => 402,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 402
             }
           } = get(conn, "/api/v1/groups/group-1") |> json_response(200)
  end

  test "applies batch operations in order and isolates rejected operations", %{conn: conn} do
    operations = [
      open_operation(%{arrival_on: "2026-12-20", departure_on: "2026-12-23"}),
      operation("record_cash_payment", "pay-1", %{
        amount_cents: 1000,
        expected_revision: 1
      }),
      operation("record_cash_payment", "stale-and-invalid", %{
        amount_cents: 0,
        expected_revision: 1
      }),
      operation("record_cash_payment", "pay-2", %{
        amount_cents: 1000,
        expected_revision: 2
      }),
      operation("record_cash_payment", "too-much", %{
        amount_cents: 4001,
        expected_revision: 3
      })
    ]

    assert %{"results" => [opened, paid_one, stale, paid_two, rejected]} =
             json_response(submit(conn, operations), 200)

    assert opened["revision"] == 1
    assert paid_one["revision"] == 2
    assert paid_one["outstanding_deposit_cents"] == 5000
    assert stale["code"] == "stale_revision"
    assert stale["expected_revision"] == 1
    assert stale["actual_revision"] == 2
    assert paid_two["revision"] == 3
    assert paid_two["outstanding_deposit_cents"] == 4000
    assert rejected["code"] == "payment_exceeds_outstanding"

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 2000}} =
             get(conn, "/api/v1/groups/group-1") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 2000}} =
             get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "reschedules by preserving stay length and increments the revision", %{conn: conn} do
    ops = [
      open_operation(%{arrival_on: "2026-12-20", departure_on: "2026-12-23"}),
      operation("reschedule_group", "move-1", %{
        occurred_on: "2026-10-10",
        new_arrival_on: "2027-01-02",
        expected_revision: 1
      })
    ]

    assert %{"results" => [_, moved]} = json_response(submit(conn, ops), 200)
    assert moved["status"] == "applied"
    assert moved["new_arrival_on"] == "2027-01-02"
    assert moved["new_departure_on"] == "2027-01-05"
    assert moved["revision"] == 2

    assert %{"data" => %{"arrival_on" => "2027-01-02", "departure_on" => "2027-01-05"}} =
             get(conn, "/api/v1/groups/group-1") |> json_response(200)
  end

  test "cancellation refunds flexible cash exactly fourteen days before arrival", %{conn: conn} do
    ops = [
      open_operation(%{arrival_on: "2026-12-20", departure_on: "2026-12-22"}),
      operation("record_cash_payment", "pay-1", %{amount_cents: 2000, expected_revision: 1}),
      operation("cancel_group", "cancel-1", %{
        occurred_on: "2026-12-06",
        expected_revision: 2
      })
    ]

    assert %{"results" => [_, _, cancelled]} = json_response(submit(conn, ops), 200)
    assert cancelled["refunded_cents"] == 2000
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 3

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2000,
               "cash_retained_cents" => 0
             }
           } =
             get(conn, "/api/v1/ledger") |> json_response(200)

    assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
             get(conn, "/api/v1/groups/group-1") |> json_response(200)

    assert %{"results" => [inactive]} =
             submit(conn, [operation("cancel_group", "cancel-again", %{expected_revision: 3})])
             |> json_response(200)

    assert inactive["code"] == "group_not_active"

    after_cancel = [
      operation("record_cash_payment", "pay-after-cancel", %{amount_cents: 1}),
      operation("reschedule_group", "move-after-cancel", %{
        new_arrival_on: "2027-01-01"
      }),
      operation("cancel_group", "cancel-after-cancel", %{})
    ]

    assert %{"results" => [payment, move, cancellation]} =
             submit(conn, after_cancel) |> json_response(200)

    assert payment["code"] == "group_not_active"
    assert move["code"] == "group_not_active"
    assert cancellation["code"] == "group_not_active"
  end

  test "retains late flexible and advance purchase payments on cancellation", %{conn: conn} do
    flexible_ops = [
      open_operation(%{arrival_on: "2026-12-20", departure_on: "2026-12-21"}),
      operation("record_cash_payment", "pay-flexible", %{amount_cents: 2000}),
      operation("cancel_group", "cancel-flexible", %{occurred_on: "2026-12-07"})
    ]

    assert %{"results" => [_, _, late_cancel]} =
             json_response(submit(conn, flexible_ops), 200)

    assert late_cancel["refunded_cents"] == 0
    assert late_cancel["retained_cents"] == 2000

    advance_ops = [
      open_operation(%{
        group_id: "group-2",
        rate_plan: "advance_purchase",
        arrival_on: "2026-12-20",
        departure_on: "2026-12-21"
      }),
      operation("record_cash_payment", "pay-advance", %{group_id: "group-2", amount_cents: 10000}),
      operation("cancel_group", "cancel-advance", %{
        group_id: "group-2",
        occurred_on: "2026-10-04"
      })
    ]

    assert %{"results" => [_, _, advance_cancel]} =
             json_response(submit(conn, advance_ops), 200)

    assert advance_cancel["refunded_cents"] == 0
    assert advance_cancel["retained_cents"] == 10000

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 12000
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "validates batch shape, group lookup, and domain inputs", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             post(conn, "/api/v1/partner-batches", %{"operations" => "not-an-array"})
             |> json_response(422)

    bad_ops = [
      %{"operation_id" => "missing-type", "occurred_on" => "2026-10-01"},
      open_operation(%{group_id: "group-invalid-stay", departure_on: "2026-12-10"}),
      open_operation(%{group_id: "group-invalid-rate", rate_plan: "unknown"}),
      open_operation(%{group_id: "group-invalid-rooms", rooms: []}),
      open_operation(%{
        group_id: "group-duplicate-room",
        rooms: [
          %{room_id: "same", nightly_rate_cents: 100},
          %{room_id: "same", nightly_rate_cents: 200}
        ]
      }),
      operation("record_cash_payment", "missing-group", %{
        group_id: "does-not-exist",
        amount_cents: 0,
        expected_revision: 999
      })
    ]

    assert %{
             "results" => [
               unknown,
               invalid_stay,
               invalid_plan,
               invalid_rooms,
               duplicate_rooms,
               missing
             ]
           } =
             json_response(submit(conn, bad_ops), 200)

    assert unknown["code"] == "invalid_operation"
    assert invalid_stay["code"] == "invalid_stay"
    assert invalid_plan["code"] == "invalid_rate_plan"
    assert duplicate_rooms["code"] == "invalid_rooms"
    assert invalid_rooms["code"] == "invalid_rooms"
    assert missing["code"] == "group_not_found"
    assert missing["group_id"] == "does-not-exist"

    duplicate_group = open_operation(%{group_id: "duplicate-group"})

    assert %{"results" => [_, duplicate]} =
             submit(conn, [duplicate_group, duplicate_group]) |> json_response(200)

    assert duplicate["code"] == "group_already_exists"

    assert %{"error" => %{"code" => "group_not_found"}} =
             get(conn, "/api/v1/groups/does-not-exist") |> json_response(404)
  end

  test "rejected payment and invalid reschedule leave group and ledger unchanged", %{conn: conn} do
    ops = [
      open_operation(%{arrival_on: "2026-12-20", departure_on: "2026-12-21"}),
      operation("record_cash_payment", "bad-payment", %{amount_cents: -1}),
      operation("record_cash_payment", "excess-payment", %{amount_cents: 2001}),
      operation("reschedule_group", "bad-move", %{
        occurred_on: "2026-12-01",
        new_arrival_on: "2026-11-30"
      })
    ]

    assert %{"results" => [_, invalid_amount, excess, invalid_stay]} =
             json_response(submit(conn, ops), 200)

    assert invalid_amount["code"] == "invalid_amount"
    assert excess["code"] == "payment_exceeds_outstanding"
    assert invalid_stay["code"] == "invalid_stay"

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get(conn, "/api/v1/groups/group-1") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } =
             get(conn, "/api/v1/ledger") |> json_response(200)
  end
end
