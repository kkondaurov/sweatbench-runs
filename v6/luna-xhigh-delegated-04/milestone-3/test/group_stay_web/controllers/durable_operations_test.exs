defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{Operation, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp result(conn, operation),
    do: post_batch(conn, [operation]) |> json_response(200) |> Map.fetch!("results") |> hd()

  test "replays an applied result after domain state changes and exposes it by id", %{conn: conn} do
    operation = open_operation()
    first_result = result(conn, operation)

    assert result(conn, %{
             "operation_id" => "pay-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "amount_cents" => 10
           })["revision"] == 2

    assert result(conn, operation) == first_result

    assert json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]["revision"] == 2

    assert json_response(get(conn, "/api/v1/operations/open-1"), 200)["data"] == first_result
  end

  test "replays the first occurrence when an operation is repeated in one batch", %{conn: conn} do
    results =
      post_batch(conn, [open_operation(), open_operation()])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 0) == Enum.at(results, 1)
    assert json_response(get(conn, "/api/v1/groups/group-1"), 200)["data"]["revision"] == 1
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "remembers handled rejections, including the original stale revision details", %{
    conn: conn
  } do
    result(conn, open_operation())

    stale_operation = %{
      "operation_id" => "stale-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "amount_cents" => 10,
      "expected_revision" => 0
    }

    assert result(conn, stale_operation) == %{
             "operation_id" => "stale-1",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert result(conn, %{
             "operation_id" => "pay-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "group-1",
             "amount_cents" => 10
           })["revision"] == 2

    assert result(conn, stale_operation) == %{
             "operation_id" => "stale-1",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert json_response(get(conn, "/api/v1/operations/stale-1"), 200)["data"]["actual_revision"] ==
             1
  end

  test "rejects a changed payload without replacing the original record", %{conn: conn} do
    original = %{
      "operation_id" => "remembered-1",
      "type" => "mystery",
      "occurred_on" => "2027-01-03",
      "metadata" => %{"a" => 1, "b" => 2}
    }

    assert result(conn, original)["code"] == "invalid_operation"

    assert result(conn, Map.put(original, "occurred_on", "2027-01-04")) == %{
             "operation_id" => "remembered-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert json_response(get(conn, "/api/v1/operations/remembered-1"), 200)["data"] == %{
             "operation_id" => "remembered-1",
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    record = Repo.get_by!(Operation, operation_id: "remembered-1")
    assert record.operation_type == "mystery"
    assert Jason.decode!(record.payload_json) == original

    assert json_response(get(conn, "/api/v1/operations/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "treats object key order as equivalent while preserving array order", %{conn: conn} do
    first_body =
      ~s({"operations":[{"operation_id":"ordered-1","type":"mystery","metadata":{"a":1,"b":2},"items":[1,2]}]})

    second_body =
      ~s({"operations":[{"items":[1,2],"metadata":{"b":2,"a":1},"type":"mystery","operation_id":"ordered-1"}]})

    first_result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", first_body)
      |> json_response(200)
      |> Map.fetch!("results")
      |> hd()

    second_result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", second_body)
      |> json_response(200)
      |> Map.fetch!("results")
      |> hd()

    assert second_result == first_result

    changed_array_body =
      ~s({"operations":[{"operation_id":"ordered-1","type":"mystery","metadata":{"a":1,"b":2},"items":[2,1]}]})

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", changed_array_body)
           |> json_response(200)
           |> Map.fetch!("results")
           |> hd() == %{
             "operation_id" => "ordered-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    numeric_variant_body =
      ~s({"operations":[{"operation_id":"ordered-1","type":"mystery","metadata":{"a":1.0,"b":2},"items":[1,2]}]})

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", numeric_variant_body)
           |> json_response(200)
           |> Map.fetch!("results")
           |> hd() == %{
             "operation_id" => "ordered-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }
  end

  test "durable records retain first-commit order", %{conn: conn} do
    result(conn, %{
      "operation_id" => "audit-1",
      "type" => "mystery"
    })

    result(conn, %{
      "operation_id" => "audit-2",
      "type" => "mystery"
    })

    assert Repo.all(
             from operation in Operation, order_by: operation.id, select: operation.operation_id
           ) ==
             ["audit-1", "audit-2"]
  end
end
