defmodule GroupStayWeb.PartnerBatchIdempotencyTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Operations
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @batch_path "/api/v1/partner-batches"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
  end

  defp submit_raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, body)
  end

  defp run(conn, operations) do
    submit(conn, operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
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
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp reschedule_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-15"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp fetched_group(conn, group_id \\ "group-81") do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  describe "idempotent replay" do
    test "the first submission is processed normally", %{conn: conn} do
      assert [result] = run(conn, [open_op()])
      assert result["status"] == "applied"
      assert result["revision"] == 1
      assert fetched_group(conn)["revision"] == 1
    end

    test "an equivalent retry returns the exact stored result without re-applying", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [first] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])
      assert first["status"] == "applied"
      assert first["revision"] == 2

      for _ <- 1..3 do
        assert [retry] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])
        assert retry == first
      end

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 5_000
      assert group["revision"] == 2
    end

    test "replaying an open does not recreate the group", %{conn: conn} do
      assert [first] = run(conn, [open_op()])

      assert [retry] = run(conn, [open_op()])
      assert retry == first

      assert fetched_group(conn)["revision"] == 1
    end

    test "a replay returns date and revision details verbatim", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [first] = run(conn, [reschedule_op(%{"operation_id" => "op-move-1"})])
      assert first["status"] == "applied"
      assert first["new_arrival_on"] == "2026-12-15"
      assert first["new_departure_on"] == "2026-12-18"
      assert first["refundable_until"] == "2026-12-01"
      assert first["revision"] == 2

      # Move the group again so current state diverges from the stored result.
      assert [_] =
               run(conn, [
                 reschedule_op(%{
                   "operation_id" => "op-move-2",
                   "occurred_on" => "2026-10-05",
                   "new_arrival_on" => "2026-12-20"
                 })
               ])

      assert [retry] = run(conn, [reschedule_op(%{"operation_id" => "op-move-1"})])
      assert retry == first

      assert fetched_group(conn)["arrival_on"] == "2026-12-20"
      assert fetched_group(conn)["revision"] == 3
    end

    test "a replay ignores domain changes made since the original", %{conn: conn} do
      assert [_, paid] = run(conn, [open_op(), payment_op(%{"operation_id" => "op-pay-1"})])
      assert paid["revision"] == 2
      assert paid["outstanding_deposit_cents"] == 14_500

      assert [_] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1_000})])

      assert [_] = run(conn, [cancel_op()])

      assert [retry] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])
      assert retry == paid

      group = fetched_group(conn)
      assert group["status"] == "cancelled"
      assert group["revision"] == 4
      assert group["deposit_paid_cents"] == 6_000
    end

    test "a retry of a rejected operation returns the original rejection even when it would now be valid",
         %{conn: conn} do
      assert [rejected] = run(conn, [payment_op(%{"operation_id" => "op-early"})])
      assert rejected["status"] == "rejected"
      assert rejected["code"] == "group_not_found"

      assert [_] = run(conn, [open_op()])

      assert [retry] = run(conn, [payment_op(%{"operation_id" => "op-early"})])
      assert retry == rejected

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "a replayed stale rejection keeps the originally observed revision", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      stale = payment_op(%{"operation_id" => "op-stale", "expected_revision" => 1})
      assert [rejected] = run(conn, [stale])
      assert rejected["code"] == "stale_revision"
      assert rejected["expected_revision"] == 1
      assert rejected["actual_revision"] == 2

      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-2"})])

      assert [retry] = run(conn, [stale])
      assert retry == rejected

      assert fetched_group(conn)["revision"] == 3
    end

    test "correcting the expected_revision of a stored stale operation is a conflict", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      assert [rejected] =
               run(conn, [payment_op(%{"operation_id" => "op-stale", "expected_revision" => 1})])

      assert rejected["code"] == "stale_revision"

      assert [conflict] =
               run(conn, [payment_op(%{"operation_id" => "op-stale", "expected_revision" => 2})])

      assert conflict == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert fetched_group(conn)["revision"] == 2
    end

    test "duplicate submissions in one batch apply only once", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [first, replayed] = run(conn, [payment_op(), payment_op()])
      assert first["status"] == "applied"
      assert replayed == first

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 5_000
      assert group["revision"] == 2
    end

    test "a replayed rejection does not stop later operations", %{conn: conn} do
      assert [rejected] = run(conn, [payment_op(%{"operation_id" => "op-early"})])
      assert rejected["code"] == "group_not_found"

      assert [retry, opened] = run(conn, [payment_op(%{"operation_id" => "op-early"}), open_op()])
      assert retry == rejected
      assert opened["status"] == "applied"
    end

    test "object key order is insignificant for replay", %{conn: conn} do
      first_body = ~s({"operations":[{
        "operation_id":"op-keys","type":"open_group","occurred_on":"2026-10-03",
        "group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal",
        "arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible",
        "rooms":[{"room_id":"room-a","nightly_rate_cents":15000}]
      }]})

      reordered_body = ~s({"operations":[{
        "rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"}],
        "rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10",
        "property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81",
        "occurred_on":"2026-10-03","type":"open_group","operation_id":"op-keys"
      }]})

      assert [first] = submit_raw(conn, first_body) |> json_response(200) |> Map.fetch!("results")
      assert first["status"] == "applied"

      assert [retry] =
               submit_raw(conn, reordered_body) |> json_response(200) |> Map.fetch!("results")

      assert retry == first
      assert fetched_group(conn)["revision"] == 1
    end
  end

  describe "operation_id_conflict" do
    test "reusing an identifier with a different payload is rejected without replacing the original",
         %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [applied] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      assert [conflict] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-1", "amount_cents" => 9_999})
               ])

      assert conflict == %{
               "operation_id" => "op-pay-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert [retry] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])
      assert retry == applied

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 5_000
      assert group["revision"] == 2
    end

    test "a conflicting payload is not stored", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [applied] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      conflicting = payment_op(%{"operation_id" => "op-pay-1", "amount_cents" => 9_999})

      assert [conflict] = run(conn, [conflicting])
      assert conflict["code"] == "operation_id_conflict"

      assert [again] = run(conn, [conflicting])
      assert again["code"] == "operation_id_conflict"

      assert Operations.stored_result("op-pay-1") == applied
    end

    test "array order is significant", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      reversed_rooms = [
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
      ]

      assert [conflict] = run(conn, [open_op(%{"rooms" => reversed_rooms})])
      assert conflict["code"] == "operation_id_conflict"
    end

    test "a different value is significant", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [conflict] =
               run(conn, [open_op(%{"operation_id" => "op-open", "occurred_on" => "2026-10-04"})])

      assert conflict["code"] == "operation_id_conflict"
    end

    test "conflicting operations elsewhere in the batch do not stop processing", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      assert [conflict, applied] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-1", "amount_cents" => 100}),
                 payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1_000})
               ])

      assert conflict["code"] == "operation_id_conflict"
      assert applied["status"] == "applied"
      assert applied["revision"] == 3
    end
  end

  describe "untracked operations" do
    test "operations without a usable identifier are rejected and not remembered", %{conn: conn} do
      for overrides <- [%{"operation_id" => nil}, %{"operation_id" => ""}] do
        assert [result] = run(conn, [open_op(overrides)])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert [again] = run(conn, [open_op(%{"operation_id" => nil, "group_id" => "group-x"})])
      assert again["code"] == "invalid_operation"

      conn = get(conn, "/api/v1/operations/op-open")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "entries that are not operation objects are rejected and not remembered", %{conn: conn} do
      assert [result] = run(conn, ["open_group"])
      assert result["code"] == "invalid_operation"

      assert [again] = run(conn, [%{"completely" => "different"}])
      assert again["code"] == "invalid_operation"
    end
  end

  describe "durable records" do
    test "remember applied and rejected operations with their type and submission in commit order",
         %{conn: conn} do
      assert [_open, _paid, rejected, _replay] =
               run(conn, [
                 open_op(%{"operation_id" => "op-a"}),
                 payment_op(%{"operation_id" => "op-b"}),
                 payment_op(%{"operation_id" => "op-c", "amount_cents" => 0}),
                 payment_op(%{"operation_id" => "op-b"})
               ])

      assert rejected["code"] == "invalid_amount"

      records = Repo.all(from r in Record, order_by: [asc: r.id])

      assert Enum.map(records, & &1.operation_id) == ["op-a", "op-b", "op-c"]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "record_cash_payment"
             ]

      [open_record, paid_record, rejected_record] = records

      assert Jason.decode!(open_record.payload) == open_op(%{"operation_id" => "op-a"})
      assert Jason.decode!(paid_record.payload) == payment_op(%{"operation_id" => "op-b"})

      assert Jason.decode!(rejected_record.payload) ==
               payment_op(%{"operation_id" => "op-c", "amount_cents" => 0})

      assert Jason.decode!(open_record.result)["status"] == "applied"
      assert Jason.decode!(paid_record.result)["status"] == "applied"
      assert Jason.decode!(rejected_record.result)["code"] == "invalid_amount"
    end

    test "a rejected operation commits its record without changing domain state", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [rejected] =
               run(conn, [payment_op(%{"operation_id" => "op-too-big", "amount_cents" => 99_999})])

      assert rejected["code"] == "payment_exceeds_outstanding"

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1

      assert Operations.stored_result("op-too-big") == rejected
    end

    test "one record per operation_id is enforced at the database level" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Record{
        operation_id: "op-unique",
        type: "open_group",
        payload: "{}",
        result: "{}",
        inserted_at: now,
        updated_at: now
      })

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Record{
          operation_id: "op-unique",
          type: "open_group",
          payload: "[]",
          result: "[]",
          inserted_at: now,
          updated_at: now
        })
      end
    end
  end

  describe "unexpected faults" do
    test "roll back the current operation, are not remembered, and abort the batch", %{
      conn: conn
    } do
      # Break the rooms table so opening a group faults mid-transaction.
      Repo.query!("ALTER TABLE rooms RENAME TO rooms_fault")

      batch = [
        payment_op(%{"operation_id" => "op-fault-pay"}),
        open_op(%{"operation_id" => "op-fault-open"})
      ]

      error =
        try do
          submit(conn, batch)
          nil
        rescue
          e -> e
        end

      assert error != nil

      # The handled rejection committed before the fault; the faulted
      # operation left neither domain state nor an idempotency record.
      stored_rejection = Operations.stored_result("op-fault-pay")
      assert stored_rejection["code"] == "group_not_found"
      assert Operations.stored_result("op-fault-open") == nil

      missing = get(conn, "/api/v1/groups/group-81")
      assert json_response(missing, 404) == %{"error" => %{"code" => "group_not_found"}}

      # Once the fault clears, the gateway retries the batch: the remembered
      # rejection replays and the open applies for the first time.
      Repo.query!("ALTER TABLE rooms_fault RENAME TO rooms")

      assert [replayed, opened] = run(conn, batch)
      assert replayed == stored_rejection
      assert opened["status"] == "applied"
      assert fetched_group(conn)["revision"] == 1
    end
  end
end
