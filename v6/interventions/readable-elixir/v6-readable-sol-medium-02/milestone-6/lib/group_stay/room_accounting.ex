defmodule GroupStay.RoomAccounting do
  @moduledoc """
  Owns allocation and settlement of group funding at room granularity.

  Cash allocations retain durable-payment provenance, allowing provider corrections without
  disturbing unrelated funding.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.{FundingAllocations, HotelCredit, Repo}

  alias GroupStay.Reservations.{
    CashPaymentAccounting,
    CashPaymentSettlement,
    HotelCreditAllocation,
    Room,
    RoomCashAllocation
  }

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
        where: allocation.room_id in ^room_ids,
        order_by: [asc: allocation.allocation_sequence_id]
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

    move_payment_cash(cash_allocations, disposition, group.group_id)
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
    affected_group_ids = remove_held_allocations(payment, amount)

    update_payment(payment,
      held_cents: payment.held_cents - amount,
      reduced_cents: payment.reduced_cents + amount
    )

    totals_for_groups(affected_group_ids)
  end

  @doc "Charges back every non-reduced disposition of a payment."
  def charge_back_payment(payment) do
    charged =
      payment.held_cents + payment.refunded_cents + payment.retained_cents +
        payment.converted_to_credit_cents

    affected_group_ids = remove_held_allocations(payment, payment.held_cents)
    settlements = payment_settlements(payment.id)
    HotelCredit.revoke_payment_entitlements(payment.id)

    update_payment(payment,
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: payment.charged_back_cents + charged
    )

    from(settlement in CashPaymentSettlement,
      where: settlement.payment_accounting_id == ^payment.id
    )
    |> Repo.delete_all()

    {charged, totals_for_groups(affected_group_ids), settlements}
  end

  @doc "Moves held cash and credit between active groups without changing their provenance."
  def transfer_deposit(source_group_id, destination_group_id, amount) do
    source_group_id
    |> newest_allocations()
    |> draw_allocations(amount)
    |> Enum.each(&move_draw(&1, destination_group_id))

    %{
      source: active_totals(source_group_id),
      destination: active_totals(destination_group_id)
    }
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
          allocation_sequence_id: FundingAllocations.next_sequence_id!(),
          amount_cents: allocated
        })
        |> Repo.insert!()

        from(candidate in Room, where: candidate.id == ^room.id)
        |> Repo.update_all(inc: [cash_paid_cents: allocated])
      end

      if allocated == left, do: {:halt, 0}, else: {:cont, left - allocated}
    end)
  end

  defp remove_held_allocations(_payment, 0), do: []

  defp remove_held_allocations(payment, amount) do
    from(allocation in RoomCashAllocation,
      join: room in assoc(allocation, :room),
      where: allocation.payment_accounting_id == ^payment.id,
      order_by: [desc: allocation.allocation_sequence_id],
      preload: [:room]
    )
    |> Repo.all()
    |> remove_from_allocations(amount, MapSet.new())
    |> MapSet.to_list()
  end

  defp remove_from_allocations(_allocations, 0, affected), do: affected

  defp remove_from_allocations([allocation | rest], left, affected) do
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

    remove_from_allocations(
      rest,
      left - removed,
      MapSet.put(affected, allocation.room.group_id)
    )
  end

  defp move_payment_cash(allocations, nil, _group_id), do: allocations

  defp move_payment_cash(allocations, disposition, group_id) do
    allocations
    |> Enum.reject(&is_nil(&1.payment_accounting_id))
    |> Enum.group_by(& &1.payment_accounting_id, & &1.amount_cents)
    |> Enum.each(fn {payment_id, amounts} ->
      amount = Enum.sum(amounts)

      from(payment in CashPaymentAccounting, where: payment.id == ^payment_id)
      |> Repo.update_all(inc: [{:held_cents, -amount}, {disposition, amount}])

      record_settlement(payment_id, group_id, disposition, amount)
    end)
  end

  defp funding_blocks(allocations) do
    Enum.map(allocations, &{&1.payment_accounting_id, &1.amount_cents})
  end

  defp update_payment(payment, changes),
    do: payment |> Changeset.change(changes) |> Repo.update!()

  def active_totals(group_id) do
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

  defp totals_for_groups(group_ids),
    do: Map.new(group_ids, &{&1, active_totals(&1)})

  defp newest_allocations(group_id) do
    cash =
      from(allocation in RoomCashAllocation,
        join: room in assoc(allocation, :room),
        where: room.group_id == ^group_id and room.status == "active",
        preload: [:room]
      )
      |> Repo.all()
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit =
      from(allocation in HotelCreditAllocation,
        join: room in assoc(allocation, :room),
        where: room.group_id == ^group_id and room.status == "active",
        preload: [:room]
      )
      |> Repo.all()
      |> Enum.map(&%{kind: :credit, allocation: &1})

    Enum.sort_by(cash ++ credit, & &1.allocation.allocation_sequence_id, :desc)
  end

  defp draw_allocations(allocations, amount), do: draw_allocations(allocations, amount, [])
  defp draw_allocations(_allocations, 0, draws), do: Enum.reverse(draws)

  defp draw_allocations([entry | rest], left, draws) do
    drawn = min(entry.allocation.amount_cents, left)
    remove_source_allocation(entry, drawn)
    draw_allocations(rest, left - drawn, [{entry.kind, entry.allocation, drawn} | draws])
  end

  defp remove_source_allocation(%{kind: kind, allocation: allocation}, amount) do
    field = if kind == :cash, do: :cash_paid_cents, else: :credit_paid_cents

    from(room in Room, where: room.id == ^allocation.room_id)
    |> Repo.update_all(inc: [{field, -amount}])

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end
  end

  defp move_draw({kind, allocation, amount}, destination_group_id) do
    if kind == :cash and allocation.payment_accounting_id do
      from(payment in CashPaymentAccounting,
        where: payment.id == ^allocation.payment_accounting_id
      )
      |> Repo.update_all(set: [participated_in_transfer: true])
    end

    allocate_transferred(kind, allocation, destination_group_id, amount)
  end

  defp allocate_transferred(_kind, _allocation, _group_id, 0), do: :ok

  defp allocate_transferred(kind, allocation, group_id, amount) do
    room =
      Repo.one!(
        from room in Room,
          where:
            room.group_id == ^group_id and room.status == "active" and
              room.cash_paid_cents + room.credit_paid_cents < room.deposit_due_cents,
          order_by: [asc: room.position],
          limit: 1
      )

    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    moved = min(capacity, amount)
    insert_transferred_allocation(kind, allocation, room, moved)
    allocate_transferred(kind, allocation, group_id, amount - moved)
  end

  defp insert_transferred_allocation(:cash, allocation, room, amount) do
    %RoomCashAllocation{}
    |> Changeset.change(%{
      room_id: room.id,
      payment_accounting_id: allocation.payment_accounting_id,
      allocation_sequence_id: FundingAllocations.next_sequence_id!(),
      amount_cents: amount
    })
    |> Repo.insert!()

    from(candidate in Room, where: candidate.id == ^room.id)
    |> Repo.update_all(inc: [cash_paid_cents: amount])
  end

  defp insert_transferred_allocation(:credit, allocation, room, amount) do
    %HotelCreditAllocation{}
    |> Changeset.change(%{
      lot_id: allocation.lot_id,
      group_id: room.group_id,
      room_id: room.id,
      allocation_sequence_id: FundingAllocations.next_sequence_id!(),
      amount_cents: amount
    })
    |> Repo.insert!()

    from(candidate in Room, where: candidate.id == ^room.id)
    |> Repo.update_all(inc: [credit_paid_cents: amount])
  end

  defp record_settlement(payment_id, group_id, disposition, amount) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      CashPaymentSettlement,
      [
        Map.put(
          %{
            payment_accounting_id: payment_id,
            group_id: group_id,
            inserted_at: now,
            updated_at: now
          },
          disposition,
          amount
        )
      ],
      conflict_target: [:payment_accounting_id, :group_id],
      on_conflict: [inc: [{disposition, amount}], set: [updated_at: now]]
    )
  end

  defp payment_settlements(payment_id) do
    Repo.all(
      from settlement in CashPaymentSettlement,
        where: settlement.payment_accounting_id == ^payment_id
    )
  end
end
