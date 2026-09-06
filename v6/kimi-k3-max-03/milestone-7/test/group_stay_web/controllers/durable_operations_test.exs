defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query
  import GroupStayWeb.BatchHelpers

  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_operation(operation_id) do
    get(build_conn(), ~p"/api/v1/operations/#{operation_id}")
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)
  end

  defp get_ledger do
    conn = get(build_conn(), ~p"/api/v1/ledger")
    json_response(conn, 200)
  end

  describe "retry behavior" do
    test "an exact retry returns the original result without changing state" do
      operations = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 8_000})
      ]

      conn = post_batch(operations)
      assert %{"results" => first_results} = json_response(conn, 200)

      conn = post_batch(operations)
      assert %{"results" => ^first_results} = json_response(conn, 200)

      # The payment was applied exactly once.
      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 8_000}} =
               get_group("group-81")

      assert %{"data" => %{"cash_held_cents" => 8_000}} = get_ledger()
      assert Repo.aggregate(OperationRecord, :count) == 2
    end

    test "object key order is irrelevant for payload equivalence" do
      conn = post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])
      assert %{"results" => [first]} = json_response(conn, 200)

      # Same content, built with a different key order.
      reordered = %{
        "amount_cents" => 10_000,
        "group_id" => "group-missing",
        "occurred_on" => "2026-10-04",
        "type" => "record_cash_payment",
        "operation_id" => "op-pay"
      }

      conn = post_batch([reordered])
      assert %{"results" => [^first]} = json_response(conn, 200)
      assert Repo.aggregate(OperationRecord, :count) == 1
    end

    test "array order stays significant" do
      conn = post_batch([open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      reordered_rooms =
        open_group_op(%{
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        })

      conn = post_batch([reordered_rooms])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)

      # The original record still stands and replays.
      conn = post_batch([open_group_op()])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)
    end

    test "a rejected result is remembered even when it would now be valid" do
      conn = post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)

      # The group now exists, but the retry still receives the original rejection.
      conn = post_batch([open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = get_group("group-81")
    end

    test "reusing an identifier with a different payload is rejected without replacing it" do
      conn = post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])
      assert %{"results" => [%{"status" => "rejected"}]} = json_response(conn, 200)

      conn =
        post_batch([
          record_cash_payment_op(%{"group_id" => "group-missing", "amount_cents" => 5})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "operation_id_conflict",
                   "group_id" => "group-missing"
                 }
               ]
             } = json_response(conn, 200)

      # The original record was not replaced and is still served.
      conn = post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)

      assert Repo.aggregate(OperationRecord, :count) == 1
    end

    test "stale-revision retries return the stored details verbatim" do
      post_batch([open_group_op()])
      post_batch([record_cash_payment_op(%{"amount_cents" => 5_000})])

      stale =
        record_cash_payment_op(%{
          "operation_id" => "op-1002",
          "expected_revision" => 1,
          "amount_cents" => 100
        })

      conn = post_batch([stale])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 } = original
               ]
             } = json_response(conn, 200)

      # The group moves on, but the replay still shows the original numbers.
      post_batch([record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 100})])

      conn = post_batch([stale])
      assert %{"results" => [^original]} = json_response(conn, 200)
      assert %{"data" => %{"revision" => 3}} = get_group("group-81")

      # Retrying with a corrected revision is a different payload.
      corrected = Map.put(stale, "expected_revision", 3)

      conn = post_batch([corrected])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)
    end

    test "a retry inside the same batch replays the stored result" do
      operations = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 8_000}),
        record_cash_payment_op(%{"amount_cents" => 8_000})
      ]

      conn = post_batch(operations)

      assert %{"results" => [open_result, payment_result, replay_result]} =
               json_response(conn, 200)

      assert %{"status" => "applied", "revision" => 1} = open_result
      assert %{"status" => "applied", "revision" => 2} = payment_result
      assert replay_result == payment_result

      assert %{"data" => %{"deposit_paid_cents" => 8_000}} = get_group("group-81")
    end

    test "a conflict does not stop later operations in the batch" do
      operations = [
        open_group_op(),
        # Same identifier as the first operation, different payload.
        open_group_op(%{"rate_plan" => "advance_purchase"}),
        record_cash_payment_op(%{"amount_cents" => 4_000})
      ]

      conn = post_batch(operations)

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "rejected", "code" => "operation_id_conflict"},
                 %{"status" => "applied", "revision" => 2}
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"deposit_paid_cents" => 4_000}} = get_group("group-81")
    end

    test "handled rejections commit their record while leaving the domain unchanged" do
      conn = post_batch([open_group_op(%{"rate_plan" => "nope"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rate_plan"}]} =
               json_response(conn, 200)

      assert Repo.aggregate(OperationRecord, :count) == 1
      assert Repo.aggregate(GroupStay.Groups.Group, :count) == 0

      conn = get_operation("op-open")

      assert %{"data" => %{"status" => "rejected", "code" => "invalid_rate_plan"}} =
               json_response(conn, 200)
    end
  end

  describe "durable audit records" do
    test "every remembered operation keeps its type, content, and commit order" do
      operations = [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 8_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20"})
      ]

      conn = post_batch(operations)
      assert %{"results" => results} = json_response(conn, 200)

      records = Repo.all(from(r in OperationRecord, order_by: [asc: r.id]))

      assert length(records) == 3
      assert Enum.map(records, & &1.operation_id) == ["op-open", "op-pay", "op-cancel"]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "cancel_group"
             ]

      for {record, operation, result} <- Enum.zip([records, operations, results]) do
        assert Jason.decode!(record.payload) == operation
        assert Jason.decode!(record.result) == result
      end
    end

    test "operations without an operation_id are not remembered" do
      conn = post_batch([open_group_op() |> Map.delete("operation_id")])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)

      assert Repo.aggregate(OperationRecord, :count) == 0
    end

    test "non-map operations are rejected and not remembered" do
      conn = post_batch(["not-an-operation"])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)

      assert Repo.aggregate(OperationRecord, :count) == 0
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored applied result" do
      post_batch([open_group_op(), record_cash_payment_op(%{"amount_cents" => 8_000})])

      conn = get_operation("op-pay")

      assert %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 8_000,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 2
               }
             } = json_response(conn, 200)
    end

    test "returns the stored rejected result" do
      post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])

      conn = get_operation("op-pay")

      assert %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "group-missing"
               }
             } = json_response(conn, 200)
    end

    test "returns 404 operation_not_found for an unknown identifier" do
      conn = get_operation("op-missing")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end
  end
end
