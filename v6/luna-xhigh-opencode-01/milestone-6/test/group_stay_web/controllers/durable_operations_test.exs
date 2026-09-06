defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Operation, Repo}
  import Ecto.Query

  test "replays an applied result without changing the current group", %{conn: conn} do
    operation = open_group("group-81", "open-81")

    assert %{"results" => [first_result]} = submit(conn, [operation])
    assert %{"results" => [^first_result]} = submit(conn, [operation])

    assert %{"data" => %{"revision" => 1}} = get_group(conn, "group-81")
    assert %{"data" => ^first_result} = get_operation(conn, "open-81")
    assert Repo.aggregate(Operation, :count, :id) == 1
  end

  test "replays rejected results even after the operation would become valid", %{conn: conn} do
    payment = payment("pay-missing", "group-81", 1)

    assert %{
             "results" => [%{"status" => "rejected", "code" => "group_not_found"} = first_result]
           } = submit(conn, [payment])

    assert %{"results" => [open_result]} = submit(conn, [open_group("group-81", "open-81")])
    assert open_result["revision"] == 1

    assert %{"results" => [^first_result]} = submit(conn, [payment])

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get_group(conn, "group-81")
  end

  test "rejects a changed payload without replacing the original record", %{conn: conn} do
    original = open_group("group-81", "open-81")
    changed = Map.put(original, "group_id", "group-82")

    assert %{"results" => [original_result]} = submit(conn, [original])

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-81",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = submit(conn, [changed])

    assert %{"data" => ^original_result} = get_operation(conn, "open-81")
    assert %{"error" => %{"code" => "group_not_found"}} = get_group(conn, "group-82", 404)
  end

  test "checks payload equality independent of object key order but not array order", %{
    conn: conn
  } do
    original = open_group("group-81", "open-81")

    reordered = %{
      "rooms" => [
        %{"nightly_rate_cents" => 15_000, "room_id" => "room-a"},
        %{"nightly_rate_cents" => 17_500, "room_id" => "room-b"}
      ],
      "rate_plan" => "flexible",
      "departure_on" => "2026-12-13",
      "arrival_on" => "2026-12-10",
      "property_id" => "ams-canal",
      "guest_id" => "guest-22",
      "group_id" => "group-81",
      "occurred_on" => "2026-10-03",
      "type" => "open_group",
      "operation_id" => "open-81"
    }

    array_reordered =
      Map.put(reordered, "rooms", Enum.reverse(reordered["rooms"]))

    assert %{"results" => [%{"status" => "applied"}]} = submit(conn, [original])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [reordered])

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [array_reordered])
  end

  test "remembers stale revision details and exposes durable records", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_group("group-81", "open-81")])

    stale = payment("pay-stale", "group-81", 1) |> Map.put("expected_revision", 0)

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               } = stale_result
             ]
           } = submit(conn, [stale])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [payment("pay-valid", "group-81", 1)])

    assert %{"results" => [^stale_result]} = submit(conn, [stale])

    records = Repo.all(from operation in Operation, order_by: operation.id)
    assert Enum.map(records, & &1.operation_id) == ["open-81", "pay-stale", "pay-valid"]

    assert Enum.map(records, & &1.operation_type) == [
             "open_group",
             "record_cash_payment",
             "record_cash_payment"
           ]

    assert Jason.decode!(Enum.at(records, 1).payload) == stale
  end

  test "returns the usual not-found response for an unknown operation", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             get_operation(conn, "does-not-exist", 404)
  end

  test "serializes concurrent retries and applies the operation once", %{conn: conn} do
    operation = open_group("group-81", "open-81")

    results =
      1..8
      |> Task.async_stream(
        fn _ -> GroupStay.process_batch(%{"operations" => [operation]}) end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, [result]}} -> result end)

    assert Enum.uniq(results) |> length() == 1
    assert %{"data" => %{"revision" => 1}} = get_group(conn, "group-81")
    assert Repo.aggregate(Operation, :count, :id) == 1
  end

  defp open_group(group_id, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_group(conn, group_id, status \\ 200) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(status)
  end

  defp get_operation(conn, operation_id, status \\ 200) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(status)
  end
end
