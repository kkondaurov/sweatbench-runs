defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Allocates new funding in room order and removes only the selected held funding.
  All writes share the enclosing durable operation transaction.
  """
  import Ecto.Query, except: [update: 2]
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditEntitlement, FundingAllocation, HotelCredit, Payment, Room}

  def active_rooms(group_id) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: r.position
    )
  end

  def fund(group_id, amount, source) do
    field = if source[:credit_lot_id], do: :credit_paid_cents, else: :cash_paid_cents

    remaining =
      Enum.reduce(active_rooms(group_id), amount, fn room, unpaid ->
        filled =
          min(unpaid, room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents)

        if filled > 0 do
          Repo.insert!(
            struct!(
              FundingAllocation,
              Map.merge(source, %{
                group_id: group_id,
                room_id: room.id,
                amount_cents: filled
              })
            )
          )

          update(room, %{field => Map.fetch!(room, field) + filled})
        end

        unpaid - filled
      end)

    if remaining != 0, do: raise("funding exceeds room capacity")
  end

  def settle(group, rooms, refundable, method, operation_id, on) do
    ids = Enum.map(rooms, & &1.id)
    allocations = Repo.all(from a in FundingAllocation, where: a.room_id in ^ids, order_by: a.id)
    cash_allocations = Enum.filter(allocations, &is_nil(&1.credit_lot_id))
    cash = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))

    disposition =
      cond do
        not refundable -> :retained_cents
        method == "hotel_credit" -> :converted_to_credit_cents
        true -> :refunded_cents
      end

    {issued, lot} =
      HotelCredit.issue(
        group,
        operation_id,
        if(disposition == :converted_to_credit_cents, do: cash, else: 0),
        on
      )

    settle_cash(cash_allocations, disposition, lot)

    allocations
    |> Enum.reject(&is_nil(&1.credit_lot_id))
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, slices} ->
      HotelCredit.settle_amount(
        group.group_id,
        lot_id,
        Enum.sum(Enum.map(slices, & &1.amount_cents)),
        refundable,
        on
      )
    end)

    Repo.delete_all(from a in FundingAllocation, where: a.room_id in ^ids)

    Enum.each(
      rooms,
      &update(&1, %{
        status: "cancelled",
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
    )

    %{
      refunded_cents: if(disposition == :refunded_cents, do: cash, else: 0),
      retained_cents: if(disposition == :retained_cents, do: cash, else: 0),
      converted_to_credit_cents: if(disposition == :converted_to_credit_cents, do: cash, else: 0),
      credit_issued_cents: issued
    }
  end

  defp settle_cash(allocations, disposition, lot) do
    # A payment can span several rooms. Round running totals once per payment,
    # keeping legacy cash ahead of every identified payment.
    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.sort_by(fn {payment_id, slices} ->
      {payment_id != nil, Enum.min(Enum.map(slices, & &1.id))}
    end)
    |> Enum.reduce(0, fn {payment_id, slices}, preceding ->
      cash = Enum.sum(Enum.map(slices, & &1.amount_cents))

      if payment_id do
        payment = Repo.get!(Payment, payment_id)
        update(payment, %{disposition => Map.fetch!(payment, disposition) + cash})

        if lot do
          Repo.insert!(%CreditEntitlement{
            credit_lot_id: lot.id,
            payment_operation_id: payment_id,
            amount_cents:
              HotelCredit.bonus_value(preceding + cash) - HotelCredit.bonus_value(preceding)
          })
        end
      end

      preceding + cash
    end)
  end

  def remove_cash(payment_id, amount) do
    allocations =
      Repo.all(
        from a in FundingAllocation,
          where: a.payment_operation_id == ^payment_id,
          order_by: [desc: a.id]
      )

    remaining =
      Enum.reduce(allocations, amount, fn allocation, remaining ->
        removed = min(remaining, allocation.amount_cents)

        if removed > 0 do
          room = Repo.get!(Room, allocation.room_id)
          update(room, %{cash_paid_cents: room.cash_paid_cents - removed})

          if removed == allocation.amount_cents,
            do: Repo.delete!(allocation),
            else: update(allocation, %{amount_cents: allocation.amount_cents - removed})
        end

        remaining - removed
      end)

    if remaining != 0, do: raise("payment held cash does not match its allocations")
  end

  defp update(record, changes), do: record |> Ecto.Changeset.change(changes) |> Repo.update!()
end
