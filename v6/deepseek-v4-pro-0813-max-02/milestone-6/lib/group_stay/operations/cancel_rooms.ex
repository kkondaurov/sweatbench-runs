defmodule GroupStay.Operations.CancelRooms do
  @moduledoc """
  Settles selected rooms of an active group from a `cancel_rooms` operation.

  Every supplied room id must identify a distinct, active room of the group.
  The selected rooms' allocated cash and credit are settled with the same
  date, policy, refund method, bonus, and restoration rules as a full
  cancellation. One hotel-credit bonus is computed over the selected rooms'
  combined cash. The unpaid deposit of those rooms stops being due; other
  rooms and their allocations are unchanged. When no active room remains,
  the group becomes cancelled.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.FinanceReporting
  alias GroupStay.Operations
  alias GroupStay.Operations.Settlement
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on, :room_ids]

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
           apply_to_group(operation, group, fields.room_ids, occurred_on)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_to_group(operation, group, room_ids, occurred_on) do
    with :ok <- Operations.guard_group(operation, group),
         {:ok, refund_method} <- Settlement.validate_refund_method(operation["refund_method"]),
         :ok <- Settlement.assert_method_available(group, refund_method, occurred_on),
         {:ok, rooms} <- resolve_rooms(group, room_ids) do
      settle_and_finish(operation, group, rooms, occurred_on, refund_method)
    else
      {:rejected, result} ->
        result

      :refund_method_not_available ->
        Operations.rejected(operation, "refund_method_not_available")

      :invalid_rooms ->
        Operations.rejected(operation, "invalid_rooms")
    end
  end

  defp resolve_rooms(_group, room_ids) when not is_list(room_ids), do: :invalid_rooms

  defp resolve_rooms(_group, []), do: :invalid_rooms

  defp resolve_rooms(group, room_ids) do
    if room_ids == Enum.uniq(room_ids) do
      rooms =
        Enum.map(room_ids, fn room_id ->
          Repo.get_by(Room, room_id: room_id, group_id: group.id)
        end)

      if Enum.all?(rooms, &(&1 != nil and &1.status == "active")) do
        {:ok, Enum.map(rooms, & &1)}
      else
        :invalid_rooms
      end
    else
      :invalid_rooms
    end
  end

  defp settle_and_finish(operation, group, rooms, occurred_on, refund_method) do
    ordered =
      Repo.all(
        from r in Room,
          where: r.group_id == ^group.id,
          order_by: [asc: r.position]
      )

    settled =
      Enum.filter(ordered, fn room -> Enum.any?(rooms, &(&1.id == room.id)) end)
      |> Enum.map(& &1.room_id)

    settlement =
      RoomAccounting.settle(group, rooms, occurred_on, refund_method, operation["operation_id"])

    FinanceReporting.record_settlement(operation, group.property_id, settlement)

    RoomAccounting.sync_group_columns(group.id)

    group = Repo.get!(Group, group.id)
    revision = group.revision + 1

    status =
      if Repo.exists?(from r in Room, where: r.group_id == ^group.id and r.status == "active") do
        "active"
      else
        "cancelled"
      end

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [status: status, revision: revision]
      )

    Operations.applied(operation,
      group_id: group.group_id,
      cancelled_room_ids: settled,
      refunded_cents: settlement.refunded_cents,
      retained_cents: settlement.retained_cents,
      credit_issued_cents: settlement.credit_issued_cents,
      revision: revision
    )
  end
end
