defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  test "replays an applied result without consulting current group state", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open("replay-group")])

    payment = payment("replayed-payment", "replay-group", 100, 1)

    assert %{
             "results" => [
               %{
                 "operation_id" => "replayed-payment",
                 "status" => "applied",
                 "amount_cents" => 100,
                 "revision" => 2
               }
             ]
           } = post_batch(conn, [payment])

    assert %{"results" => [replayed]} = post_batch(conn, [payment])
    assert replayed["revision"] == 2
    assert replayed["outstanding_deposit_cents"] == 19_400

    assert %{"results" => [%{"revision" => 3}]} =
             post_batch(conn, [payment("next-payment", "replay-group", 100, 2)])

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 200}} =
             json_response(get(conn, "/api/v1/groups/replay-group"), 200)

    assert %{"data" => stored} =
             json_response(get(conn, "/api/v1/operations/replayed-payment"), 200)

    assert stored == replayed

    assert ["open-replay-group", "replayed-payment", "next-payment"] ==
             Repo.all(from record in Record, order_by: [asc: record.id])
             |> Enum.map(& &1.operation_id)
  end

  test "remembers handled rejections and returns the original rejection on retry", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open("rejected-group")])

    rejected = payment("remembered-rejection", "rejected-group", 20_000, 1)

    assert %{
             "results" => [
               %{
                 "operation_id" => "remembered-rejection",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               }
             ]
           } = post_batch(conn, [rejected])

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [payment("valid-payment", "rejected-group", 100, 1)])

    assert %{"results" => [retried]} = post_batch(conn, [rejected])

    assert retried == %{
             "operation_id" => "remembered-rejection",
             "status" => "rejected",
             "code" => "payment_exceeds_outstanding"
           }

    assert %{"data" => stored} =
             json_response(get(conn, "/api/v1/operations/remembered-rejection"), 200)

    assert stored == retried

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
             json_response(get(conn, "/api/v1/groups/rejected-group"), 200)
  end

  test "rejects a different payload as a conflict without replacing the original record", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [open("conflict-group")])

    original = payment("same-operation", "conflict-group", 100, 1)
    changed = Map.put(original, "amount_cents", 50)

    assert %{"results" => [%{"revision" => 2}]} = post_batch(conn, [original])

    assert %{"results" => [conflict]} = post_batch(conn, [changed])

    assert conflict == %{
             "operation_id" => "same-operation",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert %{"data" => original_result} =
             json_response(get(conn, "/api/v1/operations/same-operation"), 200)

    assert original_result["status"] == "applied"
    assert original_result["amount_cents"] == 100

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
             json_response(get(conn, "/api/v1/groups/conflict-group"), 200)
  end

  test "treats object key order as equivalent but array order as a changed payload", %{conn: conn} do
    original = open("payload-group")

    assert %{"results" => [%{"revision" => 1}]} = post_batch(conn, [original])

    equivalent = %{
      "rooms" =>
        Enum.map(
          original["rooms"],
          &%{"nightly_rate_cents" => &1["nightly_rate_cents"], "room_id" => &1["room_id"]}
        ),
      "rate_plan" => original["rate_plan"],
      "departure_on" => original["departure_on"],
      "arrival_on" => original["arrival_on"],
      "property_id" => original["property_id"],
      "guest_id" => original["guest_id"],
      "group_id" => original["group_id"],
      "occurred_on" => original["occurred_on"],
      "type" => original["type"],
      "operation_id" => original["operation_id"]
    }

    assert %{"results" => [%{"revision" => 1, "status" => "applied"}]} =
             post_batch(conn, [equivalent])

    changed = Map.put(original, "rooms", Enum.reverse(original["rooms"]))

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             post_batch(conn, [changed])

    records = Repo.all(from record in Record, order_by: [asc: record.id])
    assert Enum.map(records, & &1.operation_id) == ["open-payload-group"]
    assert hd(records).type == "open_group"
    assert Jason.decode!(hd(records).payload_json) == original
  end

  test "returns operation_not_found for an unknown operation", %{conn: conn} do
    assert %{"error" => %{"code" => "operation_not_found"}} =
             json_response(get(conn, "/api/v1/operations/missing-operation"), 404)
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
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

  defp payment(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end
end
