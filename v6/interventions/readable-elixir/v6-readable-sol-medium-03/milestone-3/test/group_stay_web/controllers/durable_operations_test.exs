defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Deposits.OperationRecord
  alias GroupStay.Repo

  describe "durable operation receipts" do
    test "replays an applied result exactly without applying its effects again", %{conn: conn} do
      open = open_group()
      first_payment = payment("payment-1", 5_000)

      assert %{"results" => [_, original_result]} = post_operations(conn, [open, first_payment])

      assert %{"results" => [_later_payment, replayed_result]} =
               post_operations(build_conn(), [
                 payment("payment-2", 1_000),
                 first_payment
               ])

      assert replayed_result == original_result
      assert replayed_result["revision"] == 2
      assert replayed_result["outstanding_deposit_cents"] == 14_500

      assert get_group("group-1")["revision"] == 3

      assert get(build_conn(), "/api/v1/ledger")
             |> json_response(200)
             |> get_in(["data", "cash_held_cents"]) == 6_000
    end

    test "remembers a rejection even after domain state changes", %{conn: conn} do
      rejected_payment = payment("too-early", 1_000)

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               post_operations(conn, [rejected_payment])

      post_operations(build_conn(), [open_group()])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               post_operations(build_conn(), [rejected_payment])

      assert get_group("group-1")["revision"] == 1
    end

    test "replays the revision details observed by a stale operation", %{conn: conn} do
      post_operations(conn, [open_group(), payment("applied-payment", 1_000)])

      stale = Map.put(payment("stale-payment", 100), "expected_revision", 1)

      assert %{"results" => [original]} = post_operations(build_conn(), [stale])

      post_operations(build_conn(), [payment("later-payment", 1_000)])

      assert %{"results" => [replayed]} = post_operations(build_conn(), [stale])
      assert replayed == original
      assert replayed["expected_revision"] == 1
      assert replayed["actual_revision"] == 2

      corrected = Map.put(stale, "expected_revision", 3)

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               post_operations(build_conn(), [corrected])
    end

    test "rejects changed payloads without replacing the original receipt", %{conn: conn} do
      original = open_group()
      post_operations(conn, [original])

      changed = %{original | "rooms" => Enum.reverse(original["rooms"])}

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = post_operations(build_conn(), [changed])

      assert get_operation("open-1") == %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-1",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end

    test "treats JSON object key order as irrelevant", %{conn: conn} do
      original =
        ~s({"operations":[{"operation_id":"unknown-1","type":"unknown","metadata":{"a":1,"b":2}}]})

      reordered =
        ~s({"operations":[{"metadata":{"b":2,"a":1},"type":"unknown","operation_id":"unknown-1"}]})

      first = post_raw_json(conn, original)
      second = post_raw_json(build_conn(), reordered)

      assert first == second

      assert first == %{
               "results" => [
                 %{
                   "operation_id" => "unknown-1",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 }
               ]
             }
    end

    test "reads stored results and returns the documented missing-operation error", %{conn: conn} do
      assert get(conn, "/api/v1/operations/not-here") |> json_response(404) ==
               %{"error" => %{"code" => "operation_not_found"}}

      post_operations(build_conn(), [payment("missing-payment", 100)])

      assert get_operation("missing-payment") == %{
               "operation_id" => "missing-payment",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "retains complete submissions, types, and first-commit order for audit", %{conn: conn} do
      first = Map.put(payment("audit-first", 100), "partner_metadata", %{"trace" => [1, 2]})
      second = %{"operation_id" => "audit-second", "type" => "unsupported", "extra" => true}

      post_operations(conn, [first, second])

      records =
        from(record in OperationRecord,
          where: record.operation_id in ["audit-first", "audit-second"],
          order_by: record.id
        )
        |> Repo.all()

      assert Enum.map(records, & &1.operation_id) == ["audit-first", "audit-second"]
      assert Enum.map(records, & &1.operation_type) == ["record_cash_payment", "unsupported"]
      assert Enum.map(records, & &1.submitted_content) == [first, second]
      assert Enum.map(records, & &1.result["status"]) == ["rejected", "rejected"]
    end
  end

  defp post_operations(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp post_raw_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
    |> json_response(200)
  end

  defp get_operation(operation_id) do
    get(build_conn(), "/api/v1/operations/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_group(group_id) do
    get(build_conn(), "/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_group do
    %{
      "operation_id" => "open-1",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp payment(operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
  end
end
