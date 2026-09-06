defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{OperationRecord, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "hotel-1",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp payment(operation_id, amount, expected_revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
    |> then(fn operation ->
      if expected_revision,
        do: Map.put(operation, "expected_revision", expected_revision),
        else: operation
    end)
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "replays an applied result verbatim without consulting current state", %{conn: conn} do
    operation = payment("pay-1", 500, 1)

    [_, original, _] =
      submit(conn, [open_operation(), operation, payment("pay-2", 500, 2)])

    [retried] = submit(build_conn(), [operation])

    assert retried == original
    assert retried["revision"] == 2

    group = build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
    assert group["data"]["revision"] == 3
    assert group["data"]["cash_paid_cents"] == 1_000
  end

  test "remembers rejections and their original stale-revision details", %{conn: conn} do
    stale = payment("stale", 100, 9)

    [_, original, _] =
      submit(conn, [open_operation(), stale, payment("advance-state", 100, 1)])

    [retried] = submit(build_conn(), [stale])

    assert retried == original
    assert retried["actual_revision"] == 1
    assert retried["code"] == "stale_revision"
  end

  test "rejects a changed payload and preserves the original operation", %{conn: conn} do
    original_submission = open_operation()
    [original] = submit(conn, [original_submission])

    [conflict] =
      submit(build_conn(), [
        open_operation(%{
          "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 20_000}]
        })
      ])

    assert conflict == %{
             "operation_id" => "open-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    record = Repo.get_by!(OperationRecord, operation_id: "open-1")
    assert record.submission == original_submission
    assert record.result == original
    assert Repo.aggregate(OperationRecord, :count) == 1
  end

  test "ignores object key order but treats array order as significant", %{conn: conn} do
    original = %{
      "operation_id" => "unknown-1",
      "type" => "unknown",
      "occurred_on" => "2027-01-01",
      "metadata" => %{"first" => 1, "second" => [1, 2]}
    }

    [original_result] = submit(conn, [original])

    equivalent = %{
      "metadata" => %{"second" => [1, 2], "first" => 1},
      "occurred_on" => "2027-01-01",
      "type" => "unknown",
      "operation_id" => "unknown-1"
    }

    assert submit(build_conn(), [equivalent]) == [original_result]

    changed = put_in(equivalent, ["metadata", "second"], [2, 1])
    assert [conflict] = submit(build_conn(), [changed])
    assert conflict["code"] == "operation_id_conflict"
  end

  test "retains complete submissions and results in first-commit order", %{conn: conn} do
    rejected = %{
      "operation_id" => "bad-1",
      "type" => "unknown",
      "occurred_on" => "2027-01-01",
      "metadata" => %{"b" => 2, "a" => [1, 2]}
    }

    results = submit(conn, [rejected, open_operation()])
    records = Repo.all(from r in OperationRecord, order_by: r.id)

    assert Enum.map(records, & &1.operation_id) == ["bad-1", "open-1"]
    assert Enum.map(records, & &1.operation_type) == ["unknown", "open_group"]
    assert hd(records).submission == rejected
    assert Enum.map(records, & &1.result) == results
  end

  test "reads stored applied and rejected results without exposing submissions", %{conn: conn} do
    [applied, rejected] =
      submit(conn, [open_operation(), payment("bad-payment", 0)])

    assert build_conn() |> get("/api/v1/operations/open-1") |> json_response(200) == %{
             "data" => applied
           }

    assert build_conn()
           |> get("/api/v1/operations/bad-payment")
           |> json_response(200) == %{"data" => rejected}

    assert build_conn() |> get("/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "concurrent retries have one domain effect and one durable record", %{conn: conn} do
    submit(conn, [open_operation()])
    operation = payment("concurrent-payment", 1)

    results =
      1..5
      |> Task.async_stream(fn _ -> GroupStay.Operations.submit([operation]) end)
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) |> length() == 1

    group = build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
    assert group["data"]["cash_paid_cents"] == 1
    assert Repo.aggregate(OperationRecord, :count) == 2
  end

  test "an unexpected persistence fault rolls back domain changes and is not remembered", %{
    conn: conn
  } do
    Repo.query!("""
    CREATE TRIGGER fail_operation_record
    BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fault-1'
    BEGIN
      SELECT RAISE(ABORT, 'forced operation-record failure');
    END
    """)

    operation = open_operation(%{"operation_id" => "fault-1", "group_id" => "fault-group"})

    assert_error_sent 500, fn ->
      post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})
    end

    refute Repo.get_by(OperationRecord, operation_id: "fault-1")

    assert build_conn() |> get("/api/v1/groups/fault-group") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end
end
