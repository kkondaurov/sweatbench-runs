defmodule GroupStay.IdempotentOperationsTest do
  @moduledoc """
  Domain-level verification of the durable idempotency guarantee for partner
  operations (docs/requests/03-durable-operations.md).

  Results are asserted through `decode/1`, which normalizes atom- and
  string-keyed maps the way JSON encoding does.
  """
  use GroupStay.DataCase, async: false

  alias GroupStay.Groups
  alias GroupStay.Groups.{Group, OperationRecord}

  defp submit(operation) do
    Groups.apply_operation(operation)
    |> decode()
  end

  defp submit_all(operations) do
    Enum.map(Groups.apply_batch(operations), &decode/1)
  end

  defp decode(map), do: Jason.decode!(Jason.encode!(map))

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp group_by_id(group_id), do: Repo.get_by(Group, group_id: group_id)

  test "an equivalent retry returns the stored result without touching domain state" do
    op = open_op("group-replay")
    first = submit(op)

    assert submit(op) == first
    assert submit(op) == first
    assert %{"status" => "applied", "revision" => 1} = first

    assert group_by_id("group-replay").revision == 1
  end

  test "object key order is irrelevant for equivalence" do
    op = open_op("group-key-order")
    first = submit(op)

    # The same payload assembled with keys in another order must replay.
    reordered = %{
      "rooms" => op["rooms"],
      "rate_plan" => op["rate_plan"],
      "departure_on" => op["departure_on"],
      "arrival_on" => op["arrival_on"],
      "property_id" => op["property_id"],
      "guest_id" => op["guest_id"],
      "group_id" => op["group_id"],
      "occurred_on" => op["occurred_on"],
      "type" => op["type"],
      "operation_id" => op["operation_id"]
    }

    assert submit(reordered) == first
    assert group_by_id("group-key-order").revision == 1
  end

  test "array order and values remain significant" do
    op = open_op("group-array-order")
    submit(op)

    reordered_rooms = Enum.reverse(op["rooms"])

    assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
             submit(%{op | "rooms" => reordered_rooms})
  end

  test "rejected results are remembered and domain state is left unchanged" do
    payment = payment_op("reject-remembered", 100)
    assert %{"status" => "rejected", "code" => "group_not_found"} = submit(payment)

    submit(open_op("reject-remembered"))

    # A retry still receives the original rejection, and no payment was applied.
    assert %{"status" => "rejected", "code" => "group_not_found"} = submit(payment)
    group = group_by_id("reject-remembered")
    assert group.revision == 1
    assert group.cash_paid_cents == 0
  end

  test "a stored rejection does not advance a revision" do
    group_id = "reject-no-bump"
    submit(open_op(group_id))

    payment = payment_op(group_id, 0)
    assert %{"status" => "rejected", "code" => "invalid_amount"} = submit(payment)

    other = payment_op(group_id, 100)
    assert %{"status" => "applied", "revision" => 2} = submit(other)

    # The remembered rejection replays; the applied operation is untouched.
    assert %{"status" => "rejected", "code" => "invalid_amount"} = submit(payment)
    assert group_by_id(group_id).revision == 2
    assert group_by_id(group_id).cash_paid_cents == 100
  end

  test "reuse with a different payload is rejected and does not replace the original record" do
    group_id = "conflict"
    submit(open_op(group_id))

    original = payment_op(group_id, 500)
    submit(original)

    conflict = %{original | "amount_cents" => 600}

    assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
             submit(conflict)

    # The original record still answers equivalent retries.
    assert %{"status" => "applied", "amount_cents" => 500} = submit(original)
    assert Groups.get_operation(original["operation_id"])["amount_cents"] == 500
  end

  test "stale-revision details replay verbatim and differ enough to conflict when corrected" do
    group_id = "stale-replay"
    submit(open_op(group_id))
    submit(payment_op(group_id, 500))

    stale = payment_op(group_id, 100, %{"expected_revision" => 1})

    assert %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2} =
             submit(stale)

    # Move the group on; the remembered rejection must still report the
    # revision observed at the original attempt.
    submit(payment_op(group_id, 200))
    assert group_by_id(group_id).revision == 3

    assert %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2} =
             submit(stale)

    # Retrying the same identifier with the corrected revision is a conflict.
    corrected = %{stale | "expected_revision" => 3}

    assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
             submit(corrected)
  end

  test "audit retains the type and the complete submitted content" do
    op = open_op("audit")
    submit(op)

    record = Repo.get_by(OperationRecord, operation_id: op["operation_id"])
    assert record.type == "open_group"
    assert record.status == "applied"
    assert Jason.decode!(record.request) == op
    assert Jason.decode!(record.result)["group_id"] == "audit"
  end

  test "durable records preserve the order in which they were first committed" do
    first = payment_op("order-1", 100)
    second = open_op("order-2")
    third = payment_op("order-3", 25)

    submit(first)
    submit(second)
    submit(third)

    records = Repo.all(from r in OperationRecord, order_by: r.id)

    assert Enum.map(records, & &1.operation_id) ==
             [first["operation_id"], second["operation_id"], third["operation_id"]]

    assert Enum.map(records, & &1.status) == ["rejected", "applied", "rejected"]
  end

  test "same-batch duplicates replay against the earlier committed attempt" do
    op = open_op("same-batch")
    [first, second] = submit_all([op, op])

    assert %{"status" => "applied", "revision" => 1} = first
    assert %{"status" => "applied", "revision" => 1} = second
    assert group_by_id("same-batch").revision == 1
  end

  test "operations without an identifier are processed each time" do
    op = open_op("no-id") |> Map.delete("operation_id")

    assert %{"status" => "applied", "operation_id" => nil} = submit(op)

    assert %{"status" => "rejected", "code" => "group_already_exists", "operation_id" => nil} =
             submit(op)

    assert Repo.all(from r in OperationRecord, where: is_nil(r.operation_id)) == []
    refute group_by_id("no-id") == nil
  end

  test "an unexpected exception rolls back and is not remembered" do
    op =
      Map.merge(open_op("explode"), %{
        "operation_id" => "op-explode",
        "extra" => {:not, :encodable}
      })

    assert_raise Protocol.UndefinedError, fn -> Groups.apply_operation(op) end

    refute Repo.get_by(OperationRecord, operation_id: "op-explode")
    refute group_by_id("explode")
  end

  test "unexpected exceptions abort the batch and are not remembered" do
    group_id = "batch-unexpected"
    good = open_op(group_id)
    bad = Map.merge(open_op("explode"), %{"extra" => {:not, :encodable}})

    assert_raise Protocol.UndefinedError, fn ->
      Groups.apply_batch([good, bad])
    end

    # The successful earlier operation committed; the failure itself was not.
    assert group_by_id(group_id)
    refute Repo.get_by(OperationRecord, operation_id: bad["operation_id"])
  end
end
