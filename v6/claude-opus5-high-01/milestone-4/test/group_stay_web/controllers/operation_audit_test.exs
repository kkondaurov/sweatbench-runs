defmodule GroupStayWeb.OperationAuditTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  alias GroupStay.Operations

  describe "the durable record as an audit trail" do
    test "retains every remembered submission in commit order", %{conn: conn} do
      remembered = [
        open_group_op(),
        payment_op(%{operation_id: "op-too-much", amount_cents: 500_000}),
        payment_op(),
        open_group_op(%{operation_id: "op-odd", type: "teleport_group"}),
        cancel_op()
      ]

      # The operation carrying no identifier cannot be remembered; every other one
      # is retained once, in the order it was committed.
      submit(conn, List.insert_at(remembered, 4, Map.delete(payment_op(), "operation_id")))

      records = Operations.in_commit_order()

      assert ~w(op-open op-too-much op-pay op-odd op-cancel) ==
               Enum.map(records, & &1.operation_id)

      assert ~w(open_group record_cash_payment record_cash_payment teleport_group cancel_group) ==
               Enum.map(records, & &1.type)

      assert remembered == Enum.map(records, &Operations.submitted_content/1)

      assert ~w(applied rejected applied rejected applied) ==
               Enum.map(records, & &1.result["status"])
    end

    test "retains the submission as sent, whatever order its keys arrived in", %{conn: conn} do
      body =
        ~s({"operations":[{"amount_cents":10000,"group_id":"group-81",) <>
          ~s("occurred_on":"2026-10-04","type":"record_cash_payment","operation_id":"op-pay"}]})

      submit_one(conn, open_group_op())
      conn |> post_raw_batch(body) |> json_response(200)

      assert {:ok, record} = Operations.fetch("op-pay")

      assert %{
               "operation_id" => "op-pay",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "group-81",
               "amount_cents" => 10_000
             } == Operations.submitted_content(record)
    end

    test "a retry does not add a second record", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op(), payment_op()])
      submit_one(conn, payment_op())
      submit_one(conn, payment_op(%{amount_cents: 1}))

      assert ~w(op-open op-pay) == Enum.map(Operations.in_commit_order(), & &1.operation_id)
    end
  end
end
