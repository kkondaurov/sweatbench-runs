defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query

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

  defp transfer(source_group_id, destination_group_id, id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: id,
        type: "transfer_deposit",
        source_group_id: source_group_id,
        destination_group_id: destination_group_id,
        amount_cents: 1
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp submit_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  test "replays applied results, ignores object key order, and rejects changed payloads", %{
    conn: conn
  } do
    original =
      open_operation(%{
        operation_id: "durable-open",
        group_id: "durable-group",
        arrival_on: "2026-12-20",
        departure_on: "2026-12-21"
      })

    payment =
      operation("record_cash_payment", "durable-payment", %{
        group_id: "durable-group",
        amount_cents: 100,
        expected_revision: 1
      })

    assert %{"results" => [opened, paid]} =
             submit(conn, [original, payment]) |> json_response(200)

    assert %{"results" => [^opened, ^paid]} =
             submit(conn, [original, payment]) |> json_response(200)

    changed_payment = Map.put(payment, :amount_cents, 101)

    assert %{"results" => [conflict]} =
             submit(conn, [changed_payment]) |> json_response(200)

    assert conflict["code"] == "operation_id_conflict"

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
             get(conn, "/api/v1/groups/durable-group") |> json_response(200)

    first_json =
      ~s({"operations":[{"operation_id":"json-key-order","type":"open_group","occurred_on":"2026-10-03","group_id":"json-order-group","guest_id":"guest-1","property_id":"hotel-1","arrival_on":"2026-12-10","departure_on":"2026-12-11","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":1000}]}]})

    reordered_json =
      ~s({"operations":[{"rooms":[{"nightly_rate_cents":1000,"room_id":"room-a"}],"rate_plan":"flexible","departure_on":"2026-12-11","arrival_on":"2026-12-10","property_id":"hotel-1","guest_id":"guest-1","group_id":"json-order-group","occurred_on":"2026-10-03","type":"open_group","operation_id":"json-key-order"}]})

    first_result = submit_json(conn, first_json) |> json_response(200)
    assert submit_json(conn, reordered_json) |> json_response(200) == first_result

    ordered_rooms = [
      %{room_id: "room-a", nightly_rate_cents: 1000},
      %{room_id: "room-b", nightly_rate_cents: 2000}
    ]

    ordered_group =
      open_operation(%{
        operation_id: "array-order-operation",
        group_id: "array-order-group",
        rooms: ordered_rooms
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [ordered_group]) |> json_response(200)

    reversed_group = Map.put(ordered_group, :rooms, Enum.reverse(ordered_rooms))

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [reversed_group]) |> json_response(200)

    assert %{"data" => %{"rooms" => [%{"room_id" => "room-a"}, %{"room_id" => "room-b"}]}} =
             get(conn, "/api/v1/groups/array-order-group") |> json_response(200)
  end

  test "stores rejected results and exposes only the original result", %{conn: conn} do
    opening =
      open_operation(%{
        operation_id: "audit-open",
        group_id: "audit-group",
        arrival_on: "2026-12-20",
        departure_on: "2026-12-21"
      })

    stale =
      operation("record_cash_payment", "stale-audit", %{
        group_id: "audit-group",
        amount_cents: 1,
        expected_revision: 0
      })

    payment =
      operation("record_cash_payment", "audit-payment", %{
        group_id: "audit-group",
        amount_cents: 1,
        expected_revision: 1
      })

    assert %{"results" => [_, original_stale, _]} =
             submit(conn, [opening, stale, payment]) |> json_response(200)

    assert original_stale["code"] == "stale_revision"
    assert original_stale["actual_revision"] == 1

    assert %{"results" => [replayed_stale]} =
             submit(conn, [stale]) |> json_response(200)

    assert replayed_stale == original_stale

    corrected = Map.put(stale, :expected_revision, 2)

    assert %{"results" => [conflict]} =
             submit(conn, [corrected]) |> json_response(200)

    assert conflict["code"] == "operation_id_conflict"

    assert %{"data" => ^original_stale} =
             get(conn, "/api/v1/operations/stale-audit") |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(conn, "/api/v1/operations/unknown") |> json_response(404)

    records =
      GroupStay.Repo.all(
        from operation in GroupStay.PartnerOperation,
          order_by: operation.id
      )

    assert Enum.map(records, & &1.operation_id) == ["audit-open", "stale-audit", "audit-payment"]

    assert Enum.at(records, 0).operation_type == "open_group"
    assert Enum.at(records, 0).submission == Jason.decode!(Jason.encode!(opening))
    assert Enum.at(records, 1).operation_type == "record_cash_payment"
    assert Enum.at(records, 1).submission == Jason.decode!(Jason.encode!(stale))
    assert Enum.at(records, 1).result == original_stale
  end

  test "serializes concurrent retries of the same operation", %{conn: conn} do
    operation =
      open_operation(%{
        operation_id: "concurrent-open",
        group_id: "concurrent-group"
      })
      |> Jason.encode!()
      |> Jason.decode!()

    results =
      1..8
      |> Task.async_stream(
        fn _ -> GroupStay.Reservations.process_batch([operation]) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [hd(results)]

    assert %{"data" => %{"revision" => 1}} =
             get(conn, "/api/v1/groups/concurrent-group") |> json_response(200)
  end

  test "rolls back domain changes and leaves no record after an unexpected database error", %{
    conn: conn
  } do
    operations = [
      open_operation(%{
        operation_id: "rollback-source-open",
        group_id: "rollback-source",
        guest_id: "rollback-guest",
        arrival_on: "2026-12-20",
        departure_on: "2026-12-21"
      }),
      operation("record_cash_payment", "rollback-source-payment", %{
        group_id: "rollback-source",
        amount_cents: 500
      }),
      operation("cancel_group", "rollback-credit-issue", %{
        group_id: "rollback-source",
        occurred_on: "2026-10-03",
        refund_method: "hotel_credit",
        expected_revision: 2
      }),
      open_operation(%{
        operation_id: "rollback-target-open",
        group_id: "rollback-target",
        guest_id: "rollback-guest",
        arrival_on: "2026-12-25",
        departure_on: "2026-12-26"
      })
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, operations) |> json_response(200)

    credit_payment =
      operation("apply_hotel_credit", "rollback-credit-apply", %{
        group_id: "rollback-target",
        amount_cents: 100,
        occurred_on: "2026-10-04",
        expected_revision: 1
      })
      |> Jason.encode!()
      |> Jason.decode!()

    GroupStay.Repo.query!("""
    CREATE TRIGGER fail_reservation_update
    BEFORE UPDATE ON group_reservations
    BEGIN
      SELECT RAISE(ABORT, 'forced reservation update failure');
    END
    """)

    assert_raise Exqlite.Error, fn ->
      GroupStay.Reservations.process_batch([credit_payment])
    end

    GroupStay.Repo.query!("DROP TRIGGER fail_reservation_update")

    assert GroupStay.Reservations.get_operation("rollback-credit-apply") == nil

    assert %{revision: 1, credit_paid_cents: 0} =
             GroupStay.Reservations.get_group("rollback-target")

    assert %{available_cents: 550} =
             GroupStay.Reservations.guest_credit("rollback-guest", ~D[2026-10-04])

    assert [%{"status" => "applied", "amount_cents" => 100}] =
             GroupStay.Reservations.process_batch([credit_payment])
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
        operation_id: "open-advance-cancellation",
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
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
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
        operation_id: "open-non-refundable-credit",
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

    assert %{"data" => %{"credit_paid_cents" => 0, "status" => "cancelled"}} =
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
      open_operation(%{
        operation_id: "invalid-stay-open",
        group_id: "group-invalid-stay",
        departure_on: "2026-12-10"
      }),
      open_operation(%{
        operation_id: "invalid-rate-open",
        group_id: "group-invalid-rate",
        rate_plan: "unknown"
      }),
      open_operation(%{
        operation_id: "invalid-rooms-open",
        group_id: "group-invalid-rooms",
        rooms: []
      }),
      open_operation(%{
        operation_id: "duplicate-rooms-open",
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

    assert %{
             "data" => %{
               "operation_id" => "missing-type",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
           } = get(conn, "/api/v1/operations/missing-type") |> json_response(200)

    assert invalid_stay["code"] == "invalid_stay"
    assert invalid_plan["code"] == "invalid_rate_plan"
    assert duplicate_rooms["code"] == "invalid_rooms"
    assert invalid_rooms["code"] == "invalid_rooms"
    assert missing["code"] == "group_not_found"
    assert missing["group_id"] == "does-not-exist"

    duplicate_group = open_operation(%{group_id: "duplicate-group"})

    assert %{"results" => [first, replayed]} =
             submit(conn, [duplicate_group, duplicate_group]) |> json_response(200)

    assert replayed == first

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

  test "room cancellation settles only selected room funding and payment reductions compose", %{
    conn: conn
  } do
    opening =
      open_operation(%{
        operation_id: "room-accounting-open",
        group_id: "room-accounting-group",
        arrival_on: "2026-12-20",
        departure_on: "2026-12-21",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 10_000},
          %{room_id: "room-b", nightly_rate_cents: 10_000}
        ]
      })

    payment =
      operation("record_cash_payment", "room-accounting-payment", %{
        group_id: "room-accounting-group",
        amount_cents: 3000
      })

    reduce =
      operation("reduce_cash_payment", "reduce-room-payment", %{
        payment_operation_id: "room-accounting-payment",
        amount_cents: 500,
        expected_revision: 2
      })

    cancel_b =
      operation("cancel_rooms", "cancel-room-b", %{
        group_id: "room-accounting-group",
        room_ids: ["room-b"],
        occurred_on: "2026-10-04",
        expected_revision: 3
      })

    reduce_remaining =
      operation("reduce_cash_payment", "reduce-room-payment-remainder", %{
        payment_operation_id: "room-accounting-payment",
        amount_cents: 2000,
        expected_revision: 4
      })

    assert %{"results" => [_, paid, reduced, cancelled]} =
             submit(conn, [opening, payment, reduce, cancel_b]) |> json_response(200)

    assert paid["amount_cents"] == 3000
    assert reduced["outstanding_deposit_cents"] == 1500
    assert reduced["revision"] == 3
    assert cancelled["cancelled_room_ids"] == ["room-b"]
    assert cancelled["refunded_cents"] == 500
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 4

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2000,
               "deposit_paid_cents" => 2000,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 2000},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } = get(conn, "/api/v1/groups/room-accounting-group") |> json_response(200)

    assert %{"results" => [^cancelled]} = submit(conn, [cancel_b]) |> json_response(200)

    assert %{"results" => [reduced_remaining_result]} =
             submit(conn, [reduce_remaining]) |> json_response(200)

    assert reduced_remaining_result["status"] == "applied"
    assert reduced_remaining_result["amount_cents"] == 2000
    assert reduced_remaining_result["outstanding_deposit_cents"] == 2000
    assert reduced_remaining_result["revision"] == 5

    assert %{
             "data" => %{
               "revision" => 5,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 2000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } =
             get(conn, "/api/v1/groups/room-accounting-group") |> json_response(200)

    # Replaying the original payment returns its original result without restoring the cash.
    assert %{"results" => [^paid]} = submit(conn, [payment]) |> json_response(200)

    assert %{"data" => statement} =
             get(conn, "/api/v1/payments/room-accounting-payment") |> json_response(200)

    assert statement == %{
             "payment_operation_id" => "room-accounting-payment",
             "original_group_id" => "room-accounting-group",
             "recorded_cents" => 3000,
             "held_cents" => 0,
             "refunded_cents" => 500,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 2500,
             "charged_back_cents" => 0
           }

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 500,
               "cash_reduced_cents" => 2500,
               "cash_charged_back_cents" => 0
             }
           } = get(conn, "/api/v1/ledger") |> json_response(200)
  end

  test "room cancellations validate distinct active IDs and report group room order", %{
    conn: conn
  } do
    opening =
      open_operation(%{
        operation_id: "ordered-rooms-open",
        group_id: "ordered-rooms-group",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 1000},
          %{room_id: "room-b", nightly_rate_cents: 2000}
        ]
      })

    invalid =
      operation("cancel_rooms", "duplicate-room-cancel", %{
        group_id: "ordered-rooms-group",
        room_ids: ["room-a", "room-a"],
        occurred_on: "2026-10-04",
        expected_revision: 1
      })

    cancel =
      operation("cancel_rooms", "ordered-room-cancel", %{
        group_id: "ordered-rooms-group",
        room_ids: ["room-b", "room-a"],
        occurred_on: "2026-10-04",
        expected_revision: 1
      })

    assert %{"results" => [_, rejected, cancelled]} =
             submit(conn, [opening, invalid, cancel]) |> json_response(200)

    assert rejected["code"] == "invalid_rooms"
    assert cancelled["cancelled_room_ids"] == ["room-a", "room-b"]
    assert cancelled["revision"] == 2

    assert %{
             "data" => %{
               "status" => "cancelled",
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           } =
             get(conn, "/api/v1/groups/ordered-rooms-group") |> json_response(200)
  end

  test "cash and credit allocations fill rooms in original order", %{conn: conn} do
    operations = [
      open_operation(%{
        operation_id: "room-credit-source-open",
        group_id: "room-credit-source",
        guest_id: "room-credit-guest",
        arrival_on: "2027-01-15",
        departure_on: "2027-01-16"
      }),
      operation("record_cash_payment", "room-credit-source-payment", %{
        group_id: "room-credit-source",
        amount_cents: 1000
      }),
      operation("cancel_group", "room-credit-source-cancel", %{
        group_id: "room-credit-source",
        occurred_on: "2026-10-04",
        refund_method: "hotel_credit"
      }),
      open_operation(%{
        operation_id: "room-credit-target-open",
        group_id: "room-credit-target",
        guest_id: "room-credit-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 10_000},
          %{room_id: "room-b", nightly_rate_cents: 10_000}
        ]
      }),
      operation("apply_hotel_credit", "room-credit-target-credit", %{
        group_id: "room-credit-target",
        amount_cents: 1100,
        occurred_on: "2026-10-05"
      }),
      operation("record_cash_payment", "room-credit-target-cash", %{
        group_id: "room-credit-target",
        amount_cents: 1500
      })
    ]

    assert %{"results" => [_, _, issued, _, _, _]} =
             submit(conn, operations) |> json_response(200)

    assert issued["credit_issued_cents"] == 1100

    assert %{
             "data" => %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "deposit_due_cents" => 2000,
                   "cash_paid_cents" => 900,
                   "credit_paid_cents" => 1100
                 },
                 %{
                   "room_id" => "room-b",
                   "deposit_due_cents" => 2000,
                   "cash_paid_cents" => 600,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = get(conn, "/api/v1/groups/room-credit-target") |> json_response(200)
  end

  test "payment correction rejections preserve stale revision and target error precedence", %{
    conn: conn
  } do
    assert %{"results" => [_, _, rejected_payment]} =
             submit(conn, [
               open_operation(%{
                 operation_id: "correction-target-open",
                 group_id: "correction-target-group"
               }),
               operation("record_cash_payment", "correction-valid-payment", %{
                 group_id: "correction-target-group",
                 amount_cents: 100
               }),
               operation("record_cash_payment", "correction-rejected-payment", %{
                 group_id: "correction-target-group",
                 amount_cents: 0
               })
             ])
             |> json_response(200)

    assert rejected_payment["code"] == "invalid_amount"

    corrections = [
      operation("reduce_cash_payment", "target-missing", %{
        payment_operation_id: "missing-payment",
        amount_cents: 1
      }),
      operation("reduce_cash_payment", "stale-rejected-payment", %{
        payment_operation_id: "correction-rejected-payment",
        amount_cents: 1,
        expected_revision: 1
      }),
      operation("reduce_cash_payment", "rejected-payment-target", %{
        payment_operation_id: "correction-rejected-payment",
        amount_cents: 1,
        expected_revision: 2
      }),
      operation("charge_back_payment", "non-cash-target", %{
        payment_operation_id: "correction-target-open",
        expected_revision: 2
      }),
      operation("reduce_cash_payment", "invalid-correction-amount", %{
        payment_operation_id: "correction-valid-payment",
        amount_cents: 0,
        expected_revision: 2
      }),
      operation("reduce_cash_payment", "excess-correction-amount", %{
        payment_operation_id: "correction-valid-payment",
        amount_cents: 101,
        expected_revision: 2
      }),
      operation("reduce_cash_payment", "full-held-correction", %{
        payment_operation_id: "correction-valid-payment",
        amount_cents: 100,
        expected_revision: 2
      }),
      operation("charge_back_payment", "fully-reduced-chargeback", %{
        payment_operation_id: "correction-valid-payment",
        expected_revision: 3
      }),
      operation("reduce_cash_payment", "fully-reduced-again", %{
        payment_operation_id: "correction-valid-payment",
        amount_cents: 1,
        expected_revision: 3
      })
    ]

    assert %{
             "results" => [
               missing,
               stale,
               rejected,
               non_cash,
               invalid,
               excess,
               applied,
               charged,
               unreducible
             ]
           } =
             submit(conn, corrections) |> json_response(200)

    assert missing["code"] == "operation_not_found"
    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 2
    assert rejected["code"] == "payment_not_reducible"
    assert non_cash["code"] == "payment_not_chargeable"
    assert invalid["code"] == "invalid_amount"
    assert excess["code"] == "reduction_exceeds_held_cash"
    assert applied["status"] == "applied"
    assert applied["amount_cents"] == 100
    assert applied["revision"] == 3
    assert charged["code"] == "payment_not_chargeable"
    assert unreducible["code"] == "payment_not_reducible"
  end

  test "chargebacks revoke payment credit entitlement and later restoration absorbs shortfall", %{
    conn: conn
  } do
    operations = [
      open_operation(%{
        operation_id: "clawback-source-open",
        group_id: "clawback-source",
        guest_id: "clawback-guest",
        arrival_on: "2027-01-15",
        departure_on: "2027-01-16",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 20_000}]
      }),
      operation("record_cash_payment", "clawback-payment-one", %{
        group_id: "clawback-source",
        amount_cents: 1005
      }),
      operation("record_cash_payment", "clawback-payment-two", %{
        group_id: "clawback-source",
        amount_cents: 1005
      }),
      operation("cancel_group", "clawback-issue-credit", %{
        group_id: "clawback-source",
        occurred_on: "2026-10-04",
        refund_method: "hotel_credit",
        expected_revision: 3
      }),
      open_operation(%{
        operation_id: "clawback-target-open",
        group_id: "clawback-target",
        guest_id: "clawback-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 20_000}]
      }),
      operation("apply_hotel_credit", "clawback-spend", %{
        group_id: "clawback-target",
        amount_cents: 1500,
        occurred_on: "2026-10-05"
      })
    ]

    assert %{"results" => [_, _, _, issued, _, applied]} =
             submit(conn, operations) |> json_response(200)

    assert issued["credit_issued_cents"] == 2211
    assert applied["revision"] == 2

    chargeback =
      operation("charge_back_payment", "chargeback-two", %{
        group_id: "ignored-group-id",
        payment_operation_id: "clawback-payment-two",
        expected_revision: 4
      })
      |> Map.delete(:group_id)

    assert %{"results" => [charged]} = submit(conn, [chargeback]) |> json_response(200)
    assert charged["status"] == "applied"
    assert charged["group_id"] == "clawback-source"
    assert charged["charged_back_cents"] == 1005
    assert charged["revision"] == 5

    assert %{
             "data" => %{
               "credit_shortfall_cents" => 394,
               "credit_liability_cents" => 1500,
               "cash_charged_back_cents" => 1005,
               "cash_converted_to_credit_cents" => 1005
             }
           } =
             get(conn, "/api/v1/ledger?on=2026-10-05") |> json_response(200)

    assert %{"data" => target_after_chargeback} =
             get(conn, "/api/v1/groups/clawback-target") |> json_response(200)

    assert target_after_chargeback["revision"] == 2
    assert target_after_chargeback["credit_paid_cents"] == 1500

    assert %{"results" => [^charged]} = submit(conn, [chargeback]) |> json_response(200)

    assert %{"results" => [restored]} =
             submit(conn, [
               operation("cancel_group", "clawback-restore", %{
                 group_id: "clawback-target",
                 occurred_on: "2026-10-06",
                 expected_revision: 2
               })
             ])
             |> json_response(200)

    assert restored["status"] == "applied"

    assert %{
             "data" => %{
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 1106,
               "cash_charged_back_cents" => 1005,
               "cash_converted_to_credit_cents" => 1005
             }
           } = get(conn, "/api/v1/ledger?on=2026-10-06") |> json_response(200)

    assert %{"data" => payment_statement} =
             get(conn, "/api/v1/payments/clawback-payment-two") |> json_response(200)

    assert payment_statement["converted_to_credit_cents"] == 0
    assert payment_statement["charged_back_cents"] == 1005
  end

  test "payment reconciliation distinguishes missing and non-cash operations", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(conn, "/api/v1/payments/no-such-payment") |> json_response(404)

    assert %{"results" => [_opened, rejected]} =
             submit(conn, [
               open_operation(%{group_id: "not-payment-group"}),
               operation("record_cash_payment", "rejected-payment", %{amount_cents: 0})
             ])
             |> json_response(200)

    assert rejected["status"] == "rejected"

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             get(conn, "/api/v1/payments/rejected-payment") |> json_response(422)
  end

  test "transfers mixed funding in reverse allocation order and preserves settlement provenance",
       %{
         conn: conn
       } do
    setup_operations = [
      open_operation(%{
        operation_id: "transfer-credit-issuer-open",
        group_id: "transfer-credit-issuer",
        guest_id: "transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      }),
      operation("record_cash_payment", "transfer-credit-issuer-payment", %{
        group_id: "transfer-credit-issuer",
        amount_cents: 1000
      }),
      operation("cancel_group", "transfer-credit-issuer-cancel", %{
        group_id: "transfer-credit-issuer",
        occurred_on: "2026-10-04",
        refund_method: "hotel_credit",
        expected_revision: 2
      }),
      open_operation(%{
        operation_id: "transfer-source-open",
        group_id: "transfer-source",
        guest_id: "transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      }),
      operation("record_cash_payment", "transfer-source-payment", %{
        group_id: "transfer-source",
        amount_cents: 1000
      }),
      operation("apply_hotel_credit", "transfer-source-credit", %{
        group_id: "transfer-source",
        amount_cents: 1000,
        occurred_on: "2026-10-04"
      }),
      open_operation(%{
        operation_id: "transfer-destination-open",
        group_id: "transfer-destination",
        guest_id: "transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 10_000},
          %{room_id: "room-b", nightly_rate_cents: 10_000}
        ]
      })
    ]

    assert %{"results" => [_, _, _, _, _, _, _]} =
             submit(conn, setup_operations) |> json_response(200)

    ledger_before_transfer = get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200)

    transfer_op =
      transfer("transfer-source", "transfer-destination", "mixed-funding-transfer", %{
        amount_cents: 1200,
        expected_revision: 3,
        destination_expected_revision: 1
      })

    assert %{"results" => [applied, replayed]} =
             submit(conn, [transfer_op, transfer_op]) |> json_response(200)

    assert replayed == applied

    assert applied == %{
             "operation_id" => "mixed-funding-transfer",
             "status" => "applied",
             "source_group_id" => "transfer-source",
             "destination_group_id" => "transfer-destination",
             "amount_cents" => 1200,
             "source_outstanding_deposit_cents" => 1200,
             "destination_outstanding_deposit_cents" => 2800,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert %{
             "data" => %{
               "cash_paid_cents" => 800,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 1200
             }
           } = get(conn, "/api/v1/groups/transfer-source") |> json_response(200)

    assert %{
             "data" => %{
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "cash_paid_cents" => 200,
                   "credit_paid_cents" => 1000
                 },
                 %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
               ],
               "cash_paid_cents" => 200,
               "credit_paid_cents" => 1000
             }
           } = get(conn, "/api/v1/groups/transfer-destination") |> json_response(200)

    ledger_after_transfer = get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200)
    assert ledger_after_transfer == ledger_before_transfer

    assert %{"data" => payment_before_settlement} =
             get(conn, "/api/v1/payments/transfer-source-payment") |> json_response(200)

    assert payment_before_settlement["held_cents"] == 1000

    assert payment_before_settlement["held_by_group"] == [
             %{"group_id" => "transfer-destination", "amount_cents" => 200},
             %{"group_id" => "transfer-source", "amount_cents" => 800}
           ]

    assert %{"results" => [cancelled]} =
             submit(conn, [
               operation("cancel_group", "transfer-destination-cancel", %{
                 group_id: "transfer-destination",
                 occurred_on: "2026-10-04",
                 refund_method: "hotel_credit",
                 expected_revision: 2
               })
             ])
             |> json_response(200)

    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 220
    assert cancelled["revision"] == 3

    assert %{
             "data" => %{
               "available_cents" => 1320,
               "lots" => lots
             }
           } =
             get(conn, "/api/v1/guests/transfer-guest/credit?on=2026-10-04") |> json_response(200)

    assert Enum.sort(Enum.map(lots, &{&1["source_operation_id"], &1["remaining_cents"]})) ==
             Enum.sort([
               {"transfer-credit-issuer-cancel", 1100},
               {"transfer-destination-cancel", 220}
             ])

    assert %{"data" => payment_after_settlement} =
             get(conn, "/api/v1/payments/transfer-source-payment") |> json_response(200)

    assert payment_after_settlement["held_cents"] == 800
    assert payment_after_settlement["converted_to_credit_cents"] == 200

    assert payment_after_settlement["held_by_group"] == [
             %{"group_id" => "transfer-source", "amount_cents" => 800}
           ]

    assert %{
             "data" => %{
               "cash_held_cents" => 800,
               "cash_converted_to_credit_cents" => 1200,
               "credit_liability_cents" => 1320
             }
           } = get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200)

    assert %{"results" => [charged]} =
             submit(conn, [
               operation("charge_back_payment", "transferred-payment-chargeback", %{
                 payment_operation_id: "transfer-source-payment",
                 expected_revision: 4
               })
               |> Map.delete(:group_id)
             ])
             |> json_response(200)

    assert charged["charged_back_cents"] == 1000
    assert charged["revision"] == 5

    assert %{
             "data" => %{
               "revision" => 4,
               "status" => "cancelled"
             }
           } = get(conn, "/api/v1/groups/transfer-destination") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 1000,
               "cash_charged_back_cents" => 1000,
               "credit_liability_cents" => 1100
             }
           } = get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200)

    assert %{"data" => payment_after_chargeback} =
             get(conn, "/api/v1/payments/transfer-source-payment") |> json_response(200)

    assert payment_after_chargeback["held_cents"] == 0
    assert payment_after_chargeback["converted_to_credit_cents"] == 0
    assert payment_after_chargeback["charged_back_cents"] == 1000
    assert payment_after_chargeback["held_by_group"] == []
  end

  test "reductions and chargebacks follow transferred payment allocations across groups", %{
    conn: conn
  } do
    operations = [
      open_operation(%{
        operation_id: "correction-transfer-source-open",
        group_id: "correction-transfer-source",
        guest_id: "correction-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      }),
      operation("record_cash_payment", "correction-transfer-payment", %{
        group_id: "correction-transfer-source",
        amount_cents: 1000
      }),
      open_operation(%{
        operation_id: "correction-transfer-destination-open",
        group_id: "correction-transfer-destination",
        guest_id: "correction-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      })
    ]

    assert %{"results" => [_, _, _]} = submit(conn, operations) |> json_response(200)

    transfer_op =
      transfer(
        "correction-transfer-source",
        "correction-transfer-destination",
        "correction-transfer-op",
        %{amount_cents: 400, expected_revision: 2, destination_expected_revision: 1}
      )

    assert %{"results" => [moved]} = submit(conn, [transfer_op]) |> json_response(200)
    assert moved["source_revision"] == 3
    assert moved["destination_revision"] == 2

    reduce_op =
      operation("reduce_cash_payment", "cross-group-reduction", %{
        group_id: "unused",
        payment_operation_id: "correction-transfer-payment",
        amount_cents: 100,
        expected_revision: 3
      })
      |> Map.delete(:group_id)

    assert %{"results" => [reduced]} = submit(conn, [reduce_op]) |> json_response(200)
    assert reduced["group_id"] == "correction-transfer-source"
    assert reduced["revision"] == 4
    assert reduced["outstanding_deposit_cents"] == 1400

    assert %{
             "data" => %{
               "revision" => 3,
               "cash_paid_cents" => 300,
               "outstanding_deposit_cents" => 1700
             }
           } = get(conn, "/api/v1/groups/correction-transfer-destination") |> json_response(200)

    chargeback_op =
      operation("charge_back_payment", "cross-group-chargeback", %{
        group_id: "unused",
        payment_operation_id: "correction-transfer-payment",
        expected_revision: 4
      })
      |> Map.delete(:group_id)

    assert %{"results" => [charged]} = submit(conn, [chargeback_op]) |> json_response(200)
    assert charged["group_id"] == "correction-transfer-source"
    assert charged["charged_back_cents"] == 900
    assert charged["revision"] == 5

    assert %{
             "data" => %{
               "revision" => 4,
               "cash_paid_cents" => 0,
               "deposit_paid_cents" => 0
             }
           } = get(conn, "/api/v1/groups/correction-transfer-destination") |> json_response(200)

    assert %{"data" => statement} =
             get(conn, "/api/v1/payments/correction-transfer-payment") |> json_response(200)

    assert statement["held_cents"] == 0
    assert statement["reduced_cents"] == 100
    assert statement["charged_back_cents"] == 900
    assert statement["held_by_group"] == []

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_reduced_cents" => 100,
               "cash_charged_back_cents" => 900
             }
           } = get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200)
  end

  test "transfer lookup and revision validation precede transfer domain rules", %{conn: conn} do
    groups = [
      open_operation(%{
        operation_id: "transfer-validation-source-open",
        group_id: "transfer-validation-source",
        guest_id: "transfer-validation-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      }),
      operation("record_cash_payment", "transfer-validation-payment", %{
        group_id: "transfer-validation-source",
        amount_cents: 1000
      }),
      open_operation(%{
        operation_id: "transfer-validation-destination-open",
        group_id: "transfer-validation-destination",
        guest_id: "transfer-validation-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "room-small", nightly_rate_cents: 100}]
      }),
      open_operation(%{
        operation_id: "transfer-validation-other-open",
        group_id: "transfer-validation-other",
        guest_id: "other-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      })
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, groups) |> json_response(200)

    checks = [
      {transfer("missing-transfer-source", "transfer-validation-destination", "missing-source"),
       "group_not_found", "missing-transfer-source"},
      {transfer("transfer-validation-source", "missing-transfer-destination", "missing-dest"),
       "group_not_found", "missing-transfer-destination"},
      {transfer("transfer-validation-source", "transfer-validation-source", "same-group"),
       "invalid_transfer", nil},
      {transfer("transfer-validation-source", "transfer-validation-other", "different-guest"),
       "invalid_transfer", nil},
      {transfer(
         "transfer-validation-source",
         "transfer-validation-destination",
         "stale-source",
         %{
           amount_cents: 1,
           expected_revision: 1,
           destination_expected_revision: 0
         }
       ), "stale_revision", "transfer-validation-source"},
      {transfer("transfer-validation-source", "transfer-validation-destination", "stale-dest", %{
         amount_cents: 1,
         expected_revision: 2,
         destination_expected_revision: 0
       }), "stale_revision", "transfer-validation-destination"},
      {transfer("transfer-validation-source", "transfer-validation-destination", "bad-amount", %{
         amount_cents: 0
       }), "invalid_amount", nil},
      {transfer(
         "transfer-validation-source",
         "transfer-validation-destination",
         "too-much-held",
         %{
           amount_cents: 1001
         }
       ), "transfer_exceeds_held_funding", nil},
      {transfer(
         "transfer-validation-source",
         "transfer-validation-destination",
         "too-much-outstanding",
         %{
           amount_cents: 21
         }
       ), "transfer_exceeds_outstanding", nil}
    ]

    assert %{"results" => results} =
             submit(conn, Enum.map(checks, &elem(&1, 0))) |> json_response(200)

    Enum.zip(results, checks)
    |> Enum.each(fn {result, {_operation, expected_code, expected_group_id}} ->
      assert result["code"] == expected_code

      if expected_group_id do
        assert result["group_id"] == expected_group_id
      end
    end)

    assert %{"results" => [cancel_source]} =
             submit(conn, [
               operation("cancel_group", "transfer-validation-cancel-source", %{
                 group_id: "transfer-validation-source",
                 occurred_on: "2026-10-04",
                 expected_revision: 2
               })
             ])
             |> json_response(200)

    assert cancel_source["status"] == "applied"

    assert %{"results" => [inactive_source]} =
             submit(conn, [
               transfer(
                 "transfer-validation-source",
                 "transfer-validation-destination",
                 "inactive-source",
                 %{
                   amount_cents: 1
                 }
               )
             ])
             |> json_response(200)

    assert inactive_source["code"] == "group_not_active"
    assert inactive_source["group_id"] == "transfer-validation-source"

    assert %{"results" => [_, funded]} =
             submit(conn, [
               open_operation(%{
                 operation_id: "transfer-validation-second-open",
                 group_id: "transfer-validation-second-source",
                 guest_id: "transfer-validation-guest",
                 arrival_on: "2027-01-20",
                 departure_on: "2027-01-21"
               }),
               operation("record_cash_payment", "transfer-validation-second-payment", %{
                 group_id: "transfer-validation-second-source",
                 amount_cents: 100
               })
             ])
             |> json_response(200)

    assert funded["status"] == "applied"

    assert %{"results" => [cancel_destination]} =
             submit(conn, [
               operation("cancel_group", "transfer-validation-cancel-destination", %{
                 group_id: "transfer-validation-destination",
                 occurred_on: "2026-10-04",
                 expected_revision: 1
               })
             ])
             |> json_response(200)

    assert cancel_destination["status"] == "applied"

    assert %{"results" => [inactive_destination]} =
             submit(conn, [
               transfer(
                 "transfer-validation-second-source",
                 "transfer-validation-destination",
                 "inactive-destination",
                 %{amount_cents: 1}
               )
             ])
             |> json_response(200)

    assert inactive_destination["code"] == "group_not_active"
    assert inactive_destination["group_id"] == "transfer-validation-destination"
  end

  test "a later transfer follows the order of mixed allocations at its source", %{conn: conn} do
    setup = [
      open_operation(%{
        operation_id: "ordered-transfer-issuer-open",
        group_id: "ordered-transfer-issuer",
        guest_id: "ordered-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21"
      }),
      operation("record_cash_payment", "ordered-transfer-issuer-payment", %{
        group_id: "ordered-transfer-issuer",
        amount_cents: 1000
      }),
      operation("cancel_group", "ordered-transfer-issuer-cancel", %{
        group_id: "ordered-transfer-issuer",
        occurred_on: "2026-10-04",
        refund_method: "hotel_credit",
        expected_revision: 2
      }),
      open_operation(%{
        operation_id: "ordered-transfer-source-open",
        group_id: "ordered-transfer-source",
        guest_id: "ordered-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "room-source", nightly_rate_cents: 20_000}]
      }),
      operation("record_cash_payment", "ordered-transfer-source-payment", %{
        group_id: "ordered-transfer-source",
        amount_cents: 1000
      }),
      operation("apply_hotel_credit", "ordered-transfer-source-credit", %{
        group_id: "ordered-transfer-source",
        amount_cents: 1000,
        occurred_on: "2026-10-04"
      }),
      open_operation(%{
        operation_id: "ordered-transfer-middle-open",
        group_id: "ordered-transfer-middle",
        guest_id: "ordered-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "room-middle", nightly_rate_cents: 10_000}]
      }),
      open_operation(%{
        operation_id: "ordered-transfer-final-open",
        group_id: "ordered-transfer-final",
        guest_id: "ordered-transfer-guest",
        arrival_on: "2027-01-20",
        departure_on: "2027-01-21",
        rooms: [%{room_id: "room-final", nightly_rate_cents: 10_000}]
      })
    ]

    assert %{"results" => [_, _, _, _, _, _, _, _]} = submit(conn, setup) |> json_response(200)
    ledger_before = get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200)

    first_transfer =
      transfer("ordered-transfer-source", "ordered-transfer-middle", "ordered-transfer-one", %{
        amount_cents: 1200,
        expected_revision: 3,
        destination_expected_revision: 1
      })

    assert %{"results" => [%{"status" => "applied", "source_revision" => 4}]} =
             submit(conn, [first_transfer]) |> json_response(200)

    second_transfer =
      transfer("ordered-transfer-middle", "ordered-transfer-final", "ordered-transfer-two", %{
        amount_cents: 300,
        expected_revision: 2,
        destination_expected_revision: 1
      })

    assert %{"results" => [second]} = submit(conn, [second_transfer]) |> json_response(200)
    assert second["source_revision"] == 3
    assert second["destination_revision"] == 2

    assert %{
             "data" => %{
               "rooms" => [
                 %{
                   "room_id" => "room-final",
                   "cash_paid_cents" => 200,
                   "credit_paid_cents" => 100
                 }
               ]
             }
           } = get(conn, "/api/v1/groups/ordered-transfer-final") |> json_response(200)

    assert %{
             "data" => %{
               "rooms" => [
                 %{
                   "room_id" => "room-middle",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 900
                 }
               ]
             }
           } = get(conn, "/api/v1/groups/ordered-transfer-middle") |> json_response(200)

    assert get(conn, "/api/v1/ledger?on=2026-10-04") |> json_response(200) == ledger_before

    reduction =
      operation("reduce_cash_payment", "ordered-transfer-reduction", %{
        group_id: "unused",
        payment_operation_id: "ordered-transfer-source-payment",
        amount_cents: 100,
        expected_revision: 4
      })
      |> Map.delete(:group_id)

    assert %{"results" => [reduced]} = submit(conn, [reduction]) |> json_response(200)
    assert reduced["group_id"] == "ordered-transfer-source"
    assert reduced["revision"] == 5

    assert %{"data" => %{"revision" => 3}} =
             get(conn, "/api/v1/groups/ordered-transfer-middle") |> json_response(200)

    assert %{
             "data" => %{
               "revision" => 3,
               "rooms" => [
                 %{
                   "room_id" => "room-final",
                   "cash_paid_cents" => 100,
                   "credit_paid_cents" => 100
                 }
               ]
             }
           } = get(conn, "/api/v1/groups/ordered-transfer-final") |> json_response(200)
  end
end
