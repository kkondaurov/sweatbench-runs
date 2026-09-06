defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Operations
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  describe "idempotent replay" do
    test "a retry with the same payload returns the exact original result", %{conn: conn} do
      original = open_group_fixture(conn)

      %{"results" => [retry]} = submit_batch(conn, [valid_open_operation()])

      assert retry == original
    end

    test "a retry does not read or change current domain state", %{conn: conn} do
      open_group_fixture(conn)

      %{"results" => [first]} = submit_batch(conn, [payment_op()])
      assert first["status"] == "applied"
      assert first["revision"] == 2

      %{"results" => [retry]} = submit_batch(conn, [payment_op()])
      assert retry == first

      data = group_data(conn, "group-81")
      assert data["deposit_paid_cents"] == 5000
      assert data["revision"] == 2

      assert ledger_data(conn)["cash_held_cents"] == 5000
    end

    test "object key order is irrelevant for equivalence", %{conn: conn} do
      conn = put_req_header(conn, "content-type", "application/json")

      original_body = ~s({"operations":[#{open_group_json()}]})
      reordered_body = ~s({"operations":[#{reordered_open_group_json()}]})

      %{"results" => [first]} =
        conn |> post("/api/v1/partner-batches", original_body) |> json_response(200)

      assert first["status"] == "applied"

      %{"results" => [retry]} =
        conn |> post("/api/v1/partner-batches", reordered_body) |> json_response(200)

      assert retry == first
      assert group_data(conn, "group-81")["revision"] == 1
    end

    test "array order remains significant", %{conn: conn} do
      open_group_fixture(conn)

      swapped_rooms = %{
        valid_open_operation()
        | "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
          ]
      }

      %{"results" => [result]} = submit_batch(conn, [swapped_rooms])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"
    end

    test "changed values remain significant", %{conn: conn} do
      open_group_fixture(conn)

      %{"results" => [first]} = submit_batch(conn, [payment_op()])
      assert first["status"] == "applied"

      %{"results" => [result]} = submit_batch(conn, [payment_op(%{"amount_cents" => 4000})])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"
    end

    test "a replayed operation does not stop later operations", %{conn: conn} do
      open_group_fixture(conn)

      %{"results" => [replay, applied]} =
        submit_batch(conn, [valid_open_operation(), payment_op()])

      assert replay["status"] == "applied"
      assert replay["revision"] == 1
      assert applied["status"] == "applied"
      assert applied["revision"] == 2
    end

    test "the same operation twice in one batch applies once", %{conn: conn} do
      open_group_fixture(conn)

      %{"results" => [first, second]} = submit_batch(conn, [payment_op(), payment_op()])

      assert first["status"] == "applied"
      assert second == first
      assert group_data(conn, "group-81")["deposit_paid_cents"] == 5000
      assert group_data(conn, "group-81")["revision"] == 2
    end
  end

  describe "remembered rejections" do
    test "a retry returns the original rejection even when later operations make it valid", %{
      conn: conn
    } do
      open_group_fixture(conn)

      credit_op = %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81",
        "amount_cents" => 1000
      }

      %{"results" => [rejected]} = submit_batch(conn, [credit_op])
      assert rejected["status"] == "rejected"
      assert rejected["code"] == "insufficient_credit"

      # Later operations give the guest enough credit to fund the group.
      open_group_fixture(conn, %{"operation_id" => "op-fund", "group_id" => "group-fund"})
      pay_group(conn, "group-fund", 5000)
      cancel_group(conn, "group-fund", "2026-11-26", %{"refund_method" => "hotel_credit"})
      assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500

      %{"results" => [retry]} = submit_batch(conn, [credit_op])

      assert retry == rejected

      data = group_data(conn, "group-81")
      assert data["revision"] == 1
      assert data["credit_paid_cents"] == 0
    end

    test "a stale_revision rejection is replayed with the revisions observed originally", %{
      conn: conn
    } do
      open_group_fixture(conn)

      stale = payment_op() |> Map.put("expected_revision", 5)
      %{"results" => [rejected]} = submit_batch(conn, [stale])
      assert rejected["code"] == "stale_revision"
      assert rejected["expected_revision"] == 5
      assert rejected["actual_revision"] == 1

      # Advance the group's revision; the replay must not observe it.
      submit_batch(conn, [payment_op(%{"operation_id" => "op-other"})])
      assert group_data(conn, "group-81")["revision"] == 2

      %{"results" => [retry]} = submit_batch(conn, [stale])
      assert retry == rejected
    end

    test "an applied result keeps its original revision after the group moves on", %{conn: conn} do
      open_group_fixture(conn)

      %{"results" => [first]} = submit_batch(conn, [payment_op()])
      assert first["revision"] == 2

      submit_batch(conn, [payment_op(%{"operation_id" => "op-more", "amount_cents" => 1000})])
      assert group_data(conn, "group-81")["revision"] == 3

      %{"results" => [retry]} = submit_batch(conn, [payment_op()])
      assert retry == first
    end
  end

  describe "operation_id_conflict" do
    test "a different payload under the same identifier is rejected", %{conn: conn} do
      open_group_fixture(conn)

      different = %{valid_open_operation() | "group_id" => "group-99"}

      %{"results" => [result]} = submit_batch(conn, [different])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-99"
             }
    end

    test "a conflict does not replace the original record or change domain state", %{conn: conn} do
      original = open_group_fixture(conn)

      submit_batch(conn, [%{valid_open_operation() | "group_id" => "group-99"}])

      # The original result is still replayed and served.
      %{"results" => [retry]} = submit_batch(conn, [valid_open_operation()])
      assert retry == original

      conn = get(conn, ~p"/api/v1/operations/op-1001")
      assert json_response(conn, 200) == %{"data" => original}

      # The conflicting payload was not applied and no extra record was kept.
      conn = get(conn, ~p"/api/v1/groups/group-99")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}

      assert Repo.one(from r in OperationRecord, select: count(r.id)) == 1
    end

    test "correcting expected_revision under the same identifier is a conflict", %{conn: conn} do
      open_group_fixture(conn)

      stale = payment_op() |> Map.put("expected_revision", 5)
      %{"results" => [rejected]} = submit_batch(conn, [stale])
      assert rejected["code"] == "stale_revision"

      corrected = payment_op() |> Map.put("expected_revision", 1)
      %{"results" => [result]} = submit_batch(conn, [corrected])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"

      data = group_data(conn, "group-81")
      assert data["revision"] == 1
      assert data["deposit_paid_cents"] == 0
    end

    test "a conflict is not itself remembered", %{conn: conn} do
      open_group_fixture(conn)
      conflicting = %{valid_open_operation() | "group_id" => "group-99"}

      %{"results" => [first]} = submit_batch(conn, [conflicting])
      %{"results" => [second]} = submit_batch(conn, [conflicting])

      assert first["code"] == "operation_id_conflict"
      assert second["code"] == "operation_id_conflict"

      assert Repo.one(from r in OperationRecord, select: count(r.id)) == 1
    end
  end

  describe "invalid operations" do
    test "an invalid operation with an identifier is remembered like other rejections", %{
      conn: conn
    } do
      operation = %{valid_open_operation() | "type" => "extend_group"}

      %{"results" => [rejected]} = submit_batch(conn, [operation])
      assert rejected["code"] == "invalid_operation"

      %{"results" => [retry]} = submit_batch(conn, [operation])
      assert retry == rejected

      # A corrected payload under the same identifier is a conflict.
      %{"results" => [conflict]} = submit_batch(conn, [valid_open_operation()])
      assert conflict["code"] == "operation_id_conflict"

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "an operation without an identifier is rejected without a record", %{conn: conn} do
      operation = Map.delete(valid_open_operation(), "operation_id")

      %{"results" => [first]} = submit_batch(conn, [operation])
      %{"results" => [second]} = submit_batch(conn, [operation])

      assert first["code"] == "invalid_operation"
      assert first["operation_id"] == nil
      assert second == first

      assert Repo.one(from r in OperationRecord, select: count(r.id)) == 0
    end
  end

  describe "unexpected faults" do
    test "an unexpected exception aborts the operation and is not remembered", %{conn: conn} do
      operation = Map.put(valid_open_operation(), "unencodable", :not_json)

      assert_raise ArgumentError, fn -> Operations.apply_operation(operation) end

      conn = get(conn, ~p"/api/v1/operations/op-1001")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}

      # The gateway can retry the batch once the fault is gone.
      %{"results" => [result]} = submit_batch(conn, [valid_open_operation()])
      assert result["status"] == "applied"
    end
  end

  describe "audit retention" do
    test "retains type and complete submitted content in first-commit order", %{conn: conn} do
      open = valid_open_operation()

      invalid = %{
        "operation_id" => "op-bad",
        "type" => "extend_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      }

      rejected_payment = payment_op(%{"amount_cents" => 999_999})

      submit_batch(conn, [open, invalid, rejected_payment])

      records = Repo.all(from r in OperationRecord, order_by: [asc: r.id])

      assert Enum.map(records, & &1.operation_id) == ["op-1001", "op-bad", "op-pay"]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "extend_group",
               "record_cash_payment"
             ]

      [open_record, invalid_record, payment_record] = records
      assert Jason.decode!(open_record.payload) == open
      assert Jason.decode!(invalid_record.payload) == invalid
      assert Jason.decode!(payment_record.payload) == rejected_payment

      assert Jason.decode!(open_record.result)["status"] == "applied"
      assert Jason.decode!(invalid_record.result)["code"] == "invalid_operation"
      assert Jason.decode!(payment_record.result)["code"] == "payment_exceeds_outstanding"
    end

    test "later conflicting submissions do not change the retained record", %{conn: conn} do
      open = valid_open_operation()
      submit_batch(conn, [open])
      submit_batch(conn, [%{open | "group_id" => "group-99"}])

      record = Repo.get_by!(OperationRecord, operation_id: "op-1001")
      assert Jason.decode!(record.payload) == open
      assert Jason.decode!(record.result)["status"] == "applied"
    end
  end

  defp open_group_json do
    ~s({"operation_id":"op-1001","type":"open_group","occurred_on":"2026-10-03",) <>
      ~s("group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal",) <>
      ~s("arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible",) <>
      ~s("rooms":[{"room_id":"room-a","nightly_rate_cents":15000},) <>
      ~s({"room_id":"room-b","nightly_rate_cents":17500}]})
  end

  defp reordered_open_group_json do
    ~s({"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},) <>
      ~s({"nightly_rate_cents":17500,"room_id":"room-b"}],) <>
      ~s("rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10",) <>
      ~s("property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81",) <>
      ~s("occurred_on":"2026-10-03","type":"open_group","operation_id":"op-1001"})
  end
end
