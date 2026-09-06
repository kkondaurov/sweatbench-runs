defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Operations
  alias GroupStay.PartnerOperations.PartnerOperation
  alias GroupStay.Repo

  describe "durable operation retries" do
    test "replays an applied result verbatim without consulting or changing current state", %{
      conn: conn
    } do
      submit(conn, [open(), cash("pay-once", 100)])

      original = operation_result(conn, "pay-once")

      assert original == %{
               "operation_id" => "pay-once",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 100,
               "outstanding_deposit_cents" => 100,
               "revision" => 2
             }

      submit(conn, [cash("pay-later", 50)])
      retried = submit(conn, [cash("pay-once", 100)]) |> only_result()

      assert retried == original

      group = get_group(conn)
      assert group["cash_paid_cents"] == 150
      assert group["revision"] == 3
    end

    test "remembers a rejection even after later operations make the domain state valid", %{
      conn: conn
    } do
      missing = cash("future-payment", 50)

      original = submit(conn, [missing]) |> only_result()
      assert original["code"] == "group_not_found"

      submit(conn, [open()])

      assert submit(conn, [missing]) |> only_result() == original

      conflict = submit(conn, [%{missing | "amount_cents" => 75}]) |> only_result()

      assert conflict == %{
               "operation_id" => "future-payment",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert operation_result(conn, "future-payment") == original
      assert get_group(conn)["cash_paid_cents"] == 0
    end

    test "replays the original stale-revision details after the group advances", %{conn: conn} do
      submit(conn, [open(), cash("first-payment", 25)])

      stale = cash("stale-payment", -1) |> Map.put("expected_revision", 1)
      original = submit(conn, [stale]) |> only_result()

      assert Map.take(original, ["code", "expected_revision", "actual_revision"]) == %{
               "code" => "stale_revision",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      submit(conn, [cash("newer-payment", 25)])

      assert submit(conn, [stale]) |> only_result() == original
      assert operation_result(conn, "stale-payment") == original

      corrected = Map.put(stale, "expected_revision", 3)

      assert submit(conn, [corrected]) |> only_result() |> Map.fetch!("code") ==
               "operation_id_conflict"
    end

    test "treats object key order as irrelevant and array order as significant", %{conn: conn} do
      operation = open()
      original = submit(conn, [operation]) |> only_result()

      reordered_objects =
        operation
        |> Enum.reverse()
        |> Map.new()
        |> Map.update!("rooms", fn rooms ->
          Enum.map(rooms, fn room -> room |> Enum.reverse() |> Map.new() end)
        end)

      assert submit(conn, [reordered_objects]) |> only_result() == original

      reversed_rooms = Map.update!(operation, "rooms", &Enum.reverse/1)

      assert submit(conn, [reversed_rooms]) |> only_result() == %{
               "operation_id" => "open-group-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert get_group(conn)["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 500},
               %{"room_id" => "room-b", "nightly_rate_cents" => 500}
             ]
    end

    test "serializes concurrent retries so their effect is applied once", %{conn: conn} do
      submit(conn, [open()])
      operation = cash("concurrent-payment", 100)

      results =
        1..8
        |> Task.async_stream(
          fn _ -> Operations.process_batch([operation]) |> List.first() end,
          max_concurrency: 8,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.uniq(results) == [
               %{
                 "operation_id" => "concurrent-payment",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 100,
                 "revision" => 2
               }
             ]

      group = get_group(conn)
      assert group["cash_paid_cents"] == 100
      assert group["revision"] == 2

      assert Repo.aggregate(
               from(operation in PartnerOperation,
                 where: operation.operation_id == "concurrent-payment"
               ),
               :count
             ) == 1
    end
  end

  describe "operation audit records and reads" do
    test "retains complete submissions and results in first-commit order", %{conn: conn} do
      unknown = %{
        "operation_id" => "audit-rejected",
        "type" => "unknown_operation",
        "occurred_on" => "2026-10-03",
        "metadata" => %{"labels" => ["one", "two"], "attempt" => 1}
      }

      submit(conn, [unknown, open()])
      submit(conn, [%{unknown | "metadata" => %{"labels" => ["two", "one"]}}])

      records = Repo.all(from operation in PartnerOperation, order_by: operation.id)

      assert Enum.map(records, & &1.operation_id) == ["audit-rejected", "open-group-1"]

      rejected = List.first(records)
      assert rejected.operation_type == "unknown_operation"
      assert rejected.submitted_content == unknown
      assert rejected.result["code"] == "invalid_operation"
    end

    test "stores handled invalid operations that have an identifier", %{conn: conn} do
      invalid = %{
        "operation_id" => "invalid-type",
        "type" => 17,
        "occurred_on" => "2026-10-03",
        "extra" => %{"present" => true}
      }

      result = submit(conn, [invalid]) |> only_result()
      assert result["code"] == "invalid_operation"

      record = Repo.get_by!(PartnerOperation, operation_id: "invalid-type")
      assert record.operation_type == nil
      assert record.submitted_content == invalid
      assert record.result == result
    end

    test "returns operation_not_found for an unknown identifier", %{conn: conn} do
      conn = get(conn, "/api/v1/operations/not-recorded")

      assert json_response(conn, 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(%{"results" => [result]}), do: result

  defp operation_result(conn, operation_id) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_group(conn) do
    conn
    |> get("/api/v1/groups/group-1")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open do
    %{
      "operation_id" => "open-group-1",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 500},
        %{"room_id" => "room-b", "nightly_rate_cents" => 500}
      ]
    }
  end

  defp cash(operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
  end
end
