defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Operations.PartnerOperation
  alias GroupStay.Repo

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp submit(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{operations: operations})

  test "replays an applied result without observing later state", %{conn: conn} do
    open = open_operation()

    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 500,
      "expected_revision" => 1
    }

    later = %{payment | "operation_id" => "pay-2", "expected_revision" => 2}
    conn = submit(conn, [open, payment, later, payment])

    assert %{"results" => [opened, first, second, replay]} = json_response(conn, 200)
    assert opened["revision"] == 1
    assert first == replay
    assert first["revision"] == 2
    assert second["revision"] == 3

    group = get(recycle(conn), ~p"/api/v1/groups/group-1") |> json_response(200)
    assert group["data"]["cash_paid_cents"] == 1_000
    assert group["data"]["revision"] == 3
  end

  test "remembers rejections and exact stale revision details", %{conn: conn} do
    stale = %{
      "operation_id" => "stale-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 100,
      "expected_revision" => 9
    }

    payment = %{stale | "operation_id" => "pay-1", "expected_revision" => 1}
    conn = submit(conn, [open_operation(), stale, payment, stale])

    assert %{"results" => [_, first_stale, paid, replay]} = json_response(conn, 200)
    assert first_stale == replay
    assert first_stale["actual_revision"] == 1
    assert paid["revision"] == 2
  end

  test "does not reconsider a rejection after domain state changes", %{conn: conn} do
    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 100
    }

    conn = submit(conn, [payment, open_operation(), payment])
    assert %{"results" => [first, _, replay]} = json_response(conn, 200)
    assert first == replay
    assert replay["code"] == "group_not_found"

    group = get(recycle(conn), ~p"/api/v1/groups/group-1") |> json_response(200)
    assert group["data"]["cash_paid_cents"] == 0
    assert group["data"]["revision"] == 1
  end

  test "treats a corrected expected revision as a conflicting payload", %{conn: conn} do
    stale = %{
      "operation_id" => "stale-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 100,
      "expected_revision" => 9
    }

    corrected = %{stale | "expected_revision" => 1}
    conn = submit(conn, [open_operation(), stale, corrected])
    assert %{"results" => [_, rejected, conflict]} = json_response(conn, 200)
    assert rejected["code"] == "stale_revision"
    assert conflict["code"] == "operation_id_conflict"

    group = get(recycle(conn), ~p"/api/v1/groups/group-1") |> json_response(200)
    assert group["data"]["revision"] == 1
  end

  test "rejects changed payloads and preserves the original record", %{conn: conn} do
    original = open_operation()
    changed = put_in(original, ["rooms", Access.at(0), "nightly_rate_cents"], 20_000)
    conn = submit(conn, [original, changed])

    assert %{"results" => [applied, conflict]} = json_response(conn, 200)
    assert applied["status"] == "applied"

    assert conflict == %{
             "operation_id" => "open-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    stored = get(recycle(conn), ~p"/api/v1/operations/open-1") |> json_response(200)
    assert stored == %{"data" => applied}
  end

  test "treats object key order as irrelevant and array order as significant", %{conn: conn} do
    original = open_operation()
    reordered_object = original |> Enum.reverse() |> Map.new()

    reversed_rooms =
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "group-2",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 100},
          %{"room_id" => "b", "nightly_rate_cents" => 200}
        ]
      })

    conn =
      submit(conn, [
        original,
        reordered_object,
        reversed_rooms,
        update_in(reversed_rooms["rooms"], &Enum.reverse/1)
      ])

    assert %{"results" => [first, replay, _, conflict]} = json_response(conn, 200)
    assert first == replay
    assert conflict["code"] == "operation_id_conflict"
  end

  test "retains complete submissions, types, and first-commit order", %{conn: conn} do
    rejected = %{
      "operation_id" => "unknown-1",
      "type" => "unknown",
      "extra" => %{"nested" => [1, 2, 3]}
    }

    conn = submit(conn, [rejected, open_operation()])

    assert %{"results" => [%{"status" => "rejected"}, %{"status" => "applied"}]} =
             json_response(conn, 200)

    records = Repo.all(from operation in PartnerOperation, order_by: operation.id)
    assert Enum.map(records, & &1.operation_id) == ["unknown-1", "open-1"]
    assert hd(records).operation_type == "unknown"
    assert hd(records).submission == rejected
  end

  test "reads rejected operations and reports missing operations", %{conn: conn} do
    rejected = %{"operation_id" => "bad-1", "type" => "unknown"}
    conn = submit(conn, [rejected])
    result = get_in(json_response(conn, 200), ["results", Access.at(0)])

    conn = get(recycle(conn), ~p"/api/v1/operations/bad-1")
    assert json_response(conn, 200) == %{"data" => result}

    conn = get(recycle(conn), ~p"/api/v1/operations/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end
end
