defmodule GroupStay.OperationsTest do
  use GroupStay.DataCase

  alias GroupStay.Operations

  @payment %{
    "operation_id" => "op-pay",
    "type" => "record_cash_payment",
    "occurred_on" => "2026-10-04",
    "group_id" => "group-81",
    "amount_cents" => 10_000
  }

  describe "remember/3" do
    test "retains the type and the complete submitted content" do
      {:ok, _record} = Operations.remember("op-pay", @payment, %{status: "applied"})

      assert {:ok, record} = Operations.fetch("op-pay")
      assert record.type == "record_cash_payment"
      assert Operations.submitted_content(record) == @payment
    end

    test "retains a submission GroupStay could not type" do
      submission = %{"operation_id" => "op-odd", "type" => 7, "amount_cents" => 1}

      {:ok, _record} = Operations.remember("op-odd", submission, %{status: "rejected"})

      assert {:ok, record} = Operations.fetch("op-odd")
      assert record.type == nil
      assert Operations.submitted_content(record) == submission
    end

    test "refuses a second record for the same identifier and keeps the first" do
      {:ok, _record} = Operations.remember("op-pay", @payment, %{status: "applied"})

      assert {:error, changeset} =
               Operations.remember("op-pay", %{"operation_id" => "op-pay"}, %{
                 status: "rejected"
               })

      assert %{operation_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, record} = Operations.fetch("op-pay")
      assert record.result == %{"status" => "applied"}
      assert Operations.submitted_content(record) == @payment
    end

    test "reports an unused identifier as missing" do
      assert :error = Operations.fetch("op-pay")
    end
  end

  describe "same_request?/2" do
    setup do
      {:ok, record} = Operations.remember("op-pay", @payment, %{status: "applied"})
      %{record: record}
    end

    test "accepts the submission it was created from", %{record: record} do
      assert Operations.same_request?(record, @payment)
      assert Operations.same_request?(record, Map.new(Enum.reverse(Map.to_list(@payment))))
    end

    test "refuses any other submission", %{record: record} do
      refute Operations.same_request?(record, Map.put(@payment, "amount_cents", 9999))
      refute Operations.same_request?(record, Map.put(@payment, "expected_revision", 1))
      refute Operations.same_request?(record, Map.delete(@payment, "occurred_on"))
    end
  end

  describe "in_commit_order/0" do
    test "reads records back in the order they were committed" do
      for index <- 1..5 do
        {:ok, _record} =
          Operations.remember("op-#{index}", %{"operation_id" => "op-#{index}"}, %{
            status: "applied"
          })
      end

      assert ~w(op-1 op-2 op-3 op-4 op-5) ==
               Enum.map(Operations.in_commit_order(), & &1.operation_id)
    end

    test "starts empty" do
      assert [] == Operations.in_commit_order()
    end
  end

  describe "durability" do
    test "records live in the database rather than in process state" do
      {:ok, _record} = Operations.remember("op-pay", @payment, %{status: "applied"})

      assert %{rows: [["op-pay", "record_cash_payment"]]} =
               Repo.query!("SELECT operation_id, type FROM operations")
    end
  end
end
