defmodule GroupStay.Reservations.AccountingBackfill do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CashFunding,
    Credit,
    CreditAllocation,
    CreditLot,
    Group,
    PartnerOperation,
    Room
  }

  # Invoked by the room-accounting migration after its DDL has been flushed.
  # The argument documents which migration repo is in use; this application has
  # one repo, and runtime schemas intentionally centralize the reconstruction.
  def run(_migration_repo) do
    receipts = Repo.all(from operation in PartnerOperation, order_by: operation.commit_order)

    original_credit_allocations =
      Repo.all(from allocation in CreditAllocation, order_by: allocation.id)

    Repo.delete_all(CreditAllocation)

    Repo.all(Group)
    |> Enum.each(&backfill_group(&1, receipts, original_credit_allocations))

    backfill_entitlements(receipts)
    :ok
  end

  defp backfill_group(group, receipts, original_credit_allocations) do
    group_receipts = applied_funding_receipts(receipts, group.group_id)
    cash_receipts = Enum.filter(group_receipts, &(&1.operation_type == "record_cash_payment"))
    credit_receipts = Enum.filter(group_receipts, &(&1.operation_type == "apply_hotel_credit"))

    durable_cash_cents = Enum.sum_by(cash_receipts, &amount/1)
    legacy_cash_cents = max(group.cash_paid_cents - durable_cash_cents, 0)

    fundings = create_cash_fundings(group, cash_receipts, legacy_cash_cents)

    if group.status == "active" do
      credit_segments =
        original_credit_allocations
        |> Enum.filter(&(&1.group_id == group.group_id))
        |> Enum.map(&%{lot_id: &1.credit_lot_id, amount_cents: &1.amount_cents})

      durable_credit_cents = Enum.sum_by(credit_receipts, &amount/1)
      legacy_credit_cents = max(group.credit_paid_cents - durable_credit_cents, 0)

      {legacy_segments, remaining_segments} = take_segments(credit_segments, legacy_credit_cents)

      {durable_credit_events, []} =
        Enum.map_reduce(credit_receipts, remaining_segments, fn receipt, segments ->
          {taken, rest} = take_segments(segments, amount(receipt))
          {{receipt.commit_order, {:credit, receipt.operation_id, taken}}, rest}
        end)

      legacy_events =
        []
        |> maybe_add_legacy_cash(fundings)
        |> maybe_add_legacy_credit(legacy_segments)

      durable_cash_events =
        Enum.map(cash_receipts, fn receipt ->
          funding = Enum.find(fundings, &(&1.payment_operation_id == receipt.operation_id))
          {receipt.commit_order, {:cash, funding, funding.recorded_cents}}
        end)

      events =
        legacy_events ++ Enum.sort_by(durable_cash_events ++ durable_credit_events, &elem(&1, 0))

      allocate_events(group, events)
    else
      zero_group_active_totals(group)
    end
  end

  defp applied_funding_receipts(receipts, group_id) do
    Enum.filter(receipts, fn receipt ->
      receipt.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
        receipt.result["status"] == "applied" and receipt.result["group_id"] == group_id
    end)
  end

  defp create_cash_fundings(group, cash_receipts, legacy_cash_cents) do
    sources =
      if legacy_cash_cents > 0,
        do: [{nil, 0, legacy_cash_cents}],
        else: []

    sources =
      sources ++
        Enum.map(cash_receipts, &{&1.operation_id, &1.commit_order, amount(&1)})

    fundings =
      Enum.map(sources, fn {operation_id, funding_order, recorded_cents} ->
        dispositions = initial_dispositions(group, recorded_cents)

        %CashFunding{}
        |> CashFunding.changeset(
          Map.merge(dispositions, %{
            group_id: group.group_id,
            payment_operation_id: operation_id,
            funding_order: funding_order,
            recorded_cents: recorded_cents
          })
        )
        |> Repo.insert!()
      end)

    # Old releases settled a whole group uniformly, so every source has the
    # same disposition. This assertion guards a corrupt legacy aggregate.
    expected = group.cash_paid_cents
    actual = Enum.sum_by(fundings, & &1.recorded_cents)

    if expected != actual do
      raise "cannot reconstruct cash funding for #{group.group_id}: #{expected} != #{actual}"
    end

    fundings
  end

  defp initial_dispositions(%Group{status: "active"}, recorded_cents),
    do: %{held_cents: recorded_cents}

  defp initial_dispositions(group, recorded_cents) do
    cond do
      group.cash_refunded_cents > 0 -> %{refunded_cents: recorded_cents}
      group.cash_retained_cents > 0 -> %{retained_cents: recorded_cents}
      group.cash_converted_to_credit_cents > 0 -> %{converted_to_credit_cents: recorded_cents}
      true -> %{charged_back_cents: recorded_cents}
    end
  end

  defp maybe_add_legacy_cash(events, fundings) do
    case Enum.find(fundings, &is_nil(&1.payment_operation_id)) do
      nil -> events
      funding -> events ++ [{-2, {:cash, funding, funding.recorded_cents}}]
    end
  end

  defp maybe_add_legacy_credit(events, []), do: events
  defp maybe_add_legacy_credit(events, segments), do: events ++ [{-1, {:credit, nil, segments}}]

  defp allocate_events(group, events) do
    rooms =
      Repo.all(
        from room in Room, where: room.group_id == ^group.group_id, order_by: room.position
      )

    room_state = Map.new(rooms, &{&1.id, %{room: &1, paid_cents: 0, cash: 0, credit: 0}})

    {_rooms, final_state} =
      Enum.reduce(events, {rooms, room_state}, fn {_order, event}, {ordered_rooms, state} ->
        units = event_units(event)
        {remaining_rooms, updated_state} = allocate_units(units, ordered_rooms, state)
        {remaining_rooms, updated_state}
      end)

    Enum.each(final_state, fn {_room_id, entry} ->
      entry.room
      |> Room.accounting_changeset(%{
        cash_paid_cents: entry.cash,
        credit_paid_cents: entry.credit
      })
      |> Repo.update!()
    end)
  end

  defp event_units({:cash, funding, amount}),
    do: [%{kind: :cash, source: funding, amount_cents: amount}]

  defp event_units({:credit, operation_id, segments}) do
    Enum.map(segments, fn segment ->
      %{kind: :credit, source: {segment.lot_id, operation_id}, amount_cents: segment.amount_cents}
    end)
  end

  defp allocate_units([], rooms, state), do: {rooms, state}

  defp allocate_units([unit | units], [room | rooms] = ordered_rooms, state) do
    entry = Map.fetch!(state, room.id)
    capacity = room.deposit_due_cents - entry.paid_cents
    allocated_cents = min(capacity, unit.amount_cents)

    if allocated_cents > 0 do
      insert_reconstructed_allocation(unit, group_id(room), room.id, allocated_cents)

      field = if unit.kind == :cash, do: :cash, else: :credit

      updated_entry =
        entry
        |> Map.put(:paid_cents, entry.paid_cents + allocated_cents)
        |> Map.put(field, Map.fetch!(entry, field) + allocated_cents)

      state = Map.put(state, room.id, updated_entry)

      unit = %{unit | amount_cents: unit.amount_cents - allocated_cents}

      if unit.amount_cents == 0 do
        allocate_units(units, ordered_rooms, state)
      else
        allocate_units([unit | units], rooms, state)
      end
    else
      allocate_units([unit | units], rooms, state)
    end
  end

  defp allocate_units([unit | _units], [], _state) do
    raise "legacy funding exceeds room capacity by #{unit.amount_cents} cents"
  end

  defp insert_reconstructed_allocation(
         %{kind: :cash, source: funding},
         _group_id,
         room_id,
         amount
       ) do
    %CashAllocation{}
    |> CashAllocation.changeset(%{
      cash_funding_id: funding.id,
      room_id: room_id,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp insert_reconstructed_allocation(
         %{kind: :credit, source: {lot_id, operation_id}},
         group_id,
         room_id,
         amount
       ) do
    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      credit_lot_id: lot_id,
      group_id: group_id,
      room_id: room_id,
      funding_operation_id: operation_id,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp zero_group_active_totals(group) do
    group
    |> Ecto.Changeset.change(
      lodging_total_cents: 0,
      deposit_due_cents: 0,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0
    )
    |> Repo.update!()
  end

  defp backfill_entitlements(receipts) do
    cancellation_groups =
      receipts
      |> Enum.filter(&(&1.operation_type == "cancel_group" and &1.result["status"] == "applied"))
      |> Map.new(&{&1.operation_id, &1.result["group_id"]})

    Repo.all(CreditLot)
    |> Enum.each(fn lot ->
      with group_id when is_binary(group_id) <- cancellation_groups[lot.source_operation_id],
           fundings when fundings != [] <-
             Repo.all(
               from funding in CashFunding,
                 where:
                   funding.group_id == ^group_id and
                     funding.converted_to_credit_cents > 0,
                 order_by: funding.funding_order
             ) do
        contributions =
          Enum.map(fundings, &%{cash_funding: &1, amount_cents: &1.converted_to_credit_cents})

        Credit.create_entitlements(lot, contributions)
      else
        _ -> :ok
      end
    end)
  end

  defp take_segments(segments, 0), do: {[], segments}

  defp take_segments([segment | segments], amount_cents) do
    taken_cents = min(segment.amount_cents, amount_cents)
    taken = %{segment | amount_cents: taken_cents}

    remainder =
      if taken_cents == segment.amount_cents,
        do: segments,
        else: [%{segment | amount_cents: segment.amount_cents - taken_cents} | segments]

    {more_taken, rest} = take_segments(remainder, amount_cents - taken_cents)
    {[taken | more_taken], rest}
  end

  defp take_segments([], amount_cents) when amount_cents > 0 do
    raise "cannot reconstruct #{amount_cents} cents of legacy credit allocations"
  end

  defp amount(receipt), do: receipt.submitted_payload["amount_cents"]
  defp group_id(%Room{group_id: group_id}), do: group_id
end
