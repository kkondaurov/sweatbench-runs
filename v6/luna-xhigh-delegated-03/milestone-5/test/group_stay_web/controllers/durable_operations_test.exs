defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.{OperationRecord, Repo}
  import Ecto.Query

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
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 16_000}
        ]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "replays an applied operation exactly without applying its effects twice", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
             post_batch(conn, [open_operation()]) |> json_response(200)

    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 1_000,
      "expected_revision" => 1
    }

    first_conn = post_batch(build_conn(), [payment])
    first_body = first_conn.resp_body
    first_response = json_response(first_conn, 200)

    retry_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/partner-batches",
        ~s({"operations":[{"expected_revision":1,"amount_cents":1000,"group_id":"group-81","occurred_on":"2026-10-04","type":"record_cash_payment","operation_id":"pay-1"}]})
      )

    assert retry_conn.resp_body == first_body
    retry_response = json_response(retry_conn, 200)
    assert retry_response == first_response

    assert json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]
           |> Map.take(["revision", "deposit_paid_cents", "cash_paid_cents"]) == %{
             "revision" => 2,
             "deposit_paid_cents" => 1_000,
             "cash_paid_cents" => 1_000
           }

    assert json_response(get(conn, "/api/v1/operations/pay-1"), 200) == %{
             "data" => first_response["results"] |> hd()
           }
  end

  test "remembers rejected results and returns conflicts without replacing the record", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [open_operation()]) |> json_response(200)

    stale = %{
      "operation_id" => "stale-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => -1,
      "expected_revision" => 99
    }

    stale_result = post_batch(build_conn(), [stale]) |> json_response(200)

    assert stale_result == %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ]
           }

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1,
                 "expected_revision" => 1
               }
             ])
             |> json_response(200)

    assert post_batch(build_conn(), [stale]) |> json_response(200) == stale_result

    corrected = Map.put(stale, "expected_revision", 2)

    assert post_batch(build_conn(), [corrected]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]["revision"] == 2
  end

  test "treats array order as significant while retaining audit content and commit order", %{
    conn: conn
  } do
    first = open_operation(%{"operation_id" => "array-op"})

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [first]) |> json_response(200)

    reordered =
      Map.put(first, "rooms", [
        %{"room_id" => "room-b", "nightly_rate_cents" => 16_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
      ])

    assert post_batch(conn, [reordered]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "array-op",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    records = Repo.all(from record in OperationRecord, order_by: [asc: record.id])
    assert Enum.map(records, & &1.operation_id) == ["array-op"]
    assert hd(records).type == "open_group"
    assert Jason.decode!(hd(records).payload) == first

    assert json_response(get(conn, "/api/v1/operations/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end
end
