defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Groups.OperationRecord

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group do
    %{
      "operation_id" => "open-durable",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "durable-group",
      "guest_id" => "durable-guest",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment(operation_id, amount_cents, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "durable-group",
        "amount_cents" => amount_cents
      },
      extra
    )
  end

  test "replays an applied result without applying its effects twice and rejects changed payloads",
       %{
         conn: conn
       } do
    opening = open_group()
    payment = payment("pay-durable", 2_000)
    [opening_result, payment_result] = submit(conn, [opening, payment])

    assert [^opening_result, ^payment_result] = submit(conn, [opening, payment])

    assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
             submit(conn, [payment("pay-durable", 2_001)])

    assert %{"data" => group} =
             conn |> get("/api/v1/groups/durable-group") |> json_response(200)

    assert group["revision"] == 2
    assert group["deposit_paid_cents"] == 2_000

    assert %{"data" => ^payment_result} =
             conn |> get("/api/v1/operations/pay-durable") |> json_response(200)

    assert %{"data" => ^opening_result} =
             conn |> get("/api/v1/operations/open-durable") |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             conn |> get("/api/v1/operations/not-recorded") |> json_response(404)
  end

  test "remembers stale rejections exactly and retains submissions in first-commit order", %{
    conn: conn
  } do
    opening = open_group()
    stale_payment = payment("stale-payment", 1_000, %{"expected_revision" => 0})
    current_payment = payment("current-payment", 1_000, %{"expected_revision" => 1})

    [_, stale_result, current_result] =
      submit(conn, [opening, stale_payment, current_payment])

    assert stale_result == %{
             "operation_id" => "stale-payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "durable-group",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert %{"status" => "applied", "revision" => 2} = current_result
    assert [^stale_result] = submit(conn, [stale_payment])

    assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
             submit(conn, [payment("stale-payment", 1_000, %{"expected_revision" => 2})])

    assert %{"data" => ^stale_result} =
             conn |> get("/api/v1/operations/stale-payment") |> json_response(200)

    records =
      GroupStay.Repo.all(
        from record in OperationRecord,
          order_by: [asc: record.id]
      )

    assert Enum.map(records, & &1.operation_id) == [
             "open-durable",
             "stale-payment",
             "current-payment"
           ]

    stale_record = Enum.at(records, 1)
    assert stale_record.operation_type == "record_cash_payment"
    assert stale_record.submission == stale_payment
    assert stale_record.result == stale_result
  end

  test "keeps a rejection when later work makes the operation valid", %{conn: conn} do
    payment_before_open = payment("before-open", 1_000)
    [not_found] = submit(conn, [payment_before_open])
    assert not_found["code"] == "group_not_found"

    assert [%{"status" => "applied", "revision" => 1}] = submit(conn, [open_group()])
    assert [^not_found] = submit(conn, [payment_before_open])

    assert %{"data" => group} =
             conn |> get("/api/v1/groups/durable-group") |> json_response(200)

    assert group["revision"] == 1
    assert group["deposit_paid_cents"] == 0
  end

  test "concurrent exact retries have at most one effect", %{conn: conn} do
    assert [%{"status" => "applied", "revision" => 1}] = submit(conn, [open_group()])
    operation = payment("concurrent-payment", 1_000)

    results =
      1..6
      |> Task.async_stream(
        fn _ -> GroupStay.Groups.process_batch([operation]) end,
        max_concurrency: 6,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               "operation_id" => "concurrent-payment",
               "status" => "applied",
               "group_id" => "durable-group",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 3_000,
               "revision" => 2
             }
           ]

    assert %{"data" => group} =
             conn |> get("/api/v1/groups/durable-group") |> json_response(200)

    assert group["revision"] == 2
    assert group["deposit_paid_cents"] == 1_000
  end

  test "JSON object key order is ignored while array order remains significant", %{conn: conn} do
    first_payload =
      ~s({"operations":[{"operation_id":"audit-order","type":"unknown","extra":{"left":1,"items":[1,2]}}]})

    reordered_payload =
      ~s({"operations":[{"extra":{"items":[1,2],"left":1},"type":"unknown","operation_id":"audit-order"}]})

    changed_array_payload =
      ~s({"operations":[{"operation_id":"audit-order","type":"unknown","extra":{"left":1,"items":[2,1]}}]})

    send_raw = fn conn, body ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", body)
      |> json_response(200)
      |> Map.fetch!("results")
    end

    [rejected] = send_raw.(conn, first_payload)
    assert [^rejected] = send_raw.(conn, reordered_payload)

    assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
             send_raw.(conn, changed_array_payload)

    assert %{"data" => ^rejected} =
             conn |> get("/api/v1/operations/audit-order") |> json_response(200)

    record = GroupStay.Repo.get_by!(OperationRecord, operation_id: "audit-order")
    assert record.submission["extra"]["items"] == [1, 2]
    assert record.submission["type"] == "unknown"
  end

  test "unexpected persistence errors abort and leave no domain changes or idempotency result", %{
    conn: conn
  } do
    opening = open_group()

    GroupStay.Repo.query!("""
    CREATE TRIGGER fail_operation_record_insert
    BEFORE INSERT ON operation_records
    BEGIN
      SELECT RAISE(ABORT, 'injected operation record failure');
    END;
    """)

    assert_raise Exqlite.Error, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: [opening]}))
    end

    GroupStay.Repo.query!("DROP TRIGGER fail_operation_record_insert")

    assert GroupStay.Repo.get_by(OperationRecord, operation_id: "open-durable") == nil

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/durable-group") |> json_response(404)
  end
end
