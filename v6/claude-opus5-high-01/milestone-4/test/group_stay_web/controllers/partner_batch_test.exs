defmodule GroupStayWeb.PartnerBatchTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "POST /api/v1/partner-batches" do
    test "returns one result per operation in the submitted order", %{conn: conn} do
      operations = [
        open_group_op(%{operation_id: "op-1", group_id: "group-1"}),
        open_group_op(%{operation_id: "op-2", group_id: "group-2"}),
        payment_op(%{operation_id: "op-3", group_id: "group-1"})
      ]

      assert %{"results" => results} = submit(conn, operations)
      assert ~w(op-1 op-2 op-3) == Enum.map(results, & &1["operation_id"])
      assert Enum.all?(results, &(&1["status"] == "applied"))
    end

    test "an operation observes changes made earlier in the same batch", %{conn: conn} do
      assert %{"results" => [_open, _pay, %{"outstanding_deposit_cents" => 0}]} =
               submit(conn, [
                 open_group_op(),
                 payment_op(%{operation_id: "op-2", amount_cents: 9500}),
                 payment_op(%{operation_id: "op-3", amount_cents: 10_000})
               ])
    end

    test "a rejection neither undoes earlier work nor stops later operations", %{conn: conn} do
      assert %{"results" => results} =
               submit(conn, [
                 open_group_op(),
                 payment_op(%{operation_id: "op-2", amount_cents: 500_000}),
                 payment_op(%{operation_id: "op-3", amount_cents: 5000}),
                 open_group_op(%{operation_id: "op-4", type: "unknown_type"}),
                 cancel_op(%{operation_id: "op-5", occurred_on: "2026-11-26"})
               ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "rejected", "code" => "invalid_operation"},
               %{"status" => "applied", "revision" => 3, "refunded_cents" => 5000}
             ] = results

      assert %{"status" => "cancelled", "deposit_paid_cents" => 5000} =
               read_group(conn, "group-81")
    end

    test "an empty operations array is applied and returns no results", %{conn: conn} do
      assert %{"results" => []} = submit(conn, [])
    end

    test "a body without an operations array is an invalid batch", %{conn: conn} do
      for body <- [%{}, %{"operations" => "many"}, %{"ops" => []}, [], "batch"] do
        assert %{"error" => %{"code" => "invalid_batch"}} =
                 conn |> post_batch(body) |> json_response(422),
               "expected invalid_batch for #{inspect(body)}"
      end
    end
  end
end
