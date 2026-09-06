defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.{OperationRecord, Operations, Repo}

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp open_operation(operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 15000}]
      },
      overrides
    )
  end

  test "replays the original applied result without applying it again", %{conn: conn} do
    assert post_batch(conn, [open_operation("op-open")]) |> json_response(200)

    payment = %{
      operation_id: "op-payment",
      type: "record_cash_payment",
      occurred_on: "2026-10-04",
      group_id: "group-81",
      amount_cents: 1000
    }

    first_payment =
      post_batch(conn, [payment])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert first_payment == %{
             "operation_id" => "op-payment",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 1000,
             "outstanding_deposit_cents" => 8000,
             "revision" => 2
           }

    assert post_batch(conn, [Map.put(payment, :operation_id, "op-second-payment")])
           |> json_response(200)

    assert post_batch(conn, [payment])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == first_payment

    assert get(build_conn(), "/api/v1/operations/op-payment")
           |> json_response(200) == %{"data" => first_payment}

    assert get(build_conn(), "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 3

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_held_cents"]) == 2000
  end

  test "remembers handled rejections and ignores object key order", %{conn: conn} do
    first =
      post_json(
        conn,
        ~s({"operations":[{"operation_id":"op-missing","type":"record_cash_payment","occurred_on":"2026-10-04","group_id":"missing","amount_cents":1}]})
      )
      |> json_response(200)

    expected = %{
      "operation_id" => "op-missing",
      "status" => "rejected",
      "code" => "group_not_found",
      "group_id" => "missing"
    }

    assert first == %{"results" => [expected]}

    retry =
      post_json(
        conn,
        ~s({"operations":[{"amount_cents":1,"group_id":"missing","occurred_on":"2026-10-04","type":"record_cash_payment","operation_id":"op-missing"}]})
      )
      |> json_response(200)

    assert retry == first

    assert post_batch(conn, [open_operation("op-open-missing", %{group_id: "missing"})])
           |> json_response(200)

    assert post_json(
             conn,
             ~s({"operations":[{"amount_cents":1,"group_id":"missing","occurred_on":"2026-10-04","type":"record_cash_payment","operation_id":"op-missing"}]})
           )
           |> json_response(200) == first

    assert get(build_conn(), "/api/v1/groups/missing")
           |> json_response(200)
           |> get_in(["data", "deposit_paid_cents"]) == 0

    assert get(build_conn(), "/api/v1/operations/op-missing") |> json_response(200) == %{
             "data" => expected
           }

    record = Repo.get_by!(OperationRecord, operation_id: "op-missing")
    assert record.type == "record_cash_payment"

    assert record.payload == %{
             "operation_id" => "op-missing",
             "type" => "record_cash_payment",
             "occurred_on" => "2026-10-04",
             "group_id" => "missing",
             "amount_cents" => 1
           }

    assert record.result == expected
  end

  test "returns a conflict for a different payload and preserves the original record", %{
    conn: conn
  } do
    assert post_batch(conn, [open_operation("op-open")]) |> json_response(200)

    payment = %{
      operation_id: "op-payment",
      type: "record_cash_payment",
      occurred_on: "2026-10-04",
      group_id: "group-81",
      amount_cents: 1000
    }

    original =
      post_batch(conn, [payment]) |> json_response(200) |> get_in(["results", Access.at(0)])

    conflict =
      post_batch(conn, [Map.put(payment, :amount_cents, 2000)])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert conflict == %{
             "operation_id" => "op-payment",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert get(build_conn(), "/api/v1/operations/op-payment")
           |> json_response(200) == %{"data" => original}

    assert get(build_conn(), "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "deposit_paid_cents"]) == 1000

    assert Repo.aggregate(OperationRecord, :count, :id) == 2
  end

  test "returns operation_not_found for an unknown operation", %{conn: conn} do
    response = get(conn, "/api/v1/operations/unknown")

    assert response.status == 404
    assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "concurrent identical submissions have one domain effect", %{conn: conn} do
    assert post_batch(conn, [open_operation("op-open")]) |> json_response(200)

    payment = %{
      "operation_id" => "op-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 1000
    }

    results =
      1..4
      |> Task.async_stream(fn _ -> Operations.process_batch([payment]) end, timeout: 5_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [
             [
               %{
                 "operation_id" => "op-payment",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 1000,
                 "outstanding_deposit_cents" => 8000,
                 "revision" => 2
               }
             ]
           ]

    assert get(build_conn(), "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_held_cents"]) == 1000
  end
end
