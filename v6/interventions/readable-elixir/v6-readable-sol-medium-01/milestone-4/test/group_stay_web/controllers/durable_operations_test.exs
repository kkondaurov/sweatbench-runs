defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Deposits.PartnerOperation
  alias GroupStay.Repo

  describe "durable partner operation receipts" do
    test "replays an applied result exactly without consulting current group state", %{conn: conn} do
      opening = open_operation()
      payment = payment_operation("pay-1", 1_000, 1)

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: [opening, payment, opening]})

      assert %{"results" => [original, paid, replay]} = json_response(conn, 200)
      assert original == replay
      assert original["revision"] == 1
      assert paid["revision"] == 2

      conn = get(recycle(conn), ~p"/api/v1/groups/group-1")
      assert get_in(json_response(conn, 200), ["data", "revision"]) == 2
    end

    test "remembers handled rejections even after domain state makes them valid", %{conn: conn} do
      payment = payment_operation("early-payment", 1_000, 1)

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [payment, open_operation(), payment]
        })

      assert %{"results" => [first, _, retry]} = json_response(conn, 200)
      assert first == retry
      assert first["code"] == "group_not_found"

      conn = get(recycle(conn), ~p"/api/v1/groups/group-1")
      assert get_in(json_response(conn, 200), ["data", "deposit_paid_cents"]) == 0
    end

    test "rejects identifier reuse with a different JSON payload and retains the original", %{
      conn: conn
    } do
      original = open_operation()
      changed = put_in(original, ["rooms", Access.at(0), "nightly_rate_cents"], 20_000)

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: [original, changed]})

      assert %{"results" => [applied, conflict]} = json_response(conn, 200)

      assert conflict == %{
               "operation_id" => "open-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      conn = get(recycle(conn), ~p"/api/v1/operations/open-1")
      assert json_response(conn, 200) == %{"data" => applied}
    end

    test "stores exact stale-revision details for retries", %{conn: conn} do
      stale = payment_operation("stale", 1_000, 0)
      later_payment = payment_operation("pay-1", 1_000, 1)

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [open_operation(), stale, later_payment, stale]
        })

      assert %{"results" => [_, first, _, retry]} = json_response(conn, 200)
      assert first == retry
      assert first["actual_revision"] == 1
      assert first["expected_revision"] == 0
    end

    test "retains complete submissions, their types, and first-commit order", %{conn: conn} do
      opening = open_operation()
      rejected = payment_operation("too-much", 100_000, 1)

      conn = post(conn, ~p"/api/v1/partner-batches", %{operations: [opening, rejected, opening]})
      assert response(conn, 200)

      receipts = Repo.all(from operation in PartnerOperation, order_by: operation.id)
      assert Enum.map(receipts, & &1.operation_id) == ["open-1", "too-much"]
      assert Enum.map(receipts, & &1.operation_type) == ["open_group", "record_cash_payment"]
      assert Enum.map(receipts, & &1.submission) == [opening, rejected]
      assert Enum.at(receipts, 1).result["code"] == "payment_exceeds_outstanding"
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the documented missing-operation error", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/operations/unknown")

      assert json_response(conn, 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
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

  defp payment_operation(operation_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end
end
