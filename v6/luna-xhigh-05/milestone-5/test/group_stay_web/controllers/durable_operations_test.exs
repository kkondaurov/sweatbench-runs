defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{OperationRecord, Repo}

  test "retries return the original result without applying the operation again", %{conn: conn} do
    operation = open_operation("durable-group")

    assert %{"results" => [opened]} = post_batch(conn, [operation])

    post_batch(conn, [cash_payment("durable-payment", "durable-group", 100)])

    assert %{"results" => [retried]} = post_batch(conn, [operation])
    assert retried == opened

    assert json_response(get(conn, "/api/v1/groups/durable-group"), 200)["data"]["revision"] == 2

    assert json_response(get(conn, "/api/v1/operations/#{operation["operation_id"]}"), 200) ==
             %{"data" => opened}
  end

  test "remembers rejected results even after the domain state changes", %{conn: conn} do
    rejected_operation = cash_payment("missing-group-payment", "created-later", 1)

    assert %{"results" => [rejected]} = post_batch(conn, [rejected_operation])
    assert rejected["code"] == "group_not_found"

    post_batch(conn, [open_operation("created-later")])

    assert %{"results" => [retried]} = post_batch(conn, [rejected_operation])
    assert retried == rejected

    assert json_response(get(conn, "/api/v1/operations/missing-group-payment"), 200) ==
             %{"data" => rejected}
  end

  test "remembers stale revision details from the first attempt", %{conn: conn} do
    post_batch(conn, [open_operation("stale-durable")])

    stale_operation = %{
      "operation_id" => "stale-durable-operation",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "stale-durable",
      "new_arrival_on" => "not-a-date",
      "expected_revision" => 0
    }

    assert %{"results" => [stale]} = post_batch(conn, [stale_operation])
    assert stale["actual_revision"] == 1

    post_batch(conn, [cash_payment("stale-durable-payment", "stale-durable", 1)])

    assert %{"results" => [retried]} = post_batch(conn, [stale_operation])
    assert retried == stale
    assert retried["actual_revision"] == 1
  end

  test "ignores object key order but treats array order as part of the payload", %{conn: conn} do
    operation = open_operation("payload-equivalence")

    assert %{"results" => [opened]} = post_batch(conn, [operation])

    reordered_keys =
      operation
      |> Map.delete("rooms")
      |> Map.merge(%{
        "rooms" => [
          %{"nightly_rate_cents" => 15_000, "room_id" => "room-a"},
          %{"nightly_rate_cents" => 17_500, "room_id" => "room-b"}
        ],
        "property_id" => "ams-canal"
      })

    assert %{"results" => [same_payload]} = post_batch(conn, [reordered_keys])
    assert same_payload == opened

    reordered_rooms = %{
      operation
      | "rooms" => [
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
        ]
    }

    assert %{"results" => [conflict]} = post_batch(conn, [reordered_rooms])

    assert conflict == %{
             "operation_id" => "op-open-payload-equivalence",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert %{"results" => [original]} = post_batch(conn, [operation])
    assert original == opened
  end

  test "checks conflicts before validating the retry payload", %{conn: conn} do
    operation = open_operation("conflict-precedence")
    assert %{"results" => [_opened]} = post_batch(conn, [operation])

    conflicting_operation = %{
      "operation_id" => operation["operation_id"],
      "type" => "open_group",
      "group_id" => "conflict-precedence",
      "occurred_on" => "not-a-date",
      "rooms" => []
    }

    assert %{"results" => [conflict]} = post_batch(conn, [conflicting_operation])

    assert conflict == %{
             "operation_id" => operation["operation_id"],
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }
  end

  test "durably remembers an invalid operation with an identifiable id", %{conn: conn} do
    operation = %{
      "operation_id" => "invalid-but-durable",
      "type" => "record_cash_payment",
      "group_id" => "",
      "amount_cents" => 10
    }

    assert %{"results" => [rejected]} = post_batch(conn, [operation])

    assert rejected == %{
             "operation_id" => "invalid-but-durable",
             "status" => "rejected",
             "code" => "invalid_operation"
           }

    assert %{"results" => [retried]} = post_batch(conn, [operation])
    assert retried == rejected
  end

  test "stores applied and rejected submissions in first-commit order", %{conn: conn} do
    first = open_operation("audit-first")
    second = cash_payment("audit-second", "audit-first", 1)
    third = cash_payment("audit-third", "missing-audit-group", 1)

    post_batch(conn, [first, second, third])

    records = Repo.all(from record in OperationRecord, order_by: record.id)

    assert Enum.map(records, & &1.operation_id) == [
             "op-open-audit-first",
             "audit-second",
             "audit-third"
           ]

    assert Enum.map(records, & &1.operation_type) == [
             "open_group",
             "record_cash_payment",
             "record_cash_payment"
           ]

    assert Jason.decode!(Enum.at(records, 0).payload_json) == first
    assert Jason.decode!(Enum.at(records, 1).payload_json) == second
    assert Jason.decode!(Enum.at(records, 2).payload_json) == third
  end

  test "returns the usual not-found response for an unknown operation", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/operations/does-not-exist"), 404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(group_id) do
    %{
      "operation_id" => "op-open-#{group_id}",
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

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
