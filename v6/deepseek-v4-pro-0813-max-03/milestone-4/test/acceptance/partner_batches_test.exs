defmodule GroupStayWeb.PartnerBatchesTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp submit_batch_status(conn, body) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
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

  defp read_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  describe "open_group" do
    test "applies an open_group and reports the group deposit", %{conn: conn} do
      assert %{"results" => [result]} = submit_batch(conn, [open()])

      assert result == %{
               "operation_id" => "op-1",
               "status" => "applied",
               "group_id" => "g-1",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      assert %{"data" => group} = read_group(conn, "g-1")

      assert %{
               "group_id" => "g-1",
               "guest_id" => "guest-1",
               "property_id" => "prop-1",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             } = group

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "rounds each flexible room deposit separately before summing", %{conn: conn} do
      op =
        open(%{
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "r1", "nightly_rate_cents" => 101},
            %{"room_id" => "r2", "nightly_rate_cents" => 101},
            %{"room_id" => "r3", "nightly_rate_cents" => 101}
          ]
        })

      assert %{"results" => [%{"deposit_due_cents" => 60}]} = submit_batch(conn, [op])
    end

    test "advance purchase requires the full lodging amount as deposit", %{conn: conn} do
      op =
        open(%{
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-12",
          "rooms" => [
            %{"room_id" => "r1", "nightly_rate_cents" => 10_000},
            %{"room_id" => "r2", "nightly_rate_cents" => 15_500}
          ]
        })

      assert %{"results" => [%{"deposit_due_cents" => 51_000}]} = submit_batch(conn, [op])
    end

    test "rejects a group id that already exists", %{conn: conn} do
      assert %{"results" => [%{"status" => "applied"}]} = submit_batch(conn, [open()])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_already_exists"}]} =
               submit_batch(conn, [open(%{"operation_id" => "op-2"})])

      assert Repo.aggregate(Group, :count, :id) == 1
      assert %{"data" => %{"deposit_due_cents" => 19_500}} = read_group(conn, "g-1")
    end

    test "rejects stays with fewer than one night", %{conn: conn} do
      for {op, index} <-
            Enum.with_index([
              open(%{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"}),
              open(%{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-05"})
            ]) do
        op = Map.put(op, "operation_id", "op-bad-#{index}")

        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
                 submit_batch(conn, [op])
      end

      assert Repo.aggregate(Group, :count, :id) == 0
    end

    test "rejects unparseable stay dates", %{conn: conn} do
      op = open(%{"arrival_on" => "not-a-date"})
      assert %{"results" => [%{"code" => "invalid_stay"}]} = submit_batch(conn, [op])
    end

    test "rejects empty rooms", %{conn: conn} do
      op = open(%{"rooms" => []})
      assert %{"results" => [%{"code" => "invalid_rooms"}]} = submit_batch(conn, [op])
    end

    test "rejects duplicate room identifiers within a group", %{conn: conn} do
      op =
        open(%{
          "rooms" => [
            %{"room_id" => "r", "nightly_rate_cents" => 100},
            %{"room_id" => "r", "nightly_rate_cents" => 200}
          ]
        })

      assert %{"results" => [%{"code" => "invalid_rooms"}]} = submit_batch(conn, [op])
    end

    test "rejects rooms with unusable rates or missing identifiers", %{conn: conn} do
      for {rooms, index} <-
            Enum.with_index([
              [%{"room_id" => "r", "nightly_rate_cents" => 0}],
              [%{"room_id" => "r", "nightly_rate_cents" => -100}],
              [%{"room_id" => "r"}],
              [%{"nightly_rate_cents" => 100}]
            ]) do
        op = open(%{"rooms" => rooms, "operation_id" => "op-bad-#{index}"})
        assert %{"results" => [%{"code" => "invalid_rooms"}]} = submit_batch(conn, [op])
      end
    end

    test "rejects unknown rate plans", %{conn: conn} do
      op = open(%{"rate_plan" => "half-board"})
      assert %{"results" => [%{"code" => "invalid_rate_plan"}]} = submit_batch(conn, [op])
    end

    test "ignores expected_revision", %{conn: conn} do
      op = open(%{"expected_revision" => 42})

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               submit_batch(conn, [op])
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      open_op = open()

      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 10_000
      }

      assert %{"results" => [_, payment]} = submit_batch(conn, [open_op, pay])

      assert payment == %{
               "operation_id" => "op-2",
               "status" => "applied",
               "group_id" => "g-1",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }

      assert %{"data" => %{"deposit_paid_cents" => 10_000, "outstanding_deposit_cents" => 9_500}} =
               read_group(conn, "g-1")
    end

    test "allows paying off the full outstanding deposit", %{conn: conn} do
      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 19_500
      }

      assert %{"results" => [_, %{"status" => "applied", "outstanding_deposit_cents" => 0}]} =
               submit_batch(conn, [open(), pay])
    end

    test "rejects payments that exceed the outstanding deposit", %{conn: conn} do
      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 20_000
      }

      assert %{
               "results" => [
                 _,
                 %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
               ]
             } =
               submit_batch(conn, [open(), pay])

      assert %{"data" => %{"deposit_paid_cents" => 0, "outstanding_deposit_cents" => 19_500}} =
               read_group(conn, "g-1")
    end

    test "rejects amounts that cannot be used as a payment", %{conn: conn} do
      for {amount, index} <- Enum.with_index([0, -100]) do
        pay = %{
          "operation_id" => "op-2-#{index}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "g-1",
          "amount_cents" => amount
        }

        assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_amount"}]} =
                 submit_batch(conn, [open(), pay])
      end
    end

    test "rejects payments to a missing group", %{conn: conn} do
      pay = %{
        "operation_id" => "op-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "unknown",
        "amount_cents" => 100
      }

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               submit_batch(conn, [pay])
    end

    test "rejects payments to a cancelled group", %{conn: conn} do
      cancel = %{
        "operation_id" => "op-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "g-1"
      }

      pay = %{
        "operation_id" => "op-3",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-27",
        "group_id" => "g-1",
        "amount_cents" => 100
      }

      assert %{"results" => [_, _, %{"status" => "rejected", "code" => "group_not_active"}]} =
               submit_batch(conn, [open(), cancel, pay])
    end
  end

  describe "reschedule_group" do
    test "shifts the departure by the same number of days", %{conn: conn} do
      move = %{
        "operation_id" => "op-2",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "new_arrival_on" => "2026-12-17"
      }

      assert %{"results" => [_, moved]} = submit_batch(conn, [open(), move])

      assert moved == %{
               "operation_id" => "op-2",
               "status" => "applied",
               "group_id" => "g-1",
               "new_arrival_on" => "2026-12-17",
               "new_departure_on" => "2026-12-20",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-03",
               "revision" => 2
             }

      assert %{"data" => %{"arrival_on" => "2026-12-17", "departure_on" => "2026-12-20"}} =
               read_group(conn, "g-1")
    end

    test "increments the revision even when the dates do not change", %{conn: conn} do
      move = %{
        "operation_id" => "op-2",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "new_arrival_on" => "2026-12-10"
      }

      assert %{"results" => [_, %{"status" => "applied", "revision" => 2}]} =
               submit_batch(conn, [open(), move])

      assert %{"data" => %{"revision" => 2, "arrival_on" => "2026-12-10"}} =
               read_group(conn, "g-1")
    end

    test "rejects a new arrival that is not after the operation date", %{conn: conn} do
      for {new_arrival, index} <- Enum.with_index(["2026-10-03", "2026-10-01"]) do
        move = %{
          "operation_id" => "op-2-#{index}",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "g-1",
          "new_arrival_on" => new_arrival
        }

        assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_stay"}]} =
                 submit_batch(conn, [open(), move])
      end
    end

    test "rejects unusable new arrival dates", %{conn: conn} do
      move = %{
        "operation_id" => "op-2",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "new_arrival_on" => "soon"
      }

      assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_stay"}]} =
               submit_batch(conn, [open(), move])
    end

    test "rejects rescheduling a cancelled group", %{conn: conn} do
      cancel = %{
        "operation_id" => "op-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "g-1"
      }

      move = %{
        "operation_id" => "op-3",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "g-1",
        "new_arrival_on" => "2026-12-17"
      }

      assert %{"results" => [_, _, %{"status" => "rejected", "code" => "group_not_active"}]} =
               submit_batch(conn, [open(), cancel, move])
    end
  end

  describe "cancel_group" do
    test "refunds flexible cash when cancelled at least 14 days before arrival", %{conn: conn} do
      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 10_000
      }

      cancel = %{
        "operation_id" => "op-3",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "g-1"
      }

      assert %{"results" => [_, _, cancelled]} = submit_batch(conn, [open(), pay, cancel])

      assert cancelled == %{
               "operation_id" => "op-3",
               "status" => "applied",
               "group_id" => "g-1",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "outstanding_deposit_cents" => 0,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
                 ]
               }
             } =
               read_group(conn, "g-1")
    end

    test "retains flexible cash when cancelled inside 14 days", %{conn: conn} do
      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 10_000
      }

      cancel = %{
        "operation_id" => "op-3",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "g-1"
      }

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000}
               ]
             } =
               submit_batch(conn, [open(), pay, cancel])
    end

    test "never refunds advance purchase reservations", %{conn: conn} do
      advance = open(%{"rate_plan" => "advance_purchase"})

      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 10_000
      }

      cancel = %{
        "operation_id" => "op-3",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "g-1"
      }

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000}
               ]
             } =
               submit_batch(conn, [advance, pay, cancel])
    end

    test "cancels a group with no deposit collected", %{conn: conn} do
      cancel = %{
        "operation_id" => "op-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "g-1"
      }

      assert %{
               "results" => [
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "revision" => 2
                 }
               ]
             } =
               submit_batch(conn, [open(), cancel])
    end

    test "rejects a second cancellation", %{conn: conn} do
      cancel = %{
        "operation_id" => "op-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "g-1"
      }

      again = %{
        "operation_id" => "op-3",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "g-1"
      }

      assert %{"results" => [_, _, %{"status" => "rejected", "code" => "group_not_active"}]} =
               submit_batch(conn, [open(), cancel, again])
    end
  end

  describe "batch processing" do
    test "rejects an unknown operation type and continues with the next operation", %{conn: conn} do
      unknown = %{"operation_id" => "op-x", "type" => "teleport", "occurred_on" => "2026-10-03"}

      assert %{"results" => [first, second]} =
               submit_batch(conn, [unknown, open(%{"operation_id" => "op-2"})])

      assert first == %{
               "operation_id" => "op-x",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert second["status"] == "applied"
    end

    test "rejects operations missing required data and continues", %{conn: conn} do
      incomplete = %{
        "operation_id" => "op-x",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1"
      }

      assert %{"results" => [first, second]} =
               submit_batch(conn, [incomplete, open(%{"operation_id" => "op-2"})])

      assert first == %{
               "operation_id" => "op-x",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert second["status"] == "applied"
    end

    test "rejects an operation without an operation id", %{conn: conn} do
      op = open(%{"operation_id" => 12345})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               submit_batch(conn, [op])
    end

    test "rejects an operation entry that is not an object", %{conn: conn} do
      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               submit_batch(conn, ["open now"])
    end

    test "returns invalid_batch when the operations array is missing", %{conn: conn} do
      for body <- [%{}, %{"operations" => "nope"}, %{"operations" => nil}] do
        conn_response = submit_batch_status(conn, body)
        assert conn_response.status == 422
        assert json_response(conn_response, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "empties the batch accepts an empty operations array", %{conn: conn} do
      assert submit_batch(conn, []) == %{"results" => []}
    end

    test "later operations observe changes from earlier operations", %{conn: conn} do
      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 5_000
      }

      assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
               submit_batch(conn, [open(), pay])
    end
  end

  describe "revision contract" do
    test "honors expected_revision and reports stale revisions", %{conn: conn} do
      pay1 = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      }

      pay_stale = %{
        "operation_id" => "op-3",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      }

      pay2 = %{
        "operation_id" => "op-4",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 5_000,
        "expected_revision" => 2
      }

      pay3 = %{
        "operation_id" => "op-5",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 4_500
      }

      assert %{"results" => [_, applied, stale, applied2, applied3]} =
               submit_batch(conn, [open(), pay1, pay_stale, pay2, pay3])

      assert applied["revision"] == 2

      assert stale == %{
               "operation_id" => "op-3",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g-1",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert applied2["revision"] == 3
      assert applied3["revision"] == 4

      assert %{"data" => %{"revision" => 4, "deposit_paid_cents" => 14_500}} =
               read_group(conn, "g-1")
    end

    test "stale rejection leaves the group and ledger unchanged", %{conn: conn} do
      stale = %{
        "operation_id" => "op-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "g-1",
        "expected_revision" => 7
      }

      assert %{"results" => [_, %{"code" => "stale_revision"}]} =
               submit_batch(conn, [open(), stale])

      assert %{"data" => %{"status" => "active", "revision" => 1}} = read_group(conn, "g-1")

      assert json_response(get(conn, "/api/v1/ledger"), 200) ==
               %{
                 "data" => %{
                   "cash_held_cents" => 0,
                   "cash_refunded_cents" => 0,
                   "cash_retained_cents" => 0,
                   "cash_converted_to_credit_cents" => 0,
                   "credit_liability_cents" => 0,
                   "cash_reduced_cents" => 0,
                   "cash_charged_back_cents" => 0,
                   "credit_shortfall_cents" => 0
                 }
               }
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      move = %{
        "operation_id" => "op-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "missing",
        "new_arrival_on" => "2026-12-17",
        "expected_revision" => 1
      }

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               submit_batch(conn, [move])
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      move = %{
        "operation_id" => "op-2",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "new_arrival_on" => "2026-10-01",
        "expected_revision" => 7
      }

      assert %{"results" => [_, %{"code" => "stale_revision"}]} =
               submit_batch(conn, [open(), move])
    end

    test "rejects a non-integer expected_revision for an existing group", %{conn: conn} do
      pay = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 100,
        "expected_revision" => "1"
      }

      assert %{"results" => [_, %{"code" => "invalid_operation"}]} =
               submit_batch(conn, [open(), pay])
    end

    test "rejections never increment the revision", %{conn: conn} do
      too_much = %{
        "operation_id" => "op-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "g-1",
        "amount_cents" => 99_999
      }

      assert %{"results" => [_, %{"code" => "payment_exceeds_outstanding"}]} =
               submit_batch(conn, [open(), too_much])

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = read_group(conn, "g-1")
    end
  end
end
