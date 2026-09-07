defmodule GroupStay.Payments do
  @moduledoc """
  Owns recorded cash, its room allocations, and provider-side adjustments.

  Cash is allocated in active-room order. The immutable payment principal plus allocation
  dispositions form a double-entry-style invariant: held, refunded, retained, converted, reduced,
  and charged-back portions always sum to the amount originally recorded.
  """

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Funding.AllocationOrder
  alias GroupStay.Payments.{CashAllocation, CashPayment}
  alias GroupStay.Repo
  alias GroupStay.Reservations.RoomAccounting

  @dispositions ~w(held refunded retained converted reduced charged_back)a

  def record(group, operation_id, amount_cents, funding_order) do
    payment =
      %CashPayment{}
      |> CashPayment.creation_changeset(%{
        group_id: group.group_id,
        payment_operation_id: operation_id,
        recorded_cents: amount_cents,
        funding_order: funding_order,
        transfer_participated: false
      })
      |> Repo.insert!()

    allocate_payment(payment, RoomAccounting.active_rooms(group.group_id), amount_cents)
    payment
  end

  def get(payment_operation_id) when is_binary(payment_operation_id) do
    Repo.get_by(CashPayment, payment_operation_id: payment_operation_id)
  end

  def get(_payment_operation_id), do: nil

  def held_cents(payment) do
    allocation_total(payment.id, :held)
  end

  def remaining_chargeable_cents(payment) do
    Repo.one(
      from allocation in CashAllocation,
        where:
          allocation.cash_payment_id == ^payment.id and allocation.disposition != :reduced and
            allocation.disposition != :charged_back,
        select: sum(allocation.amount_cents)
    ) || 0
  end

  @doc "Settles held cash allocated to the selected rooms."
  def settle_rooms(group, rooms, refundable?, refund_method, operation_id, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: payment in assoc(allocation, :cash_payment),
          where: allocation.room_id in ^room_ids and allocation.disposition == :held,
          preload: [cash_payment: payment],
          order_by: [asc: allocation.allocation_order_id]
      )

    cash_cents = Enum.sum(Enum.map(allocations, & &1.amount_cents))

    {disposition, credit_lot, credit_issued_cents} =
      settlement_destination(
        group,
        allocations,
        cash_cents,
        refundable?,
        refund_method,
        operation_id,
        occurred_on
      )

    Enum.each(allocations, fn allocation ->
      allocation
      |> CashAllocation.disposition_changeset(disposition, credit_lot && credit_lot.id)
      |> Repo.update!()
    end)

    %{
      refunded_cents: if(disposition == :refunded, do: cash_cents, else: 0),
      retained_cents: if(disposition == :retained, do: cash_cents, else: 0),
      converted_cents: if(disposition == :converted, do: cash_cents, else: 0),
      credit_issued_cents: credit_issued_cents,
      credit_lot: credit_lot
    }
  end

  @doc "Removes held portions of a payment from the most recently filled room backwards."
  def reduce(payment, amount_cents) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.cash_payment_id == ^payment.id and allocation.disposition == :held,
          order_by: [desc: allocation.allocation_order_id]
      )

    consume_held(allocations, amount_cents, :reduced, %{})
  end

  @doc "Reclassifies every non-reduced portion and claws back converted-credit entitlements."
  def charge_back(payment) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.cash_payment_id == ^payment.id and allocation.disposition != :reduced and
              allocation.disposition != :charged_back,
          order_by: allocation.id
      )
      |> Enum.sort_by(fn allocation ->
        if allocation.disposition == :held,
          do: {0, -allocation.allocation_order_id},
          else: {1, allocation.id}
      end)

    summary =
      Enum.reduce(allocations, empty_summary(), fn allocation, totals ->
        room = Repo.get!(GroupStay.Reservations.Room, allocation.room_id)

        if allocation.disposition == :held do
          RoomAccounting.fund_room(room, -allocation.amount_cents, 0)
        end

        allocation
        |> CashAllocation.disposition_changeset(:charged_back)
        |> Repo.update!()

        totals
        |> Map.update!(:charged_back_cents, &(&1 + allocation.amount_cents))
        |> Map.update!(allocation.disposition, &(&1 + allocation.amount_cents))
        |> add_group_disposition(room.group_id, allocation)
      end)

    Map.put(summary, :credit, Credits.claw_back_entitlements(payment))
  end

  def statement(payment) do
    totals = disposition_totals(payment.id)

    statement = %{
      payment_operation_id: payment.payment_operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: totals.held,
      refunded_cents: totals.refunded,
      retained_cents: totals.retained,
      converted_to_credit_cents: totals.converted,
      reduced_cents: totals.reduced,
      charged_back_cents: totals.charged_back
    }

    if payment.transfer_participated do
      Map.put(statement, :held_by_group, held_by_group(payment.id))
    else
      statement
    end
  end

  def ledger_totals do
    rows =
      Repo.all(
        from allocation in CashAllocation,
          group_by: allocation.disposition,
          select: {allocation.disposition, sum(allocation.amount_cents)}
      )

    totals = Map.new(rows)

    %{
      cash_held_cents: Map.get(totals, :held, 0),
      cash_refunded_cents: Map.get(totals, :refunded, 0),
      cash_retained_cents: Map.get(totals, :retained, 0),
      cash_converted_to_credit_cents: Map.get(totals, :converted, 0),
      cash_reduced_cents: Map.get(totals, :reduced, 0),
      cash_charged_back_cents: Map.get(totals, :charged_back, 0)
    }
  end

  defp allocate_payment(_payment, _rooms, 0), do: :ok

  defp allocate_payment(payment, [room | rooms], amount_cents) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    allocated = min(capacity, amount_cents)

    if allocated > 0 do
      %CashAllocation{}
      |> CashAllocation.creation_changeset(%{
        cash_payment_id: payment.id,
        room_id: room.id,
        amount_cents: allocated,
        disposition: :held,
        allocation_order_id: AllocationOrder.next_id!()
      })
      |> Repo.insert!()

      RoomAccounting.fund_room(room, allocated, 0)
    end

    allocate_payment(payment, rooms, amount_cents - allocated)
  end

  defp settlement_destination(_group, _allocations, _cash, true, :cash, _id, _on),
    do: {:refunded, nil, 0}

  defp settlement_destination(group, allocations, cash, true, :hotel_credit, id, on) do
    if cash > 0 do
      lot = Credits.issue_for_cash(group, id, cash, on, allocations)
      {:converted, lot, cash + round_percentage(cash, 10)}
    else
      {:converted, nil, 0}
    end
  end

  defp settlement_destination(_group, _allocations, _cash, false, :cash, _id, _on),
    do: {:retained, nil, 0}

  defp consume_held(_allocations, 0, _disposition, affected_groups), do: affected_groups

  defp consume_held([allocation | rest], remaining, disposition, affected_groups) do
    consumed = min(allocation.amount_cents, remaining)
    room = Repo.get!(GroupStay.Reservations.Room, allocation.room_id)

    if consumed == allocation.amount_cents do
      allocation
      |> CashAllocation.disposition_changeset(disposition)
      |> Repo.update!()
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - consumed)
      |> Repo.update!()

      %CashAllocation{}
      |> CashAllocation.creation_changeset(%{
        cash_payment_id: allocation.cash_payment_id,
        room_id: allocation.room_id,
        amount_cents: consumed,
        disposition: disposition,
        allocation_order_id: allocation.allocation_order_id
      })
      |> Repo.insert!()
    end

    RoomAccounting.fund_room(room, -consumed, 0)

    consume_held(
      rest,
      remaining - consumed,
      disposition,
      Map.update(affected_groups, room.group_id, consumed, &(&1 + consumed))
    )
  end

  defp disposition_totals(payment_id) do
    base = Map.new(@dispositions, &{&1, 0})

    Repo.all(
      from allocation in CashAllocation,
        where: allocation.cash_payment_id == ^payment_id,
        group_by: allocation.disposition,
        select: {allocation.disposition, sum(allocation.amount_cents)}
    )
    |> Enum.reduce(base, fn {disposition, amount}, totals ->
      Map.put(totals, disposition, amount)
    end)
  end

  defp allocation_total(payment_id, disposition) do
    Repo.one(
      from allocation in CashAllocation,
        where:
          allocation.cash_payment_id == ^payment_id and
            allocation.disposition == ^disposition,
        select: sum(allocation.amount_cents)
    ) || 0
  end

  defp held_by_group(payment_id) do
    Repo.all(
      from allocation in CashAllocation,
        join: room in GroupStay.Reservations.Room,
        on: room.id == allocation.room_id,
        where:
          allocation.cash_payment_id == ^payment_id and allocation.disposition == :held and
            room.status == :active,
        group_by: room.group_id,
        order_by: room.group_id,
        select: %{
          group_id: room.group_id,
          amount_cents: sum(allocation.amount_cents)
        }
    )
  end

  defp empty_summary do
    %{
      charged_back_cents: 0,
      held: 0,
      refunded: 0,
      retained: 0,
      converted: 0,
      groups: %{}
    }
  end

  defp add_group_disposition(summary, group_id, allocation) do
    group_summary =
      Map.get(summary.groups, group_id, %{
        held: 0,
        refunded: 0,
        retained: 0,
        converted: 0,
        charged_back: 0
      })

    group_summary =
      group_summary
      |> Map.update!(:charged_back, &(&1 + allocation.amount_cents))
      |> then(fn group_summary ->
        case allocation.disposition do
          disposition when disposition in [:refunded, :retained, :converted] ->
            Map.update!(group_summary, disposition, &(&1 + allocation.amount_cents))

          :held ->
            Map.update!(group_summary, :held, &(&1 + allocation.amount_cents))

          _other ->
            group_summary
        end
      end)

    put_in(summary, [:groups, group_id], group_summary)
  end

  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)
end
