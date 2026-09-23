defmodule GroupStayWeb.OperationIdempotencyTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Repo

  defp post_raw(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp submit_raw(body), do: body |> post_raw() |> json_response(200) |> Map.fetch!("results")

  defp conflict(operation_id),
    do: %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => "operation_id_conflict"
    }

  # The stored submission and type for each record, in commit order.
  defp audit_trail do
    for [_id, operation_id, type, payload | _] <- operation_records(),
        do: {operation_id, type, Jason.decode!(payload)}
  end

  describe "retrying an applied operation" do
    setup do
      submit_one(open_group_op(%{"operation_id" => "op-open"}))
      :ok
    end

    test "returns the original result without applying it again" do
      pay = payment_op(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      original = submit_one(pay)

      assert original == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      before = db_snapshot()
      records = operation_records()

      assert submit_one(pay) == original
      assert submit([pay, pay]) == [original, original]

      assert db_snapshot() == before
      assert operation_records() == records
      assert get_ledger()["cash_held_cents"] == 5000
      assert get_group("group-81")["revision"] == 2
    end

    test "ignores object key order but not array order" do
      open = ~s({"operation_id": "op-open-2", "type": "open_group", "occurred_on": "2026-10-03",
        "group_id": "group-82", "guest_id": "guest-22", "property_id": "ams-canal",
        "arrival_on": "2026-12-10", "departure_on": "2026-12-13", "rate_plan": "flexible",
        "rooms": [{"room_id": "room-a", "nightly_rate_cents": 15000},
                  {"room_id": "room-b", "nightly_rate_cents": 17500}]})

      reordered = ~s({"rooms": [{"nightly_rate_cents": 15000, "room_id": "room-a"},
                  {"nightly_rate_cents": 17500, "room_id": "room-b"}],
        "rate_plan": "flexible", "departure_on": "2026-12-13", "arrival_on": "2026-12-10",
        "property_id": "ams-canal", "guest_id": "guest-22", "group_id": "group-82",
        "occurred_on": "2026-10-03", "type": "open_group", "operation_id": "op-open-2"})

      rooms_reversed = ~s({"operation_id": "op-open-2", "type": "open_group",
        "occurred_on": "2026-10-03", "group_id": "group-82", "guest_id": "guest-22",
        "property_id": "ams-canal", "arrival_on": "2026-12-10", "departure_on": "2026-12-13",
        "rate_plan": "flexible",
        "rooms": [{"room_id": "room-b", "nightly_rate_cents": 17500},
                  {"room_id": "room-a", "nightly_rate_cents": 15000}]})

      [original] = submit_raw(~s({"operations": [#{open}]}))
      assert %{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19_500} = original

      assert submit_raw(~s({"operations": [#{reordered}]})) == [original]
      assert submit_raw(~s({"operations": [#{rooms_reversed}]})) == [conflict("op-open-2")]

      assert Enum.map(get_group("group-82")["rooms"], & &1["room_id"]) == ["room-a", "room-b"]
    end

    test "returns the result observed originally, not current group state" do
      submit_one(payment_op(%{"operation_id" => "op-pay-1", "amount_cents" => 1000}))
      move = reschedule_op(%{"operation_id" => "op-move", "new_arrival_on" => "2026-12-20"})
      original = submit_one(move)

      assert %{"revision" => 3, "new_arrival_on" => "2026-12-20", "refundable_until" => _} =
               original

      submit_one(payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000}))
      submit_one(cancel_op(%{"operation_id" => "op-cancel"}))

      assert submit_one(move) == original
      assert %{"status" => "cancelled", "revision" => 5} = get_group("group-81")
    end

    test "is exact for revision preconditions" do
      pay = payment_op(%{"operation_id" => "op-pay", "expected_revision" => 1})
      original = submit_one(pay)
      assert %{"status" => "applied", "revision" => 2} = original

      submit_one(payment_op(%{"operation_id" => "op-pay-2", "expected_revision" => 2}))

      # The precondition no longer holds, but the retry is not evaluated again.
      assert submit_one(pay) == original
      assert get_group("group-81")["revision"] == 3
    end

    test "rejects a reused identifier with a different payload and keeps the original" do
      pay = payment_op(%{"operation_id" => "op-pay", "amount_cents" => 5000})
      original = submit_one(pay)
      records = operation_records()

      for changed <- [
            Map.put(pay, "amount_cents", 6000),
            Map.put(pay, "note", "retry"),
            Map.delete(pay, "occurred_on"),
            Map.put(pay, "type", "apply_hotel_credit"),
            cancel_op(%{"operation_id" => "op-pay"})
          ] do
        assert submit_one(changed) == conflict("op-pay")
      end

      assert operation_records() == records
      assert get_operation("op-pay") == original
      assert submit_one(pay) == original
      assert get_group("group-81")["deposit_paid_cents"] == 5000
    end

    test "treats a repeated identifier within one batch as a retry" do
      pay = payment_op(%{"operation_id" => "op-pay", "amount_cents" => 1000})
      other = payment_op(%{"operation_id" => "op-pay", "amount_cents" => 2000})

      [first, retry, conflicting, next] =
        submit([pay, pay, other, payment_op(%{"operation_id" => "op-next"})])

      assert first["revision"] == 2
      assert retry == first
      assert conflicting == conflict("op-pay")
      assert %{"status" => "applied", "revision" => 3} = next
      assert get_group("group-81")["deposit_paid_cents"] == 1000 + 5000
    end
  end

  describe "remembered rejections" do
    test "a retry receives the original rejection even when it would now apply" do
      pay = payment_op(%{"operation_id" => "op-early-pay", "amount_cents" => 1000})

      assert submit_one(pay) == %{
               "operation_id" => "op-early-pay",
               "status" => "rejected",
               "code" => "group_not_found"
             }

      submit_one(open_group_op(%{"operation_id" => "op-open"}))
      before = db_snapshot()

      assert submit_one(pay)["code"] == "group_not_found"
      assert db_snapshot() == before
      assert get_group("group-81")["deposit_paid_cents"] == 0
    end

    test "stale revision details are returned verbatim" do
      submit_one(open_group_op(%{"operation_id" => "op-open"}))
      submit_one(payment_op(%{"operation_id" => "op-pay", "amount_cents" => 1000}))

      stale = cancel_op(%{"operation_id" => "op-stale", "expected_revision" => 1})

      expected = %{
        "operation_id" => "op-stale",
        "status" => "rejected",
        "code" => "stale_revision",
        "group_id" => "group-81",
        "expected_revision" => 1,
        "actual_revision" => 2
      }

      assert submit_one(stale) == expected

      submit_one(payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1000}))
      assert submit_one(stale) == expected

      # Correcting the precondition changes the payload, so the identifier cannot be reused.
      assert submit_one(Map.put(stale, "expected_revision", 3)) == conflict("op-stale")
      assert %{"status" => "active", "revision" => 3} = get_group("group-81")

      assert %{"status" => "applied", "revision" => 4} =
               submit_one(
                 Map.merge(stale, %{"operation_id" => "op-fixed", "expected_revision" => 3})
               )
    end

    test "invalid operations with an identifier are remembered" do
      unknown = %{
        "operation_id" => "op-x",
        "type" => "teleport_group",
        "occurred_on" => "2026-10-03"
      }

      rejected = %{
        "operation_id" => "op-x",
        "status" => "rejected",
        "code" => "invalid_operation"
      }

      assert submit_one(unknown) == rejected
      assert submit_one(unknown) == rejected
      assert submit_one(Map.put(unknown, "type", "cancel_group")) == conflict("op-x")
      assert get_operation("op-x") == rejected
    end

    test "operations without a usable identifier are rejected and not remembered" do
      results =
        submit([
          Map.delete(open_group_op(), "operation_id"),
          open_group_op(%{"operation_id" => ""}),
          open_group_op(%{"operation_id" => 42}),
          "open_group"
        ])

      assert Enum.map(results, &{&1["operation_id"], &1["code"]}) == [
               {nil, "invalid_operation"},
               {"", "invalid_operation"},
               {42, "invalid_operation"},
               {nil, "invalid_operation"}
             ]

      assert operation_records() == []
      assert db_snapshot()["groups"] == []
    end

    test "a rejection commits its record without domain changes and the batch continues" do
      [opened, rejected, paid] =
        submit([
          open_group_op(%{"operation_id" => "op-open"}),
          payment_op(%{"operation_id" => "op-too-much", "amount_cents" => 1_000_000}),
          payment_op(%{"operation_id" => "op-pay", "amount_cents" => 1000})
        ])

      assert opened["status"] == "applied"
      assert rejected["code"] == "payment_exceeds_outstanding"
      assert %{"status" => "applied", "revision" => 2} = paid
      assert get_ledger()["cash_held_cents"] == 1000
      assert Enum.map(audit_trail(), &elem(&1, 0)) == ["op-open", "op-too-much", "op-pay"]
    end
  end

  describe "audit records" do
    test "retain the type and complete submission of every remembered operation in commit order" do
      open = open_group_op(%{"operation_id" => "op-open", "channel" => %{"source" => "pms"}})
      pay = payment_op(%{"operation_id" => "op-pay", "amount_cents" => 0})
      unknown = %{"operation_id" => "op-x", "type" => 7, "occurred_on" => "2026-10-03"}

      submit([open, pay])
      submit([unknown, open, cancel_op(%{"operation_id" => "op-open"})])
      submit_one(cancel_op(%{"operation_id" => "op-cancel", "refund_method" => nil}))

      assert audit_trail() == [
               {"op-open", "open_group", open},
               {"op-pay", "record_cash_payment", pay},
               {"op-x", nil, unknown},
               {"op-cancel", "cancel_group",
                cancel_op(%{"operation_id" => "op-cancel", "refund_method" => nil})}
             ]

      [[_id, _operation_id, _type, payload | _] | _] = operation_records()
      # Stored canonically, so equivalent submissions compare equal.
      assert payload == GroupStay.OperationRecords.canonical_json(open)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored applied or rejected result", %{conn: conn} do
      [opened, rejected] =
        submit([
          open_group_op(%{"operation_id" => "op open/1"}),
          payment_op(%{"operation_id" => "op-pay", "amount_cents" => -5})
        ])

      submit_one(payment_op(%{"operation_id" => "op-pay-2"}))

      assert get_operation("op open/1") == opened
      assert get_operation("op-pay") == rejected

      assert json_response(get(conn, "/api/v1/operations/op-pay"), 200) == %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               }
             }
    end

    test "returns 404 for an unknown or unremembered operation", %{conn: conn} do
      submit_one(payment_op(%{"operation_id" => "op-pay"}))
      submit_one(payment_op(%{"operation_id" => "op-pay", "amount_cents" => 1}))

      for id <- ["op-missing", "OP-PAY"] do
        assert json_response(get(conn, "/api/v1/operations/#{id}"), 404) == %{
                 "error" => %{"code" => "operation_not_found"}
               }
      end
    end
  end

  describe "unexpected failures" do
    setup do
      submit_one(open_group_op(%{"operation_id" => "op-open"}))
      :ok
    end

    defp break_ledger!,
      do:
        Repo.query!("""
        CREATE TRIGGER fail_ledger BEFORE INSERT ON ledger_entries
        BEGIN SELECT RAISE(ABORT, 'ledger unavailable'); END
        """)

    test "abort the request without remembering the failed operation" do
      batch = [
        payment_op(%{"operation_id" => "op-before", "amount_cents" => 0}),
        reschedule_op(%{"operation_id" => "op-move"}),
        payment_op(%{"operation_id" => "op-pay", "amount_cents" => 1000}),
        payment_op(%{"operation_id" => "op-after", "amount_cents" => 2000})
      ]

      break_ledger!()

      assert_error_sent 500, fn ->
        post_json(build_conn(), "/api/v1/partner-batches", %{"operations" => batch})
      end

      # Operations before the failure committed; the failing one and those after it did not.
      assert Enum.map(audit_trail(), &elem(&1, 0)) == ["op-open", "op-before", "op-move"]
      assert %{"revision" => 2, "deposit_paid_cents" => 0} = get_group("group-81")
      assert get_ledger()["cash_held_cents"] == 0

      Repo.query!("DROP TRIGGER fail_ledger")

      [before, moved, paid, after_] = submit(batch)
      assert before["code"] == "invalid_amount"
      assert moved["revision"] == 2
      assert %{"status" => "applied", "revision" => 3} = paid
      assert %{"status" => "applied", "revision" => 4} = after_
      assert get_ledger()["cash_held_cents"] == 3000
    end
  end
end
