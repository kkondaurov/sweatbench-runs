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

  test "fixes cancellation policy at booking and reports it after rescheduling", %{conn: conn} do
    operations = [
      open_operation(%{
        operation_id: "open-flex-14",
        group_id: "flex-14",
        occurred_on: "2026-12-31"
      }),
      operation("reschedule_group", "move-flex-14", %{
        group_id: "flex-14",
        occurred_on: "2027-01-02",
        new_arrival_on: "2027-02-15",
        expected_revision: 1
      }),
      open_operation(%{
        operation_id: "open-flex-30",
        group_id: "flex-30",
        occurred_on: "2027-01-01",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-02"
      }),
      operation("reschedule_group", "move-flex-30", %{
        group_id: "flex-30",
        occurred_on: "2027-01-02",
        new_arrival_on: "2027-03-15",
        expected_revision: 1
      }),
      operation("record_cash_payment", "pay-flex-30", %{
        group_id: "flex-30",
        amount_cents: 1000,
        expected_revision: 2
      }),
      operation("cancel_group", "cancel-flex-30", %{
        group_id: "flex-30",
        occurred_on: "2027-02-13",
        expected_revision: 3
      }),
      open_operation(%{
        operation_id: "open-advance-policy",
        group_id: "advance-policy",
        rate_plan: "advance_purchase"
      })
    ]

    assert %{"results" => [_, moved14, _, moved30, _, cancelled30, _]} =
             json_response(submit(conn, operations), 200)

    assert moved14["policy_version"] == "flex-14"
    assert moved14["refundable_until"] == "2027-02-01"
    assert moved30["policy_version"] == "flex-30"
    assert moved30["refundable_until"] == "2027-02-13"
    assert cancelled30["refunded_cents"] == 1000

    assert %{"data" => flex14} = get(conn, "/api/v1/groups/flex-14") |> json_response(200)
    assert flex14["policy_version"] == "flex-14"
    assert flex14["arrival_on"] == "2027-02-15"
    assert flex14["refundable_until"] == "2027-02-01"

    assert %{"data" => flex30} = get(conn, "/api/v1/groups/flex-30") |> json_response(200)
    assert flex30["policy_version"] == "flex-30"
    assert flex30["refundable_until"] == "2027-02-13"

    assert %{"data" => advance} =
             get(conn, "/api/v1/groups/advance-policy") |> json_response(200)

    assert advance["policy_version"] == "advance-nonrefundable"
    assert advance["refundable_until"] == nil
  end

  test "issues, orders, applies, restores, and expires hotel credit", %{conn: conn} do
    source_operations =
      Enum.flat_map(["z-credit", "a-credit"], fn source_id ->
        group_id = "group-#{source_id}"

        [
          open_operation(%{
            operation_id: "open-#{source_id}",
            group_id: group_id,
            guest_id: "credit-guest",
            arrival_on: "2027-01-15",
            departure_on: "2027-01-16"
          }),
          operation("record_cash_payment", "pay-#{source_id}", %{
            group_id: group_id,
            amount_cents: 1005
          }),
          operation("cancel_group", source_id, %{
            group_id: group_id,
            occurred_on: "2027-01-01",
            refund_method: "hotel_credit",
            expected_revision: 2
          })
        ]
      end)

    redeem_operations = [
      open_operation(%{
        operation_id: "open-redeem",
        group_id: "redeem-group",
        guest_id: "credit-guest",
        arrival_on: "2027-02-10",
        departure_on: "2027-02-11",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 20_000}]
      }),
      operation("apply_hotel_credit", "redeem-first", %{
        group_id: "redeem-group",
        amount_cents: 2212,
        occurred_on: "2027-01-02",
        expected_revision: 1
      })
    ]

    assert %{"results" => source_results} =
             json_response(submit(conn, source_operations), 200)

    assert Enum.map(Enum.chunk_every(source_results, 3), fn [_opened, _paid, cancelled] ->
             cancelled["credit_issued_cents"]
           end) == [1106, 1106]

    assert %{"data" => %{"available_cents" => 2212, "lots" => initial_lots}} =
             get(conn, "/api/v1/guests/credit-guest/credit?on=2027-01-01")
             |> json_response(200)

    assert Enum.map(initial_lots, & &1["source_operation_id"]) == ["a-credit", "z-credit"]
    assert Enum.all?(initial_lots, &(&1["expires_on"] == "2028-01-01"))

    assert %{"results" => [_, applied]} =
             json_response(submit(conn, redeem_operations), 200)

    assert applied["status"] == "applied"
    assert applied["amount_cents"] == 2212
    assert applied["revision"] == 2

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(conn, "/api/v1/guests/credit-guest/credit?on=2027-01-02")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 2212}} =
             get(conn, "/api/v1/ledger?on=2027-01-02") |> json_response(200)

    assert %{"results" => [restored]} =
             submit(conn, [
               operation("cancel_group", "restore-first", %{
                 group_id: "redeem-group",
                 occurred_on: "2027-01-27",
                 expected_revision: 2
               })
             ])
             |> json_response(200)

    assert restored["status"] == "applied"
    assert restored["revision"] == 3

    assert %{
             "data" => %{
               "deposit_paid_cents" => 2212,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 2212
             }
           } = get(conn, "/api/v1/groups/redeem-group") |> json_response(200)

    assert %{"data" => %{"available_cents" => 2212, "lots" => restored_lots}} =
             get(conn, "/api/v1/guests/credit-guest/credit?on=2027-01-27")
             |> json_response(200)

    assert Enum.map(restored_lots, & &1["source_operation_id"]) == ["a-credit", "z-credit"]

    assert %{"data" => %{"available_cents" => 2212}} =
             get(conn, "/api/v1/guests/credit-guest/credit?on=2028-01-01")
             |> json_response(200)

    expiry_operations = [
      open_operation(%{
        operation_id: "open-expiry",
        group_id: "expiry-group",
        guest_id: "credit-guest",
        occurred_on: "2027-12-30",
        arrival_on: "2028-01-20",
        departure_on: "2028-01-21",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 20_000}]
      }),
      operation("apply_hotel_credit", "redeem-before-expiry", %{
        group_id: "expiry-group",
        amount_cents: 2212,
        occurred_on: "2027-12-31",
        expected_revision: 1
      }),
      operation("cancel_group", "restore-after-expiry", %{
        group_id: "expiry-group",
        occurred_on: "2028-01-02",
        expected_revision: 2
      })
    ]

    assert %{"results" => [_, _, expired_restore]} =
             json_response(submit(conn, expiry_operations), 200)

    assert expired_restore["credit_issued_cents"] == 0

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(conn, "/api/v1/guests/credit-guest/credit?on=2028-01-02")
             |> json_response(200)

    assert %{"data" => ledger} =
             get(conn, "/api/v1/ledger?on=2028-01-02") |> json_response(200)

    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 2010
    assert ledger["credit_liability_cents"] == 0
  end

  test "rejects credit use without changing revision or non-refundable groups", %{conn: conn} do
    operations = [
      open_operation(%{group_id: "credit-empty"}),
      operation("apply_hotel_credit", "exceeds-deposit", %{
        group_id: "credit-empty",
        amount_cents: 6001,
        expected_revision: 1
      }),
      operation("apply_hotel_credit", "invalid-credit-amount", %{
        group_id: "credit-empty",
        amount_cents: 0,
        expected_revision: 1
      }),
      operation("apply_hotel_credit", "no-credit", %{
        group_id: "credit-empty",
        amount_cents: 100,
        expected_revision: 1
      }),
      open_operation(%{
        group_id: "non-refundable-credit",
        rate_plan: "advance_purchase"
      }),
      operation("cancel_group", "stale-credit-method", %{
        group_id: "non-refundable-credit",
        refund_method: "hotel_credit",
        expected_revision: 0
      }),
      operation("cancel_group", "credit-nonrefundable", %{
        group_id: "non-refundable-credit",
        refund_method: "hotel_credit",
        expected_revision: 1
      })
    ]

    assert %{"results" => [_, exceeds, invalid_amount, no_credit, _, stale, unavailable]} =
             json_response(submit(conn, operations), 200)

    assert exceeds["code"] == "payment_exceeds_outstanding"
    assert invalid_amount["code"] == "invalid_amount"
    assert no_credit["code"] == "insufficient_credit"
    assert stale["code"] == "stale_revision"
    assert unavailable["code"] == "refund_method_not_available"

    assert %{"data" => %{"status" => "active", "revision" => 1}} =
             get(conn, "/api/v1/groups/non-refundable-credit") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2027-01-01") |> json_response(200)

    assert %{"error" => %{"code" => "invalid_date"}} =
             get(conn, "/api/v1/ledger?on=2027-02-30") |> json_response(422)
  end

  test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
    operations = [
      open_operation(%{
        operation_id: "open-credit-source",
        group_id: "credit-source",
        guest_id: "consuming-guest",
        arrival_on: "2027-01-15",
        departure_on: "2027-01-16"
      }),
      operation("record_cash_payment", "pay-credit-source", %{
        group_id: "credit-source",
        amount_cents: 1000
      }),
      operation("cancel_group", "issue-for-consumption", %{
        group_id: "credit-source",
        occurred_on: "2027-01-01",
        refund_method: "hotel_credit",
        expected_revision: 2
      }),
      open_operation(%{
        operation_id: "open-advance-credit",
        group_id: "advance-credit",
        guest_id: "consuming-guest",
        rate_plan: "advance_purchase",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-02",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 10_000}]
      }),
      operation("apply_hotel_credit", "apply-to-advance", %{
        group_id: "advance-credit",
        amount_cents: 1100,
        occurred_on: "2027-01-02",
        expected_revision: 1
      }),
      operation("cancel_group", "consume-on-cancel", %{
        group_id: "advance-credit",
        occurred_on: "2027-01-03",
        expected_revision: 2
      })
    ]

    assert %{"results" => [_, _, issued, _, applied, cancelled]} =
             json_response(submit(conn, operations), 200)

    assert issued["credit_issued_cents"] == 1100
    assert applied["status"] == "applied"
    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0

    assert %{"data" => %{"credit_paid_cents" => 1100, "status" => "cancelled"}} =
             get(conn, "/api/v1/groups/advance-credit") |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(conn, "/api/v1/guests/consuming-guest/credit?on=2027-01-03")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2027-01-03") |> json_response(200)
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
