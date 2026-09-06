defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.Repo

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp post_raw_body(body) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", body)

    {Jason.decode!(conn.resp_body), conn.status}
  end

  defp get_operation(operation_id) do
    api_get(build_conn(), "/api/v1/operations/#{operation_id}")
  end

  defp get_group(group_id) do
    {body, 200} = api_get(build_conn(), "/api/v1/groups/#{group_id}")
    body["data"]
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  describe "idempotent retries" do
    test "an equivalent retry returns the exact original result without touching domain state" do
      {_, 200} = post_ops([open_group_op()])
      {body, 200} = post_ops([cash_payment_op()])
      applied = result(body)

      group_before = get_group("group-81")

      {retry_body, 200} =
        post_raw_body(
          ~s({"operations":[{"group_id":"group-81","amount_cents":5000,"type":"record_cash_payment","occurred_on":"2026-10-20","operation_id":"op-2001"}]})
        )

      assert result(retry_body) == applied

      group_after = get_group("group-81")
      assert group_after == group_before
      assert group_after["revision"] == 2
      assert group_after["deposit_paid_cents"] == 5_000

      {stored, 200} = get_operation("op-2001")
      assert stored == %{"data" => applied}
    end

    test "a stored rejection is returned on retry even once the domain would allow it" do
      {_, 200} = post_ops([open_group_op()])

      {body, 200} =
        post_ops([cash_payment_op(%{"operation_id" => "op-2001", "amount_cents" => 99_999})])

      rejected = result(body)
      assert rejected["code"] == "payment_exceeds_outstanding"

      {_, 200} =
        post_ops([cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 5_000})])

      {retry_body, 200} =
        post_ops([cash_payment_op(%{"operation_id" => "op-2001", "amount_cents" => 99_999})])

      assert result(retry_body) == rejected
      assert get_group("group-81")["deposit_paid_cents"] == 5_000

      record = Repo.get_by(OperationRecord, operation_id: "op-2001")
      refute is_nil(record)
      assert record.type == "record_cash_payment"
      assert Jason.decode!(record.result) == rejected

      {stored, 200} = get_operation("op-2001")
      assert stored == %{"data" => rejected}
    end

    test "two identical operations in one batch apply the effect once" do
      payment = cash_payment_op()

      {body, 200} = post_ops([open_group_op(), payment, payment])

      assert result(body, 1)["status"] == "applied"
      assert result(body, 2) == result(body, 1)

      group = get_group("group-81")
      assert group["deposit_paid_cents"] == 5_000
      assert group["revision"] == 2
    end

    test "operations without an operation id are not remembered" do
      {body, 200} =
        post_ops([
          %{
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-20",
            "group_id" => "group-81",
            "amount_cents" => 5_000
          }
        ])

      assert result(body) == %{"status" => "rejected", "code" => "invalid_operation"}
      assert Repo.all(OperationRecord) == []
    end

    test "an operation with an unusable type is rejected and still remembered" do
      op = %{"operation_id" => "op-typed", "type" => 42, "group_id" => "group-81"}

      {body, 200} = post_ops([op])

      assert result(body) == %{
               "operation_id" => "op-typed",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      record = Repo.get_by(OperationRecord, operation_id: "op-typed")
      assert is_nil(record.type)

      {stored, 200} = get_operation("op-typed")
      assert stored == %{"data" => result(body)}
    end
  end

  describe "operation_id_conflict" do
    test "a different payload with a used identifier is rejected and never replaces the record" do
      {_, 200} = post_ops([open_group_op()])
      {body, 200} = post_ops([cash_payment_op()])
      applied = result(body)

      {conflict_body, 200} =
        post_ops([cash_payment_op(%{"operation_id" => "op-2001", "amount_cents" => 100})])

      assert result(conflict_body) == %{
               "operation_id" => "op-2001",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert get_group("group-81")["deposit_paid_cents"] == 5_000

      {stored, 200} = get_operation("op-2001")
      assert stored == %{"data" => applied}

      {retry_body, 200} = post_ops([cash_payment_op()])
      assert result(retry_body) == applied
    end

    test "an operation_id_conflict rejection does not stop the rest of the batch" do
      {_, 200} = post_ops([open_group_op()])
      {_, 200} = post_ops([cash_payment_op()])

      {body, 200} =
        post_ops([
          cash_payment_op(%{"operation_id" => "op-2001", "amount_cents" => 100}),
          cash_payment_op(%{
            "operation_id" => "op-2003",
            "amount_cents" => 2_000,
            "expected_revision" => 2
          })
        ])

      assert result(body, 0)["code"] == "operation_id_conflict"

      assert result(body, 1) == %{
               "operation_id" => "op-2003",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 12_500,
               "revision" => 3
             }
    end

    test "array order is significant for payload equivalence" do
      open =
        open_group_op(%{
          "operation_id" => "op-arr",
          "group_id" => "group-arr",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        })

      {_, 200} = post_ops([open])

      swapped = %{
        open
        | "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
      }

      {body, 200} = post_ops([swapped])
      assert result(body)["code"] == "operation_id_conflict"
    end
  end

  describe "stale revision retries" do
    test "an exact retry returns the stored actual_revision without consulting current state" do
      {_, 200} = post_ops([open_group_op()])

      stale = cash_payment_op(%{"expected_revision" => 2, "operation_id" => "op-2001"})
      {body, 200} = post_ops([stale])
      rejection = result(body)

      assert rejection == %{
               "operation_id" => "op-2001",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 1
             }

      {_, 200} =
        post_ops([cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 1_000})])

      assert get_group("group-81")["revision"] == 2

      {retry_body, 200} = post_ops([stale])
      assert result(retry_body) == rejection

      corrected = cash_payment_op(%{"expected_revision" => 1, "operation_id" => "op-2001"})

      {conflict_body, 200} = post_ops([corrected])
      assert result(conflict_body)["code"] == "operation_id_conflict"

      {stored, 200} = get_operation("op-2001")
      assert stored == %{"data" => rejection}
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result" do
      {_, 200} = post_ops([open_group_op(), cash_payment_op()])
      {body, 200} = get_operation("op-2001")

      assert body == %{
               "data" => %{
                 "operation_id" => "op-2001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             }
    end

    test "exposes stored rejections, including invalid operations" do
      op = %{"operation_id" => "op-bad", "type" => "close_group", "group_id" => "group-81"}

      {body, 200} = post_ops([op])
      rejection = result(body)

      assert rejection == %{
               "operation_id" => "op-bad",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      {retry_body, 200} = post_ops([op])
      assert result(retry_body) == rejection

      {stored, 200} = get_operation("op-bad")
      assert stored == %{"data" => rejection}
    end

    test "returns operation_not_found for unknown operation ids" do
      {body, 404} = get_operation("op-never")
      assert body == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "durable audit records" do
    test "records retain the type and complete submitted content in first-commit order" do
      {_, 200} = post_ops([open_group_op(), cash_payment_op()])

      records = Repo.all(OperationRecord) |> Enum.sort_by(& &1.id)

      assert Enum.map(records, & &1.type) == ["open_group", "record_cash_payment"]
      assert Enum.at(records, 0).id < Enum.at(records, 1).id

      open_payload = Jason.decode!(Enum.at(records, 0).payload)
      payment_payload = Jason.decode!(Enum.at(records, 1).payload)

      assert open_payload == %{
               "operation_id" => "op-1001",
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
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }

      assert payment_payload["operation_id"] == "op-2001"
      assert payment_payload["amount_cents"] == 5_000

      {stored, 200} = get_operation("op-1001")
      assert stored["data"]["deposit_due_cents"] == 19_500
    end

    test "operation identifiers are unique at the database level" do
      {_, 200} = post_ops([open_group_op()])

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%OperationRecord{
          operation_id: "op-1001",
          type: "open_group",
          payload: "{}",
          result: "{}"
        })
      end
    end
  end

  describe "unexpected server faults" do
    test "a fault rolls the current operation back, is not remembered, and aborts the batch" do
      crash =
        open_group_op(%{
          "operation_id" => "op-crash",
          "group_id" => "group-crash",
          "rooms" => [
            %{"room_id" => "room-big", "nightly_rate_cents" => 10_000_000_000_000_000_000}
          ]
        })

      late =
        open_group_op(%{
          "operation_id" => "op-late",
          "group_id" => "group-late"
        })

      assert_error_sent 500, fn ->
        post_ops([open_group_op(), crash, late])
      end

      assert get_group("group-81")["revision"] == 1
      refute is_nil(Repo.get_by(OperationRecord, operation_id: "op-1001"))
      assert is_nil(Repo.get_by(OperationRecord, operation_id: "op-crash"))
      assert is_nil(Repo.get_by(OperationRecord, operation_id: "op-late"))

      {body, 404} = api_get(build_conn(), "/api/v1/groups/group-crash")
      assert body == %{"error" => %{"code" => "group_not_found"}}

      {body, 404} = api_get(build_conn(), "/api/v1/groups/group-late")
      assert body == %{"error" => %{"code" => "group_not_found"}}

      {body, 404} = get_operation("op-crash")
      assert body == %{"error" => %{"code" => "operation_not_found"}}
    end
  end
end
