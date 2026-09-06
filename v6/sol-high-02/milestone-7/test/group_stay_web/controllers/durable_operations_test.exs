defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  test "an exact retry returns the original applied result without consulting current state", %{
    conn: conn
  } do
    retried_payment = payment_operation("pay-once", 1_000, 1)

    operations = [
      open_operation(),
      retried_payment,
      payment_operation("later-payment", 500, 2),
      retried_payment
    ]

    %{"results" => [_, original, later, replay]} = post_batch(conn, operations)

    assert replay == original
    assert original["revision"] == 2
    assert later["revision"] == 3

    assert get_group("group-81") |> Map.take(["revision", "cash_paid_cents"]) == %{
             "revision" => 3,
             "cash_paid_cents" => 1_500
           }

    assert get_json("/api/v1/operations/pay-once", 200) == %{"data" => original}
  end

  test "a handled rejection is remembered even after domain state makes it otherwise valid", %{
    conn: conn
  } do
    missing_group_payment = payment_operation("remembered-rejection", 1_000, 1)

    %{"results" => [original_rejection, _, replay]} =
      post_batch(conn, [missing_group_payment, open_operation(), missing_group_payment])

    assert original_rejection == %{
             "operation_id" => "remembered-rejection",
             "status" => "rejected",
             "code" => "group_not_found"
           }

    assert replay == original_rejection
    assert get_group("group-81")["revision"] == 1

    corrected = Map.put(missing_group_payment, "expected_revision", 1)
    corrected = Map.put(corrected, "amount_cents", 500)

    assert post_batch(build_conn(), [corrected]) == %{
             "results" => [
               %{
                 "operation_id" => "remembered-rejection",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert get_json("/api/v1/operations/remembered-rejection", 200) == %{
             "data" => original_rejection
           }
  end

  test "a stale result replays its original revision details and a correction conflicts", %{
    conn: conn
  } do
    stale = payment_operation("stale-payment", 200, 0)

    %{"results" => [_, original]} = post_batch(conn, [open_operation(), stale])
    assert original["code"] == "stale_revision"
    assert original["expected_revision"] == 0
    assert original["actual_revision"] == 1

    assert post_batch(build_conn(), [payment_operation("advance-revision", 100, 1)])["results"]
           |> hd()
           |> Map.fetch!("revision") == 2

    %{"results" => [replay, conflict]} =
      post_batch(build_conn(), [stale, Map.put(stale, "expected_revision", 2)])

    assert replay == original
    assert conflict["code"] == "operation_id_conflict"
    assert get_group("group-81")["revision"] == 2
  end

  test "JSON object key order is irrelevant but array order remains significant", %{conn: conn} do
    first = """
    {"operations":[{"operation_id":"ordered-json","type":"open_group","occurred_on":"2026-10-03","group_id":"ordered","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-11","rate_plan":"flexible","rooms":[{"room_id":"a","nightly_rate_cents":100},{"room_id":"b","nightly_rate_cents":200}]}]}
    """

    reordered_objects = """
    {"operations":[{"rooms":[{"nightly_rate_cents":100,"room_id":"a"},{"nightly_rate_cents":200,"room_id":"b"}],"rate_plan":"flexible","departure_on":"2026-12-11","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"ordered","occurred_on":"2026-10-03","type":"open_group","operation_id":"ordered-json"}]}
    """

    reversed_array = """
    {"operations":[{"operation_id":"ordered-json","type":"open_group","occurred_on":"2026-10-03","group_id":"ordered","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-11","rate_plan":"flexible","rooms":[{"room_id":"b","nightly_rate_cents":200},{"room_id":"a","nightly_rate_cents":100}]}]}
    """

    original = post_raw_json(conn, first) |> get_in(["results", Access.at(0)])
    replay = post_raw_json(build_conn(), reordered_objects) |> get_in(["results", Access.at(0)])
    conflict = post_raw_json(build_conn(), reversed_array) |> get_in(["results", Access.at(0)])

    assert replay == original
    assert conflict["code"] == "operation_id_conflict"
    assert Enum.map(get_group("ordered")["rooms"], & &1["room_id"]) == ["a", "b"]
  end

  test "durable records retain submissions, types, outcomes, and first-commit order", %{
    conn: conn
  } do
    invalid = %{"operation_id" => "audit-invalid", "type" => "unknown", "nested" => %{"b" => 2}}
    opened = open_operation(%{"operation_id" => "audit-open"})

    %{"results" => [invalid_result, open_result]} = post_batch(conn, [invalid, opened])

    records = Repo.all(from(record in OperationRecord, order_by: record.id))
    assert Enum.map(records, & &1.operation_id) == ["audit-invalid", "audit-open"]
    assert Enum.map(records, & &1.operation_type) == ["unknown", "open_group"]
    assert Enum.map(records, & &1.submission) === [invalid, opened]
    assert Enum.map(records, & &1.result) == [invalid_result, open_result]

    post_batch(build_conn(), [invalid])
    assert Repo.aggregate(OperationRecord, :count) == 2
  end

  test "the operation read endpoint returns the documented missing error", %{conn: conn} do
    assert conn |> get("/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp post_raw_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
    |> json_response(200)
  end

  defp get_json(path, status) do
    build_conn() |> get(path) |> json_response(status)
  end

  defp get_group(group_id) do
    get_json("/api/v1/groups/#{group_id}", 200)["data"]
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-group",
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

  defp payment_operation(operation_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end
end
