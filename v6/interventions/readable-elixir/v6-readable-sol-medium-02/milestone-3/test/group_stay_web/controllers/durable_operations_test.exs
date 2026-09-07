defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Repo

  describe "durable partner-operation idempotency" do
    test "replays an applied result without observing or changing newer group state", %{
      conn: conn
    } do
      payment = payment_operation("pay-original", 5_000, 1)

      assert %{"results" => [_, original, _]} =
               submit(conn, [
                 open_operation(),
                 payment,
                 payment_operation("pay-later", 1_000, 2)
               ])

      assert original["revision"] == 2
      assert original["outstanding_deposit_cents"] == 14_500

      assert %{"results" => [replayed]} = submit(build_conn(), [payment])
      assert replayed == original

      assert %{
               "data" => %{
                 "revision" => 3,
                 "deposit_paid_cents" => 6_000,
                 "outstanding_deposit_cents" => 13_500
               }
             } = get_json("/api/v1/groups/group-81")
    end

    test "remembers rejected results even when later state would allow the operation", %{
      conn: conn
    } do
      payment = payment_operation("pay-before-open", 1_000, 1)

      assert %{"results" => [rejected]} = submit(conn, [payment])
      assert rejected["code"] == "group_not_found"

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(build_conn(), [open_operation()])

      assert %{"results" => [replayed]} = submit(build_conn(), [payment])
      assert replayed == rejected

      assert get_json("/api/v1/groups/group-81")["data"]["revision"] == 1
    end

    test "rejects identifier reuse with a different payload and keeps the original result", %{
      conn: conn
    } do
      stale_payment = payment_operation("stale-payment", 1_000, 99)

      assert %{"results" => [_, stale]} = submit(conn, [open_operation(), stale_payment])

      assert stale == %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      corrected = Map.put(stale_payment, "expected_revision", 1)

      assert %{"results" => [conflict]} = submit(build_conn(), [corrected])

      assert conflict == %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert %{"data" => ^stale} = get_json("/api/v1/operations/stale-payment")
      assert get_json("/api/v1/groups/group-81")["data"]["revision"] == 1
    end

    test "stores complete submissions and their first-commit order for audit", %{conn: conn} do
      invalid = %{
        "operation_id" => "invalid-with-content",
        "type" => "unknown_type",
        "occurred_on" => "2026-10-03",
        "metadata" => %{"agency" => "north", "tags" => ["vip", "late"]}
      }

      assert %{"results" => [_, %{"code" => "invalid_operation"}]} =
               submit(conn, [open_operation(), invalid])

      records = Repo.all(from record in OperationRecord, order_by: record.id)

      assert Enum.map(records, & &1.operation_id) == ["open-1", "invalid-with-content"]
      assert List.last(records).operation_type == "unknown_type"
      assert List.last(records).submission == invalid
    end

    test "returns stored results and the documented missing-operation error", %{conn: conn} do
      assert %{"results" => [result]} = submit(conn, [open_operation()])
      assert %{"data" => ^result} = get_json("/api/v1/operations/open-1")

      assert %{"error" => %{"code" => "operation_not_found"}} =
               build_conn()
               |> get("/api/v1/operations/missing")
               |> json_response(404)
    end

    test "applies concurrent equivalent submissions at most once", %{conn: conn} do
      # Establish the group before both callers race for the same payment identifier.
      assert %{"results" => [%{"status" => "applied"}]} = submit(conn, [open_operation()])
      payment = payment_operation("concurrent-payment", 2_000, 1)

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> GroupStay.PartnerOperations.process_batch([payment]) end)
        end

      assert [first, second] = Enum.map(tasks, &Task.await(&1, 5_000))
      assert first == second

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 2_000}} =
               get_json("/api/v1/groups/group-81")
    end
  end

  defp open_operation do
    %{
      "operation_id" => "open-1",
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
    }
  end

  defp payment_operation(operation_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp get_json(path) do
    build_conn()
    |> get(path)
    |> json_response(200)
  end
end
