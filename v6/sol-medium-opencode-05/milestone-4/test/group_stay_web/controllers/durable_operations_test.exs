defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{OperationRecord, Repo}

  test "replays an applied result verbatim without consulting changed group state", %{conn: conn} do
    open = open_operation()
    payment = payment_operation("pay-1", 1_000, 1)

    assert %{"results" => [opened, paid]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => [open, payment]})
             |> json_response(200)

    assert opened["revision"] == 1
    assert paid["revision"] == 2

    assert %{"results" => [%{"revision" => 3}]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{
               "operations" => [payment_operation("pay-2", 1_000, 2)]
             })
             |> json_response(200)

    assert %{"results" => [replayed]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [payment]})
             |> json_response(200)

    assert replayed == paid

    assert %{"data" => stored} =
             build_conn() |> get("/api/v1/operations/pay-1") |> json_response(200)

    assert stored == paid

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 2_000}} =
             build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
  end

  test "remembers rejections and their original revision details", %{conn: conn} do
    stale = payment_operation("stale-1", 100, 9)

    assert %{"results" => [_, original]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => [open_operation(), stale]})
             |> json_response(200)

    assert original == %{
             "operation_id" => "stale-1",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 9,
             "actual_revision" => 1
           }

    assert %{"results" => [%{"revision" => 2}]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{
               "operations" => [payment_operation("pay-later", 100, 1)]
             })
             |> json_response(200)

    assert %{"results" => [replayed]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [stale]})
             |> json_response(200)

    assert replayed == original

    corrected = %{stale | "expected_revision" => 2}

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [corrected]})
             |> json_response(200)
  end

  test "rejects identifier conflicts without replacing the audit record", %{conn: conn} do
    original = open_operation()

    assert %{"results" => [%{"status" => "applied"}]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => [original]})
             |> json_response(200)

    conflicting = put_in(original, ["rooms", Access.at(0), "nightly_rate_cents"], 20_000)

    assert %{"results" => [conflict]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [conflicting]})
             |> json_response(200)

    assert conflict == %{
             "operation_id" => "open-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert %{"results" => [replayed]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [original]})
             |> json_response(200)

    assert replayed["status"] == "applied"
    assert Repo.aggregate(OperationRecord, :count) == 1
  end

  test "keeps complete submissions and first-commit order", %{conn: conn} do
    rejected = %{
      "operation_id" => "unknown-1",
      "type" => "future_operation",
      "nested" => %{"b" => 2, "a" => 1},
      "items" => [2, 1]
    }

    assert %{"results" => [%{"code" => "invalid_operation"}, %{"status" => "applied"}]} =
             conn
             |> post("/api/v1/partner-batches", %{
               "operations" => [rejected, open_operation()]
             })
             |> json_response(200)

    records = Repo.all(from r in OperationRecord, order_by: r.id)

    assert Enum.map(records, & &1.operation_id) == ["unknown-1", "open-1"]
    assert hd(records).operation_type == "future_operation"
    assert hd(records).submission == rejected

    equivalent = %{
      "items" => [2, 1],
      "nested" => %{"a" => 1, "b" => 2},
      "type" => "future_operation",
      "operation_id" => "unknown-1"
    }

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [equivalent]})
             |> json_response(200)
  end

  test "array order is significant and missing operations return 404", %{conn: conn} do
    operation = %{
      "operation_id" => "unknown-1",
      "type" => "future_operation",
      "items" => [1, 2]
    }

    assert %{"results" => [_]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => [operation]})
             |> json_response(200)

    reordered = %{operation | "items" => [2, 1]}

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => [reordered]})
             |> json_response(200)

    assert json_response(get(build_conn(), "/api/v1/operations/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp open_operation do
    %{
      "operation_id" => "open-1",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    }
  end

  defp payment_operation(operation_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end
end
