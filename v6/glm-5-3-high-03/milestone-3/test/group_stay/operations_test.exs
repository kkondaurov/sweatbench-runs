defmodule GroupStay.OperationsTest do
  @moduledoc """
  Covers the durable idempotency record itself: what it retains of the
  submission, what outcome it remembers, and the order in which records were
  first committed.
  """

  use GroupStay.DataCase, async: false

  import Ecto.Query

  alias GroupStay.Operations
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  import GroupStay.PartnerHelpers

  test "remembers the type, the complete submission, and the result" do
    operation = open_group_operation("op-1001")

    assert [result] = Operations.run([operation])
    assert result["status"] == "applied"

    record = Repo.get_by!(OperationRecord, operation_id: "op-1001")
    assert record.type == "open_group"
    assert record.payload == operation
    assert record.result == result
  end

  test "remembers rejected operations with their submitted type" do
    operation = %{
      "operation_id" => "op-1",
      "type" => "explode_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "extra" => %{"nested" => [1, 2]}
    }

    assert [result] = Operations.run([operation])
    assert result["code"] == "invalid_operation"

    record = Repo.get_by!(OperationRecord, operation_id: "op-1")
    assert record.type == "explode_group"
    assert record.payload == operation
    assert record.result == result
  end

  test "operations submitted without a usable operation_id are not retained" do
    operation = %{"type" => "open_group", "occurred_on" => "2026-10-04"}

    assert [_result] = Operations.run([operation])
    assert Repo.aggregate(OperationRecord, :count) == 0
  end

  test "preserves the order in which records were first committed" do
    operations = [
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 5_000),
      cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-20"})
    ]

    assert Enum.map(Operations.run(operations), & &1["status"]) ==
             ["applied", "applied", "applied"]

    ids = Repo.all(from r in OperationRecord, order_by: r.id, select: r.operation_id)
    assert ids == ["op-1", "op-2", "op-3"]
  end

  test "a retry with a different payload commits no new record" do
    Operations.run([open_group_operation("op-1")])
    Operations.run([open_group_operation("op-1", %{"arrival_on" => "2026-12-11"})])

    records = Repo.all(OperationRecord)
    assert length(records) == 1
    assert hd(records).operation_id == "op-1"
  end

  test "an unexpected exception is not remembered and leaves no partial state" do
    crashing =
      open_group_operation("op-crash", %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 4_611_686_018_427_387_904}]
      })

    try do
      Operations.run([crashing])
      flunk("expected the operation to crash")
    rescue
      _ -> :ok
    end

    assert Repo.get_by(OperationRecord, operation_id: "op-crash") == nil
    assert Repo.get_by(GroupStay.Groups.Group, group_id: "group-81") == nil
  end
end
