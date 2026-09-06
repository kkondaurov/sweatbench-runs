defmodule GroupStayWeb.IdempotencyTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  alias GroupStay.Operations

  describe "retrying an operation" do
    setup %{conn: conn} do
      submit_one(conn, open_group_op())
      :ok
    end

    test "returns the original applied result and applies nothing twice", %{conn: conn} do
      first = submit_one(conn, payment_op())

      assert %{"status" => "applied", "amount_cents" => 10_000, "revision" => 2} = first
      assert first == submit_one(conn, payment_op())
      assert first == submit_one(conn, payment_op())

      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = read_group(conn, "group-81")
      assert %{"cash_held_cents" => 10_000} = read_ledger(conn)
    end

    test "a retry inside the same batch replays rather than reapplies", %{conn: conn} do
      assert %{"results" => [first, retry]} = submit(conn, [payment_op(), payment_op()])

      assert first == retry
      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = read_group(conn, "group-81")
    end

    test "object key order is irrelevant", %{conn: conn} do
      keys = [
        ~s("operation_id":"op-pay"),
        ~s("type":"record_cash_payment"),
        ~s("occurred_on":"2026-10-04"),
        ~s("group_id":"group-81"),
        ~s("amount_cents":10000)
      ]

      [first, reordered] =
        for order <- [keys, Enum.reverse(keys)] do
          body = ~s({"operations":[{#{Enum.join(order, ",")}}]})

          %{"results" => [result]} = conn |> post_raw_batch(body) |> json_response(200)
          result
        end

      assert %{"status" => "applied", "revision" => 2} = first
      assert first == reordered
      assert %{"revision" => 2, "deposit_paid_cents" => 10_000} = read_group(conn, "group-81")
    end

    test "array order is part of the payload", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]

      assert %{"status" => "applied"} =
               submit_one(conn, open_group_op(%{operation_id: "op-rooms", group_id: "group-82"}))

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(
                 conn,
                 open_group_op(%{
                   operation_id: "op-rooms",
                   group_id: "group-82",
                   rooms: Enum.reverse(rooms)
                 })
               )
    end

    test "a remembered rejection is replayed even once it would succeed", %{conn: conn} do
      missing = payment_op(%{operation_id: "op-late", group_id: "group-82"})

      assert %{"status" => "rejected", "code" => "group_not_found"} = submit_one(conn, missing)

      submit_one(conn, open_group_op(%{operation_id: "op-open-2", group_id: "group-82"}))

      assert %{"status" => "rejected", "code" => "group_not_found"} = submit_one(conn, missing)
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = read_group(conn, "group-82")
    end

    test "a handled rejection commits its record while leaving the domain unchanged",
         %{conn: conn} do
      rejected = submit_one(conn, payment_op(%{amount_cents: 500_000}))

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = rejected
      assert rejected == read_operation(conn, "op-pay")
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = read_group(conn, "group-81")
      assert %{"cash_held_cents" => 0} = read_ledger(conn)
    end

    test "later operations in the batch still run after a handled rejection", %{conn: conn} do
      assert %{"results" => [rejected, applied]} =
               submit(conn, [
                 payment_op(%{operation_id: "op-too-much", amount_cents: 500_000}),
                 payment_op(%{amount_cents: 5000})
               ])

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = rejected
      assert %{"status" => "applied", "revision" => 2} = applied
      assert {:ok, _record} = Operations.fetch("op-too-much")
    end
  end

  describe "results that carry more than integers" do
    test "replays a null field exactly", %{conn: conn} do
      submit_one(conn, open_group_op(%{rate_plan: "advance_purchase"}))

      moved = submit_one(conn, reschedule_op())

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil,
               "new_departure_on" => "2026-12-20"
             } = moved

      assert moved == submit_one(conn, reschedule_op())
      assert moved == read_operation(conn, "op-move")
      assert %{"revision" => 2, "arrival_on" => "2026-12-17"} = read_group(conn, "group-81")
    end

    test "replays a settlement without settling it again", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      settled =
        submit_one(
          conn,
          cancel_op(%{occurred_on: "2026-11-26", refund_method: "hotel_credit"})
        )

      assert %{"credit_issued_cents" => 11_000, "refunded_cents" => 0, "revision" => 3} = settled

      assert settled ==
               submit_one(
                 conn,
                 cancel_op(%{occurred_on: "2026-11-26", refund_method: "hotel_credit"})
               )

      assert %{"available_cents" => 11_000, "lots" => [_lot]} =
               read_credit(conn, "guest-22", on: "2026-11-26")

      assert %{"cash_converted_to_credit_cents" => 10_000} = read_ledger(conn, on: "2026-11-26")
    end
  end

  describe "reusing an identifier for a different payload" do
    setup %{conn: conn} do
      submit_one(conn, open_group_op())
      :ok
    end

    test "is rejected and does not replace the original record", %{conn: conn} do
      original = submit_one(conn, payment_op(%{amount_cents: 5000}))

      assert %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             } = submit_one(conn, payment_op(%{amount_cents: 6000}))

      assert original == read_operation(conn, "op-pay")
      assert original == submit_one(conn, payment_op(%{amount_cents: 5000}))
      assert %{"revision" => 2, "deposit_paid_cents" => 5000} = read_group(conn, "group-81")
    end

    test "a value of a different JSON type is a different payload", %{conn: conn} do
      submit_one(conn, payment_op(%{amount_cents: 5000}))

      body =
        ~s({"operations":[{"operation_id":"op-pay","type":"record_cash_payment",) <>
          ~s("occurred_on":"2026-10-04","group_id":"group-81","amount_cents":5000.0}]})

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               conn |> post_raw_batch(body) |> json_response(200)
    end

    test "an added key is a different payload", %{conn: conn} do
      submit_one(conn, payment_op())

      assert %{"code" => "operation_id_conflict"} =
               submit_one(conn, payment_op(%{expected_revision: 2}))
    end
  end

  describe "revisions in remembered results" do
    setup %{conn: conn} do
      submit(conn, [open_group_op(), payment_op(%{operation_id: "op-1", amount_cents: 1000})])
      :ok
    end

    test "an exact retry reports the revision observed on the original attempt",
         %{conn: conn} do
      applied = submit_one(conn, payment_op(%{operation_id: "op-2", amount_cents: 1000}))

      assert %{"revision" => 3} = applied

      submit_one(conn, payment_op(%{operation_id: "op-3", amount_cents: 1000}))

      assert applied == submit_one(conn, payment_op(%{operation_id: "op-2", amount_cents: 1000}))
      assert %{"revision" => 4} = read_group(conn, "group-81")
    end

    test "an exact retry of a stale operation reports the original actual revision",
         %{conn: conn} do
      stale = payment_op(%{operation_id: "op-stale", expected_revision: 1, amount_cents: 1000})

      assert %{"code" => "stale_revision", "actual_revision" => 2} = submit_one(conn, stale)

      submit_one(conn, payment_op(%{operation_id: "op-3", amount_cents: 1000}))

      assert %{"revision" => 3} = read_group(conn, "group-81")
      assert %{"code" => "stale_revision", "actual_revision" => 2} = submit_one(conn, stale)
    end

    test "retrying with a corrected expected revision is a conflict", %{conn: conn} do
      submit_one(
        conn,
        payment_op(%{operation_id: "op-stale", expected_revision: 1, amount_cents: 1000})
      )

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(
                 conn,
                 payment_op(%{operation_id: "op-stale", expected_revision: 2, amount_cents: 1000})
               )

      assert %{"revision" => 2, "deposit_paid_cents" => 1000} = read_group(conn, "group-81")
    end
  end

  describe "operations that cannot be remembered" do
    test "an operation without a usable identifier is rejected and never recorded",
         %{conn: conn} do
      for operation <- [
            Map.delete(payment_op(), "operation_id"),
            payment_op(%{operation_id: ""}),
            payment_op(%{operation_id: 17}),
            "not-an-operation"
          ] do
        assert %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"} =
                 submit_one(conn, operation),
               "expected an unremembered invalid_operation for #{inspect(operation)}"
      end

      assert [] == Operations.in_commit_order()
    end

    test "an unexpected fault rolls the operation back and aborts the batch", %{conn: conn} do
      submit_one(conn, open_group_op())

      # An amount SQLite cannot store is not a domain rejection: it is a fault.
      faulting =
        open_group_op(%{
          operation_id: "op-boom",
          group_id: "group-boom",
          rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 9_223_372_036_854_775_807}]
        })

      error =
        assert_raise Exqlite.Error, fn ->
          submit(conn, [faulting, payment_op()])
        end

      assert Plug.Exception.status(error) == 500

      assert :error = Operations.fetch("op-boom")
      assert json_response(get(conn, "/api/v1/groups/group-boom"), 404)

      # The batch stopped at the fault, so the operation behind it never ran.
      assert :error = Operations.fetch("op-pay")
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = read_group(conn, "group-81")
    end
  end
end
