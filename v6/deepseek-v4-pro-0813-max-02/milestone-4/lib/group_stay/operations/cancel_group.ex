defmodule GroupStay.Operations.CancelGroup do
  @moduledoc """
  Cancels a group from a `cancel_group` operation.

  Cancellation refundability follows the group's policy version, which is
  fixed when the group is opened. A refundable cancellation refunds cash (or,
  when `refund_method: "hotel_credit"` is requested, converts it into a credit
  lot worth 110% of the cash) and restores any applied hotel credit to its
  original lots. Non-refundable cancellations retain cash and consume applied
  credit. The unpaid deposit stops being due.

  The remaining active rooms are settled; their allocations leave the rooms
  and the group becomes cancelled.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations
  alias GroupStay.Operations.Settlement
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         true <- is_binary(fields.group_id),
         {:ok, occurred_on} <- Operations.parse_date(fields.occurred_on) do
      process(operation, fields, occurred_on)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp process(operation, fields, occurred_on) do
    case Repo.transaction(fn ->
           group = Repo.get_by(Group, group_id: fields.group_id)
           apply_to_group(operation, group, occurred_on)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_to_group(operation, group, occurred_on) do
    with :ok <- Operations.guard_group(operation, group),
         {:ok, refund_method} <- Settlement.validate_refund_method(operation["refund_method"]),
         :ok <- Settlement.assert_method_available(group, refund_method, occurred_on) do
      rooms = active_rooms(group)
      settle_and_finish(operation, group, rooms, occurred_on, refund_method)
    else
      {:rejected, result} ->
        result

      :refund_method_not_available ->
        Operations.rejected(operation, "refund_method_not_available")
    end
  end

  defp settle_and_finish(operation, group, rooms, occurred_on, refund_method) do
    settlement =
      RoomAccounting.settle(group, rooms, occurred_on, refund_method, operation["operation_id"])

    RoomAccounting.sync_group_columns(group.id)

    group = Repo.get!(Group, group.id)
    revision = group.revision + 1

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [status: "cancelled", revision: revision]
      )

    Operations.applied(operation,
      group_id: group.group_id,
      refunded_cents: settlement.refunded_cents,
      retained_cents: settlement.retained_cents,
      credit_issued_cents: settlement.credit_issued_cents,
      revision: revision
    )
  end

  defp active_rooms(group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: [asc: r.position]
    )
  end
end
