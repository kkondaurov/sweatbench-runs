defmodule GroupStay.RoomAccounting do
  @moduledoc """
  Owns allocation and settlement of group funding at room granularity.

  Cash allocations retain durable-payment provenance, allowing provider corrections without
  disturbing unrelated funding.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.{HotelCredit, Repo}
  alias GroupStay.Reservations.{CashPaymentAccounting, Room, RoomCashAllocation}

  @doc "Records and allocates a new durable cash payment."
  def record_cash_payment(group, operation_id, amount) do
    accounting =
      %CashPaymentAccounting{}
      |> Changeset.change(%{
        payment_operation_id: operation_id,
        group_id: group.group_id,
        recorded_cents: amount,
        held_cents: amount
      })
      |> Repo.insert!()

    allocate_cash(group.group_id, accounting.id, amount)
    accounting
  end

  @doc "Associates a newly inserted durable operation record with its payment row."
  def bind_operation_record(operation_id, operation_record_id) do
    from(payment in CashPaymentAccounting,
      where: payment.payment_operation_id == ^operation_id and is_nil(payment.operation_record_id)
    )
    |> Repo.update_all(set: [operation_record_id: operation_record_id])

    :ok
  end

  @doc "Settles selected active rooms and returns changes for the parent group."
  def settle_rooms(group, rooms, refundable?, refund_method, operation_id, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    cash_allocations =
      from(allocation in RoomCashAllocation,
        join: room in assoc(allocation, :room),
        left_join: payment in assoc(allocation, :payment_accounting),
        where: allocation.room_id in ^room_ids,
        order_by: [
          asc_nulls_first: payment.operation_record_id,
          asc: room.position,
          asc: allocation.id
        ]
      )
      |> Repo.all()

    cash = Enum.sum_by(cash_allocations, & &1.amount_cents)
    refunded = if refundable? and refund_method == "cash", do: cash, else: 0
    retained = if refundable?, do: 0, else: cash
    converted = if refundable? and refund_method == "hotel_credit", do: cash, else: 0

    disposition =
      cond do
        refunded > 0 -> :refunded_cents
        retained > 0 -> :retained_cents
        converted > 0 -> :converted_to_credit_cents
        true -> nil
      end

    move_payment_cash(cash_allocations, disposition)
    cash_blocks = funding_blocks(cash_allocations)

    credit_issued =
      if converted > 0,
        do: HotelCredit.issue(group.guest_id, operation_id, cash_blocks, occurred_on),
        else: 0

    HotelCredit.settle_room_allocations(room_ids, refundable?, occurred_on)

    from(allocation in RoomCashAllocation, where: allocation.room_id in ^room_ids)
    |> Repo.delete_all()

    from(room in Room, where: room.id in ^room_ids)
    |> Repo.update_all(set: [status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0])

    %{
      refunded_cents: refunded,
      retained_cents: retained,
      converted_cents: converted,
      credit_issued_cents: credit_issued,
      active_totals: active_totals(group.group_id)
    }
  end

  @doc "Removes an amount from one payment's held allocations in reverse fill order."
  def reduce_payment(payment, amount) do
    remove_held_allocations(payment, amount)

    update_payment(payment,
      held_cents: payment.held_cents - amount,
      reduced_cents: payment.reduced_cents + amount
    )

    active_totals(payment.group_id)
  end

  @doc "Charges back every non-reduced disposition of a payment."
  def charge_back_payment(payment) do
    charged =
      payment.held_cents + payment.refunded_cents + payment.retained_cents +
        payment.converted_to_credit_cents

    remove_held_allocations(payment, payment.held_cents)
    HotelCredit.revoke_payment_entitlements(payment.id)

    update_payment(payment,
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: payment.charged_back_cents + charged
    )

    {charged, active_totals(payment.group_id)}
  end

  defp allocate_cash(group_id, payment_id, amount) do
    rooms =
      from(room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: [asc: room.position]
      )
      |> Repo.all()

    Enum.reduce_while(rooms, amount, fn room, left ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      allocated = min(capacity, left)

      if allocated > 0 do
        %RoomCashAllocation{}
        |> Changeset.change(%{
          room_id: room.id,
          payment_accounting_id: payment_id,
          amount_cents: allocated
        })
        |> Repo.insert!()

        from(candidate in Room, where: candidate.id == ^room.id)
        |> Repo.update_all(inc: [cash_paid_cents: allocated])
      end

      if allocated == left, do: {:halt, 0}, else: {:cont, left - allocated}
    end)
  end

  defp remove_held_allocations(_payment, 0), do: :ok

  defp remove_held_allocations(payment, amount) do
    from(allocation in RoomCashAllocation,
      join: room in assoc(allocation, :room),
      where: allocation.payment_accounting_id == ^payment.id,
      order_by: [desc: room.position, desc: allocation.id],
      preload: [:room]
    )
    |> Repo.all()
    |> remove_from_allocations(amount)
  end

  defp remove_from_allocations(_allocations, 0), do: :ok

  defp remove_from_allocations([allocation | rest], left) do
    removed = min(allocation.amount_cents, left)

    from(room in Room, where: room.id == ^allocation.room_id)
    |> Repo.update_all(inc: [cash_paid_cents: -removed])

    if removed == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Changeset.change(amount_cents: allocation.amount_cents - removed)
      |> Repo.update!()
    end

    remove_from_allocations(rest, left - removed)
  end

  defp move_payment_cash(allocations, nil), do: allocations

  defp move_payment_cash(allocations, disposition) do
    allocations
    |> Enum.reject(&is_nil(&1.payment_accounting_id))
    |> Enum.group_by(& &1.payment_accounting_id, & &1.amount_cents)
    |> Enum.each(fn {payment_id, amounts} ->
      amount = Enum.sum(amounts)

      from(payment in CashPaymentAccounting, where: payment.id == ^payment_id)
      |> Repo.update_all(inc: [{:held_cents, -amount}, {disposition, amount}])
    end)
  end

  defp funding_blocks(allocations) do
    allocations
    |> Enum.group_by(& &1.payment_accounting_id, & &1.amount_cents)
    |> Enum.map(fn {payment_id, amounts} -> {payment_id, Enum.sum(amounts)} end)
    |> Enum.sort_by(fn
      {nil, _amount} -> {-1, 0}
      {payment_id, _amount} -> {0, operation_record_id(payment_id)}
    end)
  end

  defp operation_record_id(payment_id) do
    Repo.one!(
      from payment in CashPaymentAccounting,
        where: payment.id == ^payment_id,
        select: payment.operation_record_id
    )
  end

  defp update_payment(payment, changes),
    do: payment |> Changeset.change(changes) |> Repo.update!()

  defp active_totals(group_id) do
    Repo.one(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        select: %{
          active_room_count: count(room.id),
          lodging_total_cents: coalesce(sum(room.lodging_total_cents), 0),
          deposit_due_cents: coalesce(sum(room.deposit_due_cents), 0),
          cash_paid_cents: coalesce(sum(room.cash_paid_cents), 0),
          credit_paid_cents: coalesce(sum(room.credit_paid_cents), 0)
        }
    )
    |> then(&Map.put(&1, :deposit_paid_cents, &1.cash_paid_cents + &1.credit_paid_cents))
  end
end
