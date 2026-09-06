defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{OperationRecord, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-durable",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "durable-group",
        "guest_id" => "durable-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "replays the original result without consulting the current group", %{conn: conn} do
    first_result =
      submit(conn, [open_operation()])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert get_in(
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "durable-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2027-01-01",
                   "group_id" => "durable-group",
                   "amount_cents" => 100
                 }
               ]),
               200
             ),
             ["results", Access.at(0), "revision"]
           ) == 2

    assert json_response(submit(conn, [open_operation()]), 200) == %{
             "results" => [first_result]
           }

    assert json_response(get(conn, "/api/v1/operations/open-durable"), 200) == %{
             "data" => first_result
           }
  end

  test "treats object key order as insignificant but arrays and values as significant", %{
    conn: conn
  } do
    first_body =
      ~s({"operations":[{"type":"open_group","operation_id":"ordered-open","occurred_on":"2027-01-01","group_id":"ordered-group","guest_id":"ordered-guest","property_id":"ams-canal","arrival_on":"2027-03-01","departure_on":"2027-03-02","rate_plan":"flexible","rooms":[{"nightly_rate_cents":10000,"room_id":"room-a"}]}]})

    reordered_body =
      ~s({"operations":[{"rooms":[{"room_id":"room-a","nightly_rate_cents":10000}],"rate_plan":"flexible","departure_on":"2027-03-02","arrival_on":"2027-03-01","property_id":"ams-canal","guest_id":"ordered-guest","group_id":"ordered-group","occurred_on":"2027-01-01","operation_id":"ordered-open","type":"open_group"}]})

    first =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", first_body)
      |> json_response(200)

    second =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", reordered_body)
      |> json_response(200)

    assert second == first

    different_array = Map.put(open_operation(%{"operation_id" => "ordered-open"}), "rooms", [])

    assert get_in(json_response(submit(conn, [different_array]), 200), ["results", Access.at(0)]) ==
             %{
               "operation_id" => "ordered-open",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
  end

  test "replays stale-revision details and conflicts with a corrected payload", %{conn: conn} do
    assert json_response(submit(conn, [open_operation()]), 200)

    assert get_in(
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "revision-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2027-01-01",
                   "group_id" => "durable-group",
                   "amount_cents" => 100
                 }
               ]),
               200
             ),
             ["results", Access.at(0), "revision"]
           ) == 2

    stale_operation = %{
      "operation_id" => "stale-durable",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => "durable-group",
      "amount_cents" => 0,
      "expected_revision" => 1
    }

    stale_result =
      submit(conn, [stale_operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert stale_result == %{
             "operation_id" => "stale-durable",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "durable-group",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert get_in(
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "revision-payment-2",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2027-01-01",
                   "group_id" => "durable-group",
                   "amount_cents" => 100
                 }
               ]),
               200
             ),
             ["results", Access.at(0), "revision"]
           ) == 3

    assert json_response(submit(conn, [stale_operation]), 200) == %{
             "results" => [stale_result]
           }

    corrected = Map.put(stale_operation, "expected_revision", 2)

    assert get_in(json_response(submit(conn, [corrected]), 200), ["results", Access.at(0)]) == %{
             "operation_id" => "stale-durable",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }
  end

  test "remembers handled rejections and does not replace records on conflicts", %{conn: conn} do
    rejected_operation = %{
      "operation_id" => "missing-group-operation",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => "missing-group",
      "amount_cents" => 100
    }

    first_result =
      submit(conn, [rejected_operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first_result == %{
             "operation_id" => "missing-group-operation",
             "status" => "rejected",
             "code" => "group_not_found"
           }

    assert json_response(
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-missing-group",
                 "group_id" => "missing-group"
               })
             ]),
             200
           )

    assert json_response(submit(conn, [rejected_operation]), 200) == %{
             "results" => [first_result]
           }

    conflict = Map.put(rejected_operation, "amount_cents", 200)

    assert get_in(json_response(submit(conn, [conflict]), 200), ["results", Access.at(0)]) == %{
             "operation_id" => "missing-group-operation",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert Repo.aggregate(OperationRecord, :count, :id) == 2
  end

  test "stores the operation type, complete payload, and durable insertion order", %{conn: conn} do
    applied = open_operation(%{"operation_id" => "audit-applied"})

    rejected = %{
      "operation_id" => "audit-rejected",
      "type" => "unsupported_operation",
      "value" => %{"b" => 2, "a" => [1, 2]}
    }

    assert json_response(submit(conn, [applied, rejected]), 200)

    records = Repo.all(from record in OperationRecord, order_by: [asc: record.id])

    assert Enum.map(records, & &1.operation_id) == ["audit-applied", "audit-rejected"]
    assert Enum.at(records, 0).operation_type == "open_group"
    assert Enum.at(records, 1).operation_type == "unsupported_operation"
    assert Jason.decode!(Enum.at(records, 1).payload_json) == rejected
  end

  test "returns the usual not-found error for unknown operation identifiers", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/operations/unknown"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end
end
