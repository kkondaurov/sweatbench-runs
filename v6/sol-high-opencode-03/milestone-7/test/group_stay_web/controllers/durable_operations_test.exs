defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  test "returns the exact applied result on retry without applying it again" do
    open = open_operation("open", "group-1")
    payment = payment_operation("payment", "group-1", 1_000, 1)

    assert [opened, paid] = submit([open, payment])
    assert opened["revision"] == 1
    assert paid["revision"] == 2

    assert [%{"revision" => 3}] =
             submit([payment_operation("later-payment", "group-1", 500, 2)])

    assert submit([payment]) == [paid]

    assert get_group("group-1")
           |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 1_500,
             "revision" => 3
           }

    assert json_response(get(build_conn(), "/api/v1/operations/payment"), 200) == %{
             "data" => paid
           }
  end

  test "remembers rejected results even when current state would accept the operation" do
    payment = payment_operation("early-payment", "group-1", 500, 1)

    assert [rejected] = submit([payment])
    assert rejected["code"] == "group_not_found"

    assert [%{"status" => "applied"}] = submit([open_operation("open", "group-1")])
    assert submit([payment]) == [rejected]
    assert get_group("group-1")["deposit_paid_cents"] == 0
  end

  test "preserves stale revision details and treats a corrected retry as a conflict" do
    stale = payment_operation("stale", "group-1", 100, 1)

    assert [_, _, stale_result, later_result] =
             submit([
               open_operation("open", "group-1"),
               payment_operation("first-payment", "group-1", 100, 1),
               stale,
               payment_operation("later-payment", "group-1", 100, 2)
             ])

    assert stale_result == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert later_result["revision"] == 3
    assert submit([stale]) == [stale_result]

    corrected = Map.put(stale, "expected_revision", 3)
    assert submit([corrected]) == [operation_rejection("stale", "operation_id_conflict")]
    assert get_group("group-1")["revision"] == 3
  end

  test "rejects operation identifier reuse with different content and keeps the original result" do
    original = open_operation("same-id", "group-1")
    conflicting = Map.put(original, "group_id", "group-2")

    assert [applied] = submit([original])

    assert [conflict] = submit([conflicting])
    assert conflict == operation_rejection("same-id", "operation_id_conflict")

    assert submit([original]) == [applied]

    assert json_response(get(build_conn(), "/api/v1/operations/same-id"), 200) == %{
             "data" => applied
           }

    assert json_response(get(build_conn(), "/api/v1/groups/group-2"), 404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "deduplicates equivalent operations within a batch" do
    operation = open_operation("open-once", "group-1")

    assert [first, second] = submit([operation, operation])
    assert second == first
    assert Repo.aggregate(Record, :count) == 1
    assert get_group("group-1")["revision"] == 1
  end

  test "retains complete submissions, types, results, and first-commit order" do
    first =
      open_operation("first", "group-1")
      |> Map.put("partner_metadata", %{"tags" => ["one", "two"], "urgent" => true})

    second = %{
      "operation_id" => "second",
      "type" => "unknown",
      "nested" => %{"value" => nil}
    }

    assert [first_result, second_result] = submit([first, second])

    assert [first_record, second_record] = Repo.all(Record) |> Enum.sort_by(& &1.id)
    assert first_record.id < second_record.id
    assert first_record.operation_type == "open_group"
    assert first_record.submitted_content == first
    assert first_record.result == first_result
    assert second_record.operation_type == "unknown"
    assert second_record.submitted_content == second
    assert second_record.result == second_result
  end

  test "serializes concurrent retries with at-most-once effects" do
    assert [%{"status" => "applied"}] = submit([open_operation("open", "group-1")])
    payment = payment_operation("concurrent-payment", "group-1", 100, 1)

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn -> GroupStay.Operations.submit([payment]) |> List.first() end)
      end)
      |> Task.await_many()

    assert [first, second] = results
    assert second == first
    assert first.status == "applied"
    assert first.revision == 2
    assert Repo.aggregate(Record, :count, :id) == 2

    assert get_group("group-1")
           |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 100,
             "revision" => 2
           }
  end

  test "rolls back domain changes and aborts the batch on an unexpected failure" do
    assert [%{"status" => "applied"}] = submit([open_operation("open", "group-1")])

    Repo.query!("""
    CREATE TRIGGER fail_operation_record
    BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'explode'
    BEGIN
      SELECT RAISE(FAIL, 'forced operation record failure');
    END
    """)

    exploding = payment_operation("explode", "group-1", 100, 1)
    later = payment_operation("later", "group-1", 100, 2)

    assert_raise Exqlite.Error, ~r/forced operation record failure/, fn ->
      GroupStay.Operations.submit([exploding, later])
    end

    assert get_group("group-1")
           |> Map.take(["deposit_paid_cents", "revision"]) == %{
             "deposit_paid_cents" => 0,
             "revision" => 1
           }

    refute Repo.get_by(Record, operation_id: "explode")
    refute Repo.get_by(Record, operation_id: "later")

    Repo.query!("DROP TRIGGER fail_operation_record")

    assert [%{"revision" => 2}, %{"revision" => 3}] = submit([exploding, later])
  end

  test "returns the operation not found error" do
    assert json_response(get(build_conn(), "/api/v1/operations/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp submit(operations) do
    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    json_response(conn, 200)["results"]
  end

  defp get_group(group_id) do
    json_response(get(build_conn(), "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp open_operation(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment_operation(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp operation_rejection(operation_id, code) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
  end
end
