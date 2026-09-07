defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Assigns deposit funding to rooms and maintains cash-payment dispositions.

  Funding always fills active rooms in their original order. Cash allocations
  retain their payment source so reductions, settlements, chargebacks, room
  views, payment statements, and the ledger all share one accounting truth.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CashFunding,
    Group,
    Room
  }

  @disposition_fields %{
    refunded: :refunded_cents,
    retained: :retained_cents,
    converted: :converted_to_credit_cents
  }

  @doc "Records and assigns a new cash payment."
  def fund_cash(%Group{} = group, payment_operation_id, amount_cents, funding_order) do
    funding =
      %CashFunding{}
      |> CashFunding.changeset(%{
        group_id: group.group_id,
        payment_operation_id: payment_operation_id,
        funding_order: funding_order,
        recorded_cents: amount_cents,
        held_cents: amount_cents
      })
      |> Repo.insert!()

    allocate_cash(active_rooms(group.group_id), funding, amount_cents)
    funding
  end

  @doc "Returns active rooms in their immutable partner-supplied order."
  def active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: room.position
    )
  end

  @doc "Returns the active-room summary persisted on the group row."
  def totals(group_id) do
    Repo.one(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        select: %{
          lodging_total_cents: coalesce(sum(room.lodging_total_cents), 0),
          deposit_due_cents: coalesce(sum(room.deposit_due_cents), 0),
          cash_paid_cents: coalesce(sum(room.cash_paid_cents), 0),
          credit_paid_cents: coalesce(sum(room.credit_paid_cents), 0)
        }
    )
    |> then(fn totals ->
      Map.put(
        totals,
        :deposit_paid_cents,
        totals.cash_paid_cents + totals.credit_paid_cents
      )
    end)
  end

  @doc "Builds group accounting attributes after room mutations."
  def group_attributes(group_id) do
    totals = totals(group_id)

    active_room_count =
      Repo.aggregate(
        from(room in Room,
          where: room.group_id == ^group_id and room.status == "active"
        ),
        :count
      )

    Map.put(
      totals,
      :status,
      if(active_room_count == 0, do: "cancelled", else: "active")
    )
  end

  @doc "Settles all held cash assigned to selected rooms into one disposition."
  def settle_cash(room_ids, disposition) when disposition in [:refunded, :retained, :converted] do
    field = Map.fetch!(@disposition_fields, disposition)

    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.room_id in ^room_ids,
          join: funding in assoc(allocation, :cash_funding),
          preload: [cash_funding: funding],
          order_by: [asc: funding.funding_order, asc: allocation.id]
      )

    contributions =
      allocations
      |> Enum.group_by(& &1.cash_funding_id)
      |> Enum.map(fn {_funding_id, source_allocations} ->
        funding = hd(source_allocations).cash_funding
        amount = Enum.sum_by(source_allocations, & &1.amount_cents)

        attributes = %{
          field => Map.fetch!(funding, field) + amount,
          :held_cents => funding.held_cents - amount
        }

        funding
        |> CashFunding.disposition_changeset(attributes)
        |> Repo.update!()

        %{cash_funding: funding, amount_cents: amount}
      end)
      |> Enum.sort_by(& &1.cash_funding.funding_order)

    Repo.delete_all(from allocation in CashAllocation, where: allocation.room_id in ^room_ids)
    contributions
  end

  @doc "Removes held cash from a payment in reverse room-fill order."
  def reduce_cash(%CashFunding{} = funding, amount_cents) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.cash_funding_id == ^funding.id,
          join: room in assoc(allocation, :room),
          preload: [room: room],
          order_by: [desc: room.position, desc: allocation.id]
      )

    remove_cash_allocations(allocations, amount_cents)

    funding
    |> CashFunding.disposition_changeset(%{
      held_cents: funding.held_cents - amount_cents,
      reduced_cents: funding.reduced_cents + amount_cents
    })
    |> Repo.update!()
  end

  @doc "Moves every non-reduced cent of a payment to charged-back cash."
  def charge_back_cash(%CashFunding{} = funding) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.cash_funding_id == ^funding.id,
          join: room in assoc(allocation, :room),
          preload: [room: room],
          order_by: [desc: room.position, desc: allocation.id]
      )

    remove_cash_allocations(allocations, funding.held_cents)

    charged_back_cents = funding.recorded_cents - funding.reduced_cents

    funding
    |> CashFunding.disposition_changeset(%{
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: charged_back_cents
    })
    |> Repo.update!()

    charged_back_cents
  end

  @doc "Marks rooms cancelled after their funding has been settled."
  def cancel_rooms(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Room.accounting_changeset(%{
        status: "cancelled",
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
      |> Repo.update!()
    end)
  end

  defp allocate_cash(_rooms, _funding, 0), do: :ok

  defp allocate_cash([], _funding, remaining_cents) do
    raise "cash funding exceeds active room capacity by #{remaining_cents} cents"
  end

  defp allocate_cash([room | rooms], funding, remaining_cents) do
    available = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    allocated_cents = min(available, remaining_cents)

    if allocated_cents > 0 do
      %CashAllocation{}
      |> CashAllocation.changeset(%{
        cash_funding_id: funding.id,
        room_id: room.id,
        amount_cents: allocated_cents
      })
      |> Repo.insert!()

      room
      |> Room.accounting_changeset(%{cash_paid_cents: room.cash_paid_cents + allocated_cents})
      |> Repo.update!()
    end

    allocate_cash(rooms, funding, remaining_cents - allocated_cents)
  end

  defp remove_cash_allocations(_allocations, 0), do: :ok

  defp remove_cash_allocations([], remaining_cents) do
    raise "cash disposition exceeds held allocations by #{remaining_cents} cents"
  end

  defp remove_cash_allocations([allocation | allocations], remaining_cents) do
    removed_cents = min(allocation.amount_cents, remaining_cents)

    allocation.room
    |> Room.accounting_changeset(%{
      cash_paid_cents: allocation.room.cash_paid_cents - removed_cents
    })
    |> Repo.update!()

    if removed_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - removed_cents)
      |> Repo.update!()
    end

    remove_cash_allocations(allocations, remaining_cents - removed_cents)
  end
end
