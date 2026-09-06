defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp raw_json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
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
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  test "retries return the stored applied result and the lookup endpoint exposes it", %{
    conn: conn
  } do
    operation = open_operation()

    assert %{"results" => [first]} =
             json_post(conn, %{"operations" => [operation]}) |> json_response(200)

    assert %{"results" => [retry]} =
             json_post(conn, %{"operations" => [operation]}) |> json_response(200)

    assert retry == first

    assert get(build_conn(), "/api/v1/operations/open-1") |> json_response(200) == %{
             "data" => first
           }

    assert get(build_conn(), "/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert Repo.aggregate(Operation, :count, :id) == 1
  end

  test "remembered rejections replay their original revision details", %{conn: conn} do
    assert json_post(conn, %{"operations" => [open_operation()]}) |> json_response(200)

    stale = %{
      "operation_id" => "stale-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 1,
      "expected_revision" => 0
    }

    assert %{"results" => [first_rejection]} =
             json_post(conn, %{"operations" => [stale]}) |> json_response(200)

    assert first_rejection["code"] == "stale_revision"
    assert first_rejection["actual_revision"] == 1

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 1
                 }
               ]
             })
             |> json_response(200)

    assert %{"results" => [retry]} =
             json_post(conn, %{"operations" => [stale]}) |> json_response(200)

    assert retry == first_rejection

    assert get(build_conn(), "/api/v1/operations/stale-payment") |> json_response(200) == %{
             "data" => first_rejection
           }
  end

  test "object key order is ignored, while array order causes an operation conflict", %{
    conn: conn
  } do
    first_body =
      ~s({"operations":[{"operation_id":"invalid-1","type":"unknown","metadata":{"a":1,"b":2},"values":[1,2]}]})

    reordered_body =
      ~s({"operations":[{"values":[1,2],"metadata":{"b":2,"a":1},"type":"unknown","operation_id":"invalid-1"}]})

    reordered_array_body =
      ~s({"operations":[{"operation_id":"invalid-1","type":"unknown","metadata":{"b":2,"a":1},"values":[2,1]}]})

    assert %{"results" => [first]} = raw_json_post(conn, first_body) |> json_response(200)
    assert %{"results" => [retry]} = raw_json_post(conn, reordered_body) |> json_response(200)
    assert retry == first

    assert %{"results" => [conflict]} =
             raw_json_post(conn, reordered_array_body) |> json_response(200)

    assert conflict == %{
             "operation_id" => "invalid-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }
  end

  test "a corrected expected revision is a conflict and cannot replace a stale result", %{
    conn: conn
  } do
    assert json_post(conn, %{"operations" => [open_operation()]}) |> json_response(200)

    stale = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 1,
      "expected_revision" => 0
    }

    assert %{"results" => [stale_result]} =
             json_post(conn, %{"operations" => [stale]}) |> json_response(200)

    corrected = Map.put(stale, "expected_revision", 1)

    assert %{"results" => [conflict]} =
             json_post(conn, %{"operations" => [corrected]}) |> json_response(200)

    assert conflict == %{
             "operation_id" => "payment-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert %{"results" => [retry]} =
             json_post(conn, %{"operations" => [stale]}) |> json_response(200)

    assert retry == stale_result
  end

  test "handled invalid operations with non-string types are remembered", %{conn: conn} do
    operation = %{"operation_id" => "invalid-type", "type" => %{"unexpected" => true}}

    assert %{"results" => [first]} =
             json_post(conn, %{"operations" => [operation]}) |> json_response(200)

    assert first == %{
             "operation_id" => "invalid-type",
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    assert %{"results" => [retry]} =
             json_post(conn, %{"operations" => [operation]}) |> json_response(200)

    assert retry == first

    assert Repo.get_by(Operation, operation_id: "invalid-type").operation_type ==
             "{\"unexpected\":true}"
  end

  test "durable records retain type, submitted content, and commit order", %{conn: conn} do
    first = %{
      "operation_id" => "audit-1",
      "type" => "not-a-real-operation",
      "nested" => %{"z" => 1, "a" => ["x", "y"]}
    }

    second = %{
      "operation_id" => "audit-2",
      "type" => "another-invalid-operation",
      "nested" => %{"a" => ["x", "y"], "z" => 1}
    }

    assert json_post(conn, %{"operations" => [first, second]}) |> json_response(200)

    records = Repo.all(from operation in Operation, order_by: operation.id)

    assert Enum.map(records, & &1.operation_id) == ["audit-1", "audit-2"]
    assert Enum.map(records, & &1.commit_sequence) == [1, 2]

    assert Enum.map(records, & &1.operation_type) == [
             "not-a-real-operation",
             "another-invalid-operation"
           ]

    assert Enum.map(records, &Jason.decode!(&1.payload_json)) == [first, second]
  end

  test "unidentified operations remain handled rejections without a durable key", %{conn: conn} do
    assert %{"results" => [missing_id, invalid_shape]} =
             json_post(conn, %{"operations" => [%{"type" => "unknown"}, nil]})
             |> json_response(200)

    assert missing_id == %{
             "operation_id" => nil,
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    assert invalid_shape == %{
             "operation_id" => nil,
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    assert Repo.aggregate(Operation, :count, :id) == 0
  end
end
