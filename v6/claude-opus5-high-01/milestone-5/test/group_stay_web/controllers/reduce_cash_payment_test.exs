defmodule GroupStayWeb.ReduceCashPaymentTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # `op-pay` records 10_000 against the default group: 9000 fills room-a and the
  # remaining 1000 lands on room-b.
  setup %{conn: conn} do
    submit(conn, [open_group_op(), payment_op()])
    :ok
  end

  describe "reduce_cash_payment" do
    test "takes the cash back off the room the payment filled last", %{conn: conn} do
      assert %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 1000,
               "outstanding_deposit_cents" => 10_500,
               "revision" => 3
             } = submit_one(conn, reduce_op())

      assert %{
               "cash_paid_cents" => 9000,
               "deposit_paid_cents" => 9000,
               "outstanding_deposit_cents" => 10_500,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = read_group(conn, "group-81")

      assert %{"cash_held_cents" => 9000, "cash_reduced_cents" => 1000} = read_ledger(conn)
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      submit_one(conn, reduce_op(%{amount_cents: 600}))

      assert %{"status" => "applied", "outstanding_deposit_cents" => 13_100} =
               submit_one(conn, reduce_op(%{operation_id: "op-reduce-2", amount_cents: 3000}))

      assert %{
               "cash_paid_cents" => 6400,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 6400},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = read_group(conn, "group-81")

      assert %{"cash_held_cents" => 6400, "cash_reduced_cents" => 3600} = read_ledger(conn)
    end

    test "the whole remaining held portion can be reduced", %{conn: conn} do
      assert %{"status" => "applied", "outstanding_deposit_cents" => 19_500} =
               submit_one(conn, reduce_op(%{amount_cents: 10_000}))

      assert %{"cash_paid_cents" => 0, "outstanding_deposit_cents" => 19_500} =
               read_group(conn, "group-81")

      assert %{"cash_held_cents" => 0, "cash_reduced_cents" => 10_000} = read_ledger(conn)
    end

    test "reopened deposit can be funded again", %{conn: conn} do
      submit(conn, [
        reduce_op(%{amount_cents: 10_000}),
        payment_op(%{operation_id: "op-pay-2", amount_cents: 9500})
      ])

      assert %{
               "cash_paid_cents" => 9500,
               "outstanding_deposit_cents" => 10_000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 500}
               ]
             } = read_group(conn, "group-81")
    end

    test "does not rewrite the payment it corrects", %{conn: conn} do
      submit_one(conn, reduce_op())

      assert %{
               "status" => "applied",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9500,
               "revision" => 2
             } = read_operation(conn, "op-pay")

      # Retrying the payment replays that result without applying cash again.
      assert %{"status" => "applied", "amount_cents" => 10_000, "revision" => 2} =
               submit_one(conn, payment_op())

      assert %{"cash_paid_cents" => 9000, "revision" => 3} = read_group(conn, "group-81")
    end

    test "is remembered like any other operation", %{conn: conn} do
      first = submit_one(conn, reduce_op())

      assert submit_one(conn, reduce_op()) == first
      assert read_operation(conn, "op-reduce") == first
      assert %{"cash_paid_cents" => 9000, "revision" => 3} = read_group(conn, "group-81")
    end
  end

  describe "reduce_cash_payment rejections" do
    test "rejects an identifier nothing was recorded under", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "operation_not_found",
               "payment_operation_id" => "op-none"
             } = submit_one(conn, reduce_op(%{payment_operation_id: "op-none"}))
    end

    test "rejects an operation that is not a cash payment", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "payment_not_reducible"} =
               submit_one(conn, reduce_op(%{payment_operation_id: "op-open"}))
    end

    test "rejects a payment that was itself rejected", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} =
               submit_one(
                 conn,
                 payment_op(%{operation_id: "op-too-big", amount_cents: 100_000})
               )

      assert %{"code" => "payment_not_reducible"} =
               submit_one(conn, reduce_op(%{payment_operation_id: "op-too-big"}))
    end

    test "rejects a payment whose cash has all been settled", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: "2026-11-26"}))

      assert %{"code" => "payment_not_reducible", "group_id" => "group-81"} =
               submit_one(conn, reduce_op())

      assert %{"cash_refunded_cents" => 10_000, "cash_reduced_cents" => 0} = read_ledger(conn)
    end

    test "rejects a payment with nothing left to reduce", %{conn: conn} do
      submit_one(conn, reduce_op(%{amount_cents: 10_000}))

      assert %{"code" => "payment_not_reducible"} =
               submit_one(conn, reduce_op(%{operation_id: "op-reduce-2", amount_cents: 1}))
    end

    test "rejects a non-positive amount", %{conn: conn} do
      for {amount, index} <- Enum.with_index([0, -1, "500", 500.0]) do
        assert %{"status" => "rejected", "code" => "invalid_amount"} =
                 submit_one(
                   conn,
                   reduce_op(%{operation_id: "op-reduce-#{index}", amount_cents: amount})
                 ),
               "expected invalid_amount for #{inspect(amount)}"
      end

      assert %{"revision" => 2} = read_group(conn, "group-81")
    end

    test "rejects more than the payment currently holds", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "reduction_exceeds_held_cash",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81"
             } = submit_one(conn, reduce_op(%{amount_cents: 10_001}))

      assert %{"cash_paid_cents" => 10_000, "revision" => 2} = read_group(conn, "group-81")
    end

    test "rejects an operation that cannot name its target", %{conn: conn} do
      assert %{"code" => "invalid_operation"} =
               submit_one(conn, Map.delete(reduce_op(), "payment_operation_id"))
    end

    test "rejects a stale revision of the payment's group", %{conn: conn} do
      assert %{
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             } = submit_one(conn, reduce_op(%{expected_revision: 1}))

      assert %{"cash_paid_cents" => 10_000, "revision" => 2} = read_group(conn, "group-81")
    end

    test "applies on a matching revision of the payment's group", %{conn: conn} do
      assert %{"status" => "applied", "revision" => 3} =
               submit_one(conn, reduce_op(%{expected_revision: 2}))
    end
  end
end
