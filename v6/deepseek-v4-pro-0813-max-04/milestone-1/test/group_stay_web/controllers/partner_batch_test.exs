defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_group(conn, group_id),
    do: json_response(get(conn, ~p"/api/v1/groups/#{group_id}"), 200)["data"]

  defp ledger(conn), do: json_response(get(conn, ~p"/api/v1/ledger"), 200)["data"]

  describe "opening groups" do
    test "applies the flexible example from the API document" do
      conn = build_conn()

      assert batch_results(conn, [open()]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
    end

    test "charges advance purchase rooms their full lodging amount" do
      conn = build_conn()

      assert batch_results(conn, [open(%{"rate_plan" => "advance_purchase"})]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 97_500,
                 "revision" => 1
               }
             ]
    end

    test "rounds each room deposit separately before summing" do
      conn = build_conn()

      op =
        open(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_502},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10_502}
          ]
        })

      # Each room deposit rounds to 2100 (2100.4); rounding the combined total
      # would give 4201, so this pins the per-room rounding rule.
      assert batch_results(conn, [op]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 4_200,
                 "revision" => 1
               }
             ]

      assert get_group(conn, "group-81")["lodging_total_cents"] == 21_004
    end

    test "rejects a duplicate group id with group_already_exists and continues" do
      conn = build_conn()

      [applied, rejected] = batch_results(conn, [open(), open(%{"operation_id" => "op-open-2"})])

      assert applied["status"] == "applied"
      assert applied["revision"] == 1

      assert rejected == %{
               "operation_id" => "op-open-2",
               "status" => "rejected",
               "code" => "group_already_exists"
             }
    end

    test "rejects stays without at least one night" do
      conn = build_conn()

      same_day = open(%{"departure_on" => "2026-12-10"})
      backwards = open(%{"departure_on" => "2026-12-09"})

      assert batch_results(conn, [same_day, backwards]) == [
               %{"operation_id" => "op-open", "status" => "rejected", "code" => "invalid_stay"},
               %{"operation_id" => "op-open", "status" => "rejected", "code" => "invalid_stay"}
             ]
    end

    test "rejects unusable stay dates with invalid_stay" do
      conn = build_conn()

      assert batch_results(conn, [open(%{"arrival_on" => "2026-02-30"})]) == [
               %{"operation_id" => "op-open", "status" => "rejected", "code" => "invalid_stay"}
             ]
    end

    test "rejects empty room lists with invalid_rooms" do
      conn = build_conn()

      assert batch_results(conn, [open(%{"rooms" => []})]) == [
               %{"operation_id" => "op-open", "status" => "rejected", "code" => "invalid_rooms"}
             ]
    end

    test "rejects duplicate room ids with invalid_rooms" do
      conn = build_conn()

      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
      ]

      assert batch_results(conn, [open(%{"rooms" => rooms})]) == [
               %{"operation_id" => "op-open", "status" => "rejected", "code" => "invalid_rooms"}
             ]
    end

    test "rejects unknown rate plans with invalid_rate_plan" do
      conn = build_conn()

      assert batch_results(conn, [open(%{"rate_plan" => "half-board"})]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "rejected",
                 "code" => "invalid_rate_plan"
               }
             ]
    end

    test "stores the operation date as the booked_on date" do
      conn = build_conn()

      post_batch(conn, [open(%{"occurred_on" => "2026-11-01"})])

      assert get_group(conn, "group-81")["booked_on"] == "2026-11-01"
    end

    test "ignores expected_revision on open_group" do
      conn = build_conn()

      assert batch_results(conn, [open(%{"expected_revision" => 9})])
             |> hd()
             |> Map.fetch!("status") ==
               "applied"
    end
  end

  describe "recording cash" do
    test "applies cash to the outstanding deposit" do
      conn = build_conn()

      assert batch_results(conn, [open(), payment()]) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               }
             ]

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 10_000
      assert get_group(conn, "group-81")["outstanding_deposit_cents"] == 9_500
      assert ledger(conn)["cash_held_cents"] == 10_000
    end

    test "rejects payments for missing groups with group_not_found" do
      conn = build_conn()

      assert batch_results(conn, [payment()]) == [
               %{"operation_id" => "op-pay", "status" => "rejected", "code" => "group_not_found"}
             ]
    end

    test "rejects payments for cancelled groups with group_not_active" do
      conn = build_conn()

      batch_results = batch_results(conn, [open(), cancel(), payment()])

      assert batch_results |> Enum.map(& &1["code"]) |> Enum.take(-1) == ["group_not_active"]
    end

    test "rejects unusable amounts with invalid_amount" do
      conn = build_conn()

      zeros = payment(%{"operation_id" => "zero", "amount_cents" => 0})
      negatives = payment(%{"operation_id" => "neg", "amount_cents" => -100})
      strings = payment(%{"operation_id" => "str", "amount_cents" => "100"})

      assert batch_results(conn, [open(), zeros, negatives, strings])
             |> Enum.drop(1) ==
               [
                 %{"operation_id" => "zero", "status" => "rejected", "code" => "invalid_amount"},
                 %{"operation_id" => "neg", "status" => "rejected", "code" => "invalid_amount"},
                 %{"operation_id" => "str", "status" => "rejected", "code" => "invalid_amount"}
               ]
    end

    test "rejects payments above the outstanding deposit" do
      conn = build_conn()

      over = payment(%{"amount_cents" => 20_000})

      assert batch_results(conn, [open(), over]) |> Enum.drop(1) == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               }
             ]

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 0
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "honours a matching expected_revision" do
      conn = build_conn()

      second =
        payment(%{
          "operation_id" => "op-pay-2",
          "amount_cents" => 5_000,
          "expected_revision" => 2
        })

      assert batch_results(conn, [open(), payment(), second]) |> Enum.drop(1) == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "op-pay-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 4_500,
                 "revision" => 3
               }
             ]
    end

    test "accepts a payment that exactly clears the outstanding deposit" do
      conn = build_conn()

      full = payment(%{"amount_cents" => 19_500})

      assert batch_results(conn, [open(), full]) |> Enum.drop(1) == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 19_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 2
               }
             ]

      assert ledger(conn)["cash_held_cents"] == 19_500
    end

    test "rejects a stale revision with the documented fields and leaves the ledger unchanged" do
      conn = build_conn()

      stale =
        payment(%{
          "operation_id" => "op-stale",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        })

      follow_up = payment(%{"operation_id" => "op-follow", "amount_cents" => 2_000})

      results = batch_results(conn, [open(), payment(), stale, follow_up])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert Enum.at(results, 3)["status"] == "applied"
      assert Enum.at(results, 3)["revision"] == 3

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 12_000
      assert get_group(conn, "group-81")["revision"] == 3
    end

    test "checks a stale revision before other domain rules" do
      conn = build_conn()

      bad_and_stale =
        payment(%{"operation_id" => "op-bad", "amount_cents" => -10, "expected_revision" => 1})

      assert batch_results(conn, [open(), payment(), bad_and_stale]) |> Enum.at(2) == %{
               "operation_id" => "op-bad",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "resolves group existence before comparing revisions" do
      conn = build_conn()

      missing = payment(%{"group_id" => "no-such-group", "expected_revision" => 1})

      assert batch_results(conn, [missing]) == [
               %{"operation_id" => "op-pay", "status" => "rejected", "code" => "group_not_found"}
             ]
    end
  end

  describe "rescheduling" do
    test "moves the stay and keeps its length and price" do
      conn = build_conn()

      assert batch_results(conn, [open(), reschedule()]) |> Enum.drop(1) == [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-17",
                 "new_departure_on" => "2026-12-20",
                 "revision" => 2
               }
             ]

      group = get_group(conn, "group-81")
      assert group["arrival_on"] == "2026-12-17"
      assert group["departure_on"] == "2026-12-20"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "still increments the revision when the dates do not change" do
      conn = build_conn()

      same_day = reschedule(%{"new_arrival_on" => "2026-12-10"})

      assert batch_results(conn, [open(), same_day]) |> Enum.drop(1) == [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-10",
                 "new_departure_on" => "2026-12-13",
                 "revision" => 2
               }
             ]
    end

    test "rejects arrivals on or before the operation date with invalid_stay" do
      conn = build_conn()

      on_op_date = reschedule(%{"operation_id" => "on-date", "new_arrival_on" => "2026-10-10"})

      before_op_date =
        reschedule(%{"operation_id" => "before-date", "new_arrival_on" => "2026-10-09"})

      unfixable = reschedule(%{"operation_id" => "bad-date", "new_arrival_on" => "2026-02-30"})

      assert batch_results(conn, [open(), on_op_date, before_op_date, unfixable]) |> Enum.drop(1) ==
               [
                 %{"operation_id" => "on-date", "status" => "rejected", "code" => "invalid_stay"},
                 %{
                   "operation_id" => "before-date",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{"operation_id" => "bad-date", "status" => "rejected", "code" => "invalid_stay"}
               ]
    end

    test "rejects a stale revision on reschedules" do
      conn = build_conn()

      stale = reschedule(%{"operation_id" => "op-stale-move", "expected_revision" => 2})

      assert batch_results(conn, [open(), stale]) |> Enum.at(1) == %{
               "operation_id" => "op-stale-move",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 1
             }

      assert get_group(conn, "group-81")["arrival_on"] == "2026-12-10"
    end

    test "rejects reschedules for missing or cancelled groups" do
      conn = build_conn()

      missing = reschedule(%{"group_id" => "no-such-group"})
      after_cancel = reschedule(%{"operation_id" => "move-after-cancel"})

      assert batch_results(conn, [missing, open(), cancel(), after_cancel]) == [
               %{
                 "operation_id" => "op-move",
                 "status" => "rejected",
                 "code" => "group_not_found"
               },
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 2
               },
               %{
                 "operation_id" => "move-after-cancel",
                 "status" => "rejected",
                 "code" => "group_not_active"
               }
             ]
    end
  end

  describe "cancelling groups" do
    test "refunds paid cash when a flexible stay is cancelled early" do
      conn = build_conn()

      results = batch_results(conn, [open(), payment(), cancel()])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 3
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      assert group["deposit_paid_cents"] == 10_000

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0
             }
    end

    test "retains paid cash when a flexible stay is cancelled late" do
      conn = build_conn()

      late = cancel(%{"occurred_on" => "2026-12-05"})

      results = batch_results(conn, [open(), payment(), late])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 10_000
             }
    end

    test "always retains paid cash for advance purchase stays" do
      conn = build_conn()

      advance = open(%{"rate_plan" => "advance_purchase"})

      results = batch_results(conn, [advance, payment(), cancel()])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "revision" => 3
             }
    end

    test "treats cancellation exactly 14 days before arrival as refundable" do
      conn = build_conn()

      exact = cancel(%{"occurred_on" => "2026-11-26"})

      results = batch_results(conn, [open(), payment(), exact])

      assert Enum.at(results, 2)["refunded_cents"] == 10_000
      assert Enum.at(results, 2)["retained_cents"] == 0
    end

    test "releases unpaid deposit on cancellation" do
      conn = build_conn()

      batch_results(conn, [open(), cancel()])

      group = get_group(conn, "group-81")
      assert group["outstanding_deposit_cents"] == 0
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 0
    end

    test "rejects a stale revision on cancellations without touching the group" do
      conn = build_conn()

      stale = cancel(%{"operation_id" => "op-stale-cancel", "expected_revision" => 1})

      results = batch_results(conn, [open(), cancel(), stale])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-stale-cancel",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert get_group(conn, "group-81")["revision"] == 2
    end

    test "rejects later operations on cancelled groups with group_not_active" do
      conn = build_conn()

      later_payment = payment(%{"operation_id" => "late-pay"})
      later_move = reschedule(%{"operation_id" => "late-move"})
      later_cancel = cancel(%{"operation_id" => "late-cancel"})

      results = batch_results(conn, [open(), cancel(), later_payment, later_move, later_cancel])

      assert results |> Enum.drop(2) |> Enum.map(& &1["code"]) ==
               ["group_not_active", "group_not_active", "group_not_active"]
    end
  end

  describe "batch processing" do
    test "operations observe earlier operations in the same batch" do
      conn = build_conn()

      expected = payment(%{"expected_revision" => 1})

      results = batch_results(conn, [open(), expected])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
      assert Enum.at(results, 1)["revision"] == 2
    end

    test "a rejected operation leaves the database unchanged and does not stop later operations" do
      conn = build_conn()

      over = payment(%{"operation_id" => "over", "amount_cents" => 20_000})
      ok = payment(%{"operation_id" => "ok", "amount_cents" => 1_000})

      results = batch_results(conn, [open(), over, ok])

      assert Enum.at(results, 1)["code"] == "payment_exceeds_outstanding"
      assert Enum.at(results, 2)["status"] == "applied"

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 1_000
      assert get_group(conn, "group-81")["revision"] == 2
    end

    test "rejects unknown operation types with invalid_operation and continues" do
      conn = build_conn()

      mystery = %{"operation_id" => "unknown-op", "type" => "close_group"}

      results = batch_results(conn, [mystery, open()])

      assert hd(results) == %{
               "operation_id" => "unknown-op",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert Enum.at(results, 1)["status"] == "applied"
    end

    test "rejects operations missing required data with invalid_operation" do
      conn = build_conn()

      no_type = %{"operation_id" => "no-type", "occurred_on" => "2026-10-03"}
      no_amount = payment(%{"operation_id" => "no-amount"}) |> Map.delete("amount_cents")
      no_rooms = open(%{"operation_id" => "no-rooms"}) |> Map.delete("rooms")
      no_dates = open(%{"operation_id" => "no-dates"}) |> Map.delete("arrival_on")
      no_id = %{"type" => "cancel_group", "occurred_on" => "2026-10-03"}
      not_a_map = "hello"

      assert batch_results(conn, [no_type, no_amount, no_rooms, no_dates, no_id, not_a_map]) == [
               %{
                 "operation_id" => "no-type",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "no-amount",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "no-rooms",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "no-dates",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"},
               %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
             ]

      assert get(conn, ~p"/api/v1/groups/group-81").status == 404
    end

    test "returns one empty results array for an empty operations array" do
      conn = build_conn()

      assert json_response(post_batch(conn, []), 200) == %{"results" => []}
    end

    test "returns 422 invalid_batch for bodies that are not objects with an operations array" do
      for payload <- [%{}, %{"nope" => true}, %{"operations" => "x"}, []] do
        conn = build_conn()
        conn = put_req_header(conn, "content-type", "application/json")
        conn = post(conn, ~p"/api/v1/partner-batches", Jason.encode!(payload))

        assert conn.status == 422
        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end

      # A body that is valid JSON but not an object at all.
      conn = build_conn()
      conn = put_req_header(conn, "content-type", "application/json")
      conn = post(conn, ~p"/api/v1/partner-batches", ~s("just a string"))

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end
end
