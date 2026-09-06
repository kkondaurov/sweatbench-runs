defmodule GroupStayWeb.RecordCashPaymentTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  setup %{conn: conn} do
    submit_one(conn, open_group_op())
    :ok
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      assert %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9500,
               "revision" => 2
             } = submit_one(conn, payment_op())

      assert %{"deposit_paid_cents" => 10_000, "outstanding_deposit_cents" => 9500} =
               read_group(conn, "group-81")

      assert %{"cash_held_cents" => 10_000} = read_ledger(conn)
    end

    test "accepts payments up to the outstanding deposit", %{conn: conn} do
      submit_one(conn, payment_op(%{amount_cents: 9500}))

      assert %{
               "status" => "applied",
               "outstanding_deposit_cents" => 0,
               "revision" => 3
             } = submit_one(conn, payment_op(%{operation_id: "op-2", amount_cents: 10_000}))

      assert %{"deposit_paid_cents" => 19_500} = read_group(conn, "group-81")
    end

    test "rejects a payment beyond the outstanding deposit and records nothing", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding",
               "group_id" => "group-81"
             } = submit_one(conn, payment_op(%{amount_cents: 19_501}))

      assert %{"deposit_paid_cents" => 0, "revision" => 1} = read_group(conn, "group-81")
      assert %{"cash_held_cents" => 0} = read_ledger(conn)
    end

    test "rejects amounts that are not usable as a payment", %{conn: conn} do
      for amount <- [0, -100, "100", 100.5, nil] do
        assert %{"status" => "rejected", "code" => "invalid_amount"} =
                 submit_one(conn, payment_op(%{amount_cents: amount})),
               "expected invalid_amount for #{inspect(amount)}"
      end

      assert %{"status" => "rejected", "code" => "invalid_amount"} =
               submit_one(conn, Map.delete(payment_op(), "amount_cents"))

      assert %{"deposit_paid_cents" => 0, "revision" => 1} = read_group(conn, "group-81")
    end

    test "rejects a payment for a missing group", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             } = submit_one(conn, payment_op(%{group_id: "group-none"}))
    end

    test "rejects a payment for a cancelled group", %{conn: conn} do
      submit_one(conn, cancel_op())

      assert %{"status" => "rejected", "code" => "group_not_active"} =
               submit_one(conn, payment_op())

      assert %{"cash_held_cents" => 0} = read_ledger(conn)
    end

    test "rejects a payment without a group identifier", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "invalid_operation"} =
               submit_one(conn, Map.delete(payment_op(), "group_id"))
    end
  end
end
