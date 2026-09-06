defmodule GroupStay.OperationsTest do
  @moduledoc """
  Data-level tests for the durable operation records: retained submission
  content and type, commit order, and the unique index that backs the
  at-most-once guarantee for concurrent retries.
  """

  use GroupStay.DataCase, async: false

  import Ecto.Query

  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  defp open_group_operation(operation_id, group_id) do
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
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    }
  end

  defp payment_operation(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => 1_000
    }
  end

  test "retain type, complete submission, and commit order" do
    open = open_group_operation("audit-1", "group-audit")
    payment = payment_operation("audit-2", "group-audit")

    rejected = %{
      "operation_id" => "audit-3",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-missing",
      "amount_cents" => 1_000,
      "expected_revision" => 7
    }

    assert {:ok, results} =
             GroupStay.Groups.process_batch(%{"operations" => [open, payment, rejected]})

    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected"]

    records = Repo.all(from o in Operation, order_by: o.id)

    assert Enum.map(records, & &1.operation_id) == ["audit-1", "audit-2", "audit-3"]

    assert Enum.map(records, & &1.type) == [
             "open_group",
             "record_cash_payment",
             "record_cash_payment"
           ]

    # The complete submitted content is retained, rejected operations included.
    [first, second, third] = records
    assert Jason.decode!(first.payload) == open
    assert Jason.decode!(second.payload) == payment
    assert Jason.decode!(third.payload) == rejected

    assert Jason.decode!(first.result)["status"] == "applied"
    assert Jason.decode!(third.result)["code"] == "group_not_found"
  end

  test "the unique index on operation_id backs at-most-once effects" do
    Repo.insert!(%Operation{
      operation_id: "audit-dup",
      payload: "{}",
      result: ~s({"status":"applied"})
    })

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Operation{
        operation_id: "audit-dup",
        payload: "{}",
        result: ~s({"status":"applied"})
      })
    end
  end
end
