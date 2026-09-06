defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.{Operation, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-group",
        "type" => "open_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  test "returns the remembered result for an equivalent retry without reapplying it", %{
    conn: conn
  } do
    open = open_operation()

    assert %{"results" => [%{"revision" => 1} = original_result]} = post_batch(conn, [open])

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "pay-group",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-02-02",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000
               }
             ])

    reordered_json =
      ~s({"operations":[{"rooms":[{"nightly_rate_cents":10000,"room_id":"room-a"}],"rate_plan":"flexible","departure_on":"2027-03-16","arrival_on":"2027-03-15","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2027-02-01","type":"open_group","operation_id":"open-group"}]})

    assert %{"results" => [^original_result]} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", reordered_json)
             |> json_response(200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             get(conn, "/api/v1/groups/group-81") |> json_response(200)

    assert %{"data" => ^original_result} =
             get(conn, "/api/v1/operations/open-group") |> json_response(200)
  end

  test "remembers handled rejections and reports conflicts without replacing records", %{
    conn: conn
  } do
    missing_group_operation = %{
      "operation_id" => "cancel-missing",
      "type" => "cancel_group",
      "occurred_on" => "2027-02-01",
      "group_id" => "missing"
    }

    assert %{"results" => [%{"code" => "group_not_found"} = rejection]} =
             post_batch(conn, [missing_group_operation])

    assert %{"results" => [^rejection]} = post_batch(conn, [missing_group_operation])

    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open_operation()])

    assert %{"results" => [^rejection]} = post_batch(conn, [missing_group_operation])

    payment = %{
      "operation_id" => "pay-group",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-02-02",
      "group_id" => "group-81",
      "amount_cents" => 1_000
    }

    assert %{"results" => [%{"amount_cents" => 1_000} = payment_result]} =
             post_batch(conn, [payment])

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             post_batch(conn, [%{payment | "amount_cents" => 2_000}])

    assert %{"data" => ^payment_result} =
             get(conn, "/api/v1/operations/pay-group") |> json_response(200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             get(conn, "/api/v1/groups/group-81") |> json_response(200)
  end

  test "retains operation type, complete payload, result, and commit order", %{conn: conn} do
    first = open_operation(%{"operation_id" => "first-operation"})
    second = open_operation(%{"operation_id" => "second-operation", "group_id" => "group-82"})

    post_batch(conn, [first, second])

    records = Repo.all(Operation) |> Enum.sort_by(& &1.commit_order)

    assert [%Operation{} = first_record, %Operation{} = second_record] = records
    assert first_record.commit_order < second_record.commit_order
    assert first_record.operation_id == "first-operation"
    assert first_record.type == "open_group"
    assert Jason.decode!(first_record.payload_json) == first
    assert Jason.decode!(first_record.result_json)["group_id"] == "group-81"
    assert second_record.operation_id == "second-operation"
  end

  test "returns the documented not-found response for unknown operations", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(conn, "/api/v1/operations/unknown") |> json_response(404)
  end

  test "remembers invalid operations with unknown JSON types as handled rejections", %{conn: conn} do
    invalid_operation = %{"operation_id" => "invalid-type", "type" => 123}

    assert %{"results" => [%{"code" => "invalid_operation"} = result]} =
             post_batch(conn, [invalid_operation])

    assert %{"data" => ^result} =
             get(conn, "/api/v1/operations/invalid-type") |> json_response(200)
  end
end
