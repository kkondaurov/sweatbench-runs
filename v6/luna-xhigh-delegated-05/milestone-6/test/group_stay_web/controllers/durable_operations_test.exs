defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-durable",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "durable-group",
        guest_id: "durable-guest",
        property_id: "ams-canal",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-03",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 5_000},
          %{room_id: "room-b", nightly_rate_cents: 7_000}
        ]
      },
      overrides
    )
  end

  test "replays applied operations, distinguishes reordered arrays, and exposes only the result",
       %{
         conn: conn
       } do
    operation = open_operation()

    first =
      submit(conn, [operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    retry =
      submit(conn, [operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert retry == first

    conflict =
      submit(conn, [
        open_operation(%{
          group_id: "different-group",
          rooms: Enum.reverse(operation.rooms)
        })
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert conflict == %{
             "operation_id" => "open-durable",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert get(conn, "/api/v1/groups/durable-group") |> json_response(200)
    assert get(conn, "/api/v1/groups/different-group") |> json_response(404)

    assert get(conn, "/api/v1/operations/open-durable") |> json_response(200) == %{
             "data" => first
           }

    assert get(conn, "/api/v1/operations/missing-operation") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "remembers a rejection and does not reevaluate it after state changes", %{conn: conn} do
    submit(conn, [open_operation()]) |> json_response(200)

    stale_operation = %{
      operation_id: "stale-durable",
      type: "record_cash_payment",
      occurred_on: "2026-10-03",
      group_id: "durable-group",
      amount_cents: 100,
      expected_revision: 0
    }

    first_rejection =
      submit(conn, [stale_operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first_rejection == %{
             "operation_id" => "stale-durable",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "durable-group",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    submit(conn, [
      %{
        operation_id: "advance-durable",
        type: "record_cash_payment",
        occurred_on: "2026-10-03",
        group_id: "durable-group",
        amount_cents: 100
      }
    ])
    |> json_response(200)

    retry =
      submit(conn, [stale_operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert retry == first_rejection

    corrected_payload = Map.put(stale_operation, :expected_revision, 2)

    assert submit(conn, [corrected_payload])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "stale-durable",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert get(conn, "/api/v1/groups/durable-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2
  end

  test "commits handled rejections with the submitted type and complete payload", %{conn: conn} do
    operation = %{
      operation_id: "invalid-durable",
      type: "record_cash_payment",
      occurred_on: "2026-10-03",
      group_id: "missing-durable",
      amount_cents: 100,
      metadata: %{"attempt" => 1, "labels" => ["a", "b"]}
    }

    result =
      submit(conn, [operation])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["code"] == "group_not_found"

    record = Repo.get_by!(Record, operation_id: "invalid-durable")
    assert record.operation_type == "record_cash_payment"

    assert Jason.decode!(record.payload_json) == %{
             "amount_cents" => 100,
             "group_id" => "missing-durable",
             "metadata" => %{"attempt" => 1, "labels" => ["a", "b"]},
             "occurred_on" => "2026-10-03",
             "operation_id" => "invalid-durable",
             "type" => "record_cash_payment"
           }

    assert Jason.decode!(record.result_json) == result

    assert Repo.all(from record in Record, order_by: [asc: record.id])
           |> Enum.map(& &1.operation_id) == ["invalid-durable"]
  end
end
