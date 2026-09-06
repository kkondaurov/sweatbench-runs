defmodule GroupStay.RoomAccounting do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.{CashRoomAllocation, Group, Room}
  alias GroupStay.Repo

  @active "active"
  @held "held"

  def allocate_cash!(%Group{} = group, payment_operation_id, amount_cents)
      when is_binary(payment_operation_id) and is_integer(amount_cents) and amount_cents > 0 do
    allocate_to_rooms!(group, amount_cents, fn room, amount ->
      %CashRoomAllocation{}
      |> Ecto.Changeset.change(%{
        group_id: group.id,
        group_room_id: room.id,
        payment_operation_id: payment_operation_id,
        amount_cents: amount,
        disposition: @held
      })
      |> Repo.insert!()

      increment_room!(room.id, :cash_paid_cents, amount)
    end)
  end

  def held_cash_for_payment(payment_operation_id) when is_binary(payment_operation_id) do
    Repo.one(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: allocation.group_room_id == room.id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition == ^@held and room.status == ^@active,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  def reduce_payment!(payment_operation_id, amount_cents)
      when is_binary(payment_operation_id) and is_integer(amount_cents) and amount_cents > 0 do
    take_held_cash!(payment_operation_id, amount_cents, "reduced")
  end

  def charge_back_payment!(payment_operation_id) when is_binary(payment_operation_id) do
    allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              allocation.disposition not in ["reduced", "charged_back"],
          order_by: [asc: allocation.id]
        )
      )

    Enum.each(allocations, fn allocation ->
      if allocation.disposition == @held and allocation.group_room_id do
        increment_room!(allocation.group_room_id, :cash_paid_cents, -allocation.amount_cents)
      end

      allocation
      |> Ecto.Changeset.change(disposition: "charged_back")
      |> Repo.update!()
    end)

    Enum.sum(Enum.map(allocations, & &1.amount_cents))
  end

  def settle_rooms_cash!(rooms, disposition, credit_lot_id \\ nil)
      when disposition in ["refunded", "retained", "converted"] do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: allocation.group_room_id == room.id,
          where: allocation.group_room_id in ^room_ids and allocation.disposition == ^@held,
          order_by: [asc: room.position, asc: allocation.id]
        )
      )

    Enum.each(allocations, fn allocation ->
      allocation
      |> Ecto.Changeset.change(%{disposition: disposition, credit_lot_id: credit_lot_id})
      |> Repo.update!()

      increment_room!(allocation.group_room_id, :cash_paid_cents, -allocation.amount_cents)
    end)

    {Enum.sum(Enum.map(allocations, & &1.amount_cents)), allocations}
  end

  def held_cash_for_rooms(rooms) when is_list(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.one(
      from(allocation in CashRoomAllocation,
        where: allocation.group_room_id in ^room_ids and allocation.disposition == ^@held,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    dispositions =
      Repo.all(
        from(allocation in CashRoomAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id,
          group_by: allocation.disposition,
          select: {allocation.disposition, sum(allocation.amount_cents)}
        )
      )
      |> Map.new()

    %{
      held_cents: Map.get(dispositions, @held, 0),
      refunded_cents: Map.get(dispositions, "refunded", 0),
      retained_cents: Map.get(dispositions, "retained", 0),
      converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      reduced_cents: Map.get(dispositions, "reduced", 0),
      charged_back_cents: Map.get(dispositions, "charged_back", 0)
    }
  end

  def ledger_totals do
    dispositions =
      Repo.all(
        from(allocation in CashRoomAllocation,
          group_by: allocation.disposition,
          select: {allocation.disposition, sum(allocation.amount_cents)}
        )
      )
      |> Map.new()

    %{
      cash_held_cents: Map.get(dispositions, @held, 0),
      cash_refunded_cents: Map.get(dispositions, "refunded", 0),
      cash_retained_cents: Map.get(dispositions, "retained", 0),
      cash_converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      cash_reduced_cents: Map.get(dispositions, "reduced", 0),
      cash_charged_back_cents: Map.get(dispositions, "charged_back", 0)
    }
  end

  defp take_held_cash!(payment_operation_id, amount_cents, disposition) do
    allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: allocation.group_room_id == room.id,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              allocation.disposition == ^@held and room.status == ^@active,
          order_by: [desc: room.position, desc: allocation.id],
          preload: [group_room: room]
        )
      )

    {remaining, removed} =
      Enum.reduce(allocations, {amount_cents, 0}, fn allocation, {remaining, removed} ->
        to_remove = min(remaining, allocation.amount_cents)

        if to_remove == 0 do
          {remaining, removed}
        else
          if to_remove == allocation.amount_cents do
            allocation
            |> Ecto.Changeset.change(disposition: disposition)
            |> Repo.update!()
          else
            allocation
            |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - to_remove)
            |> Repo.update!()

            %CashRoomAllocation{}
            |> Ecto.Changeset.change(%{
              group_id: allocation.group_id,
              group_room_id: allocation.group_room_id,
              payment_operation_id: allocation.payment_operation_id,
              credit_lot_id: allocation.credit_lot_id,
              amount_cents: to_remove,
              disposition: disposition
            })
            |> Repo.insert!()
          end

          increment_room!(allocation.group_room_id, :cash_paid_cents, -to_remove)
          {remaining - to_remove, removed + to_remove}
        end
      end)

    if remaining == 0, do: removed, else: Repo.rollback(:held_cash_changed)
  end

  defp allocate_to_rooms!(group, amount_cents, allocate) do
    rooms = active_rooms(group.id)

    {remaining, _} =
      Enum.reduce(rooms, {amount_cents, 0}, fn room, {remaining, allocated} ->
        room_outstanding = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(max(room_outstanding, 0), remaining)

        if amount > 0, do: allocate.(room, amount)
        {remaining - amount, allocated + amount}
      end)

    if remaining == 0, do: :ok, else: Repo.rollback(:room_capacity_changed)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from(room in Room,
        where: room.group_id == ^group_id and room.status == ^@active,
        order_by: [asc: room.position]
      )
    )
  end

  defp increment_room!(room_id, field, amount_cents) do
    Repo.update_all(from(room in Room, where: room.id == ^room_id), inc: [{field, amount_cents}])
  end
end
