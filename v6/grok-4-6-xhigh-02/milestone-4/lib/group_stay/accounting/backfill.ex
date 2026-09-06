defmodule GroupStay.Accounting.Backfill do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Groups
  alias GroupStay.Groups.CashPayment
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditEntitlement
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  def run do
    groups =
      Group
      |> Repo.all()
      |> Repo.preload(:rooms)

    Enum.each(groups, &backfill_group/1)
  end

  def backfill_group(%Group{} = group) do
    group = Repo.preload(group, :rooms, force: true)

    if already_allocated?(group) or already_cancelled_rooms?(group) do
      group
    else
      do_backfill_group(group)
    end
  end

  defp do_backfill_group(group) do
    nights = Groups.nights(group.arrival_on, group.departure_on)

    Enum.each(ordered_rooms(group), fn room ->
      due =
        if nights > 0 do
          Groups.room_deposit_cents(room.nightly_rate_cents * nights, group.rate_plan)
        else
          0
        end

      status = if group.status == "cancelled", do: "cancelled", else: "active"

      room
      |> Room.changeset(%{deposit_due_cents: due, status: status})
      |> Repo.update!()
    end)

    group = Repo.preload(group, :rooms, force: true)

    if group.status == "cancelled" do
      backfill_cancelled(group)
    else
      backfill_active(group)
    end
  end

  defp backfill_cancelled(group) do
    {cash_ops, _credit_ops} = funding_ops(group)
    converted = group.cash_converted_to_credit_cents || 0
    refunded = group.refunded_cents || 0
    retained = group.retained_cents || 0

    disposition =
      cond do
        converted > 0 -> :converted
        refunded > 0 -> :refunded
        retained > 0 -> :retained
        true -> :none
      end

    Enum.each(cash_ops, fn {operation_id, amount} ->
      attrs =
        %{
          operation_id: operation_id,
          group_id: group.group_id,
          recorded_cents: amount,
          held_cents: 0
        }
        |> Map.merge(disposition_attrs(disposition, amount))

      insert_payment(attrs)
    end)

    if disposition == :converted do
      recorded_total = Enum.reduce(cash_ops, 0, fn {_id, amount}, acc -> acc + amount end)
      legacy = max((group.cash_paid_cents || 0) - recorded_total, 0)

      sources =
        [{nil, legacy} | Enum.map(cash_ops, fn {id, amount} -> {id, amount} end)]
        |> Enum.filter(fn {_id, amount} -> amount > 0 end)

      record_cancelled_entitlements(group, sources)
    end

    Enum.each(ordered_rooms(group), fn room ->
      room
      |> Room.changeset(%{cash_paid_cents: 0, credit_paid_cents: 0, status: "cancelled"})
      |> Repo.update!()
    end)
  end

  defp backfill_active(group) do
    {cash_ops, credit_ops} = funding_ops(group)
    recorded_ops = recorded_funding_ops(group)

    recorded_cash = Enum.reduce(cash_ops, 0, fn {_id, amount}, acc -> acc + amount end)
    recorded_credit = Enum.reduce(credit_ops, 0, fn {_id, amount}, acc -> acc + amount end)
    legacy_cash = max((group.cash_paid_cents || 0) - recorded_cash, 0)
    legacy_credit = max((group.credit_paid_cents || 0) - recorded_credit, 0)

    chunks = application_chunks(group)
    {legacy_chunks, remaining_chunks} = take_chunks(chunks, legacy_credit)

    group = maybe_allocate(group, legacy_cash, "cash", nil, nil)

    group =
      Enum.reduce(legacy_chunks, group, fn {lot, amount}, group ->
        maybe_allocate(group, amount, "credit", nil, lot && lot.id)
      end)

    {_group, _remaining} =
      Enum.reduce(recorded_ops, {group, remaining_chunks}, fn op, {group, remaining} ->
        {type, operation_id, amount} = op

        case type do
          "record_cash_payment" ->
            group = maybe_allocate(group, amount, "cash", operation_id, nil)

            insert_payment(%{
              operation_id: operation_id,
              group_id: group.group_id,
              recorded_cents: amount,
              held_cents: amount
            })

            {group, remaining}

          "apply_hotel_credit" ->
            {taken, remaining} = take_chunks(remaining, amount)

            group =
              Enum.reduce(taken, group, fn {lot, lot_amount}, group ->
                maybe_allocate(group, lot_amount, "credit", operation_id, lot && lot.id)
              end)

            leftover =
              amount - Enum.reduce(taken, 0, fn {_lot, lot_amount}, acc -> acc + lot_amount end)

            group =
              if leftover > 0 do
                maybe_allocate(group, leftover, "credit", operation_id, nil)
              else
                group
              end

            {group, remaining}

          _ ->
            {group, remaining}
        end
      end)

    :ok
  end

  defp maybe_allocate(group, amount, _kind, _source, _lot_id) when amount <= 0, do: group

  defp maybe_allocate(group, amount, kind, source, lot_id) do
    Accounting.allocate_for_backfill!(group, amount, kind, source, lot_id)
  end

  defp funding_ops(group) do
    recorded_funding_ops(group)
    |> Enum.reduce({[], []}, fn
      {"record_cash_payment", id, amount}, {cash, credit} ->
        {cash ++ [{id, amount}], credit}

      {"apply_hotel_credit", id, amount}, {cash, credit} ->
        {cash, credit ++ [{id, amount}]}

      _, acc ->
        acc
    end)
  end

  defp recorded_funding_ops(group) do
    from(o in Operation, order_by: [asc: o.id])
    |> Repo.all()
    |> Enum.filter(fn record ->
      record.type in ["record_cash_payment", "apply_hotel_credit"] and
        Accounting.applied?(record) and
        Accounting.operation_group_id(record) == group.group_id
    end)
    |> Enum.map(fn record ->
      amount = result_int(record.result, "amount_cents")
      {record.type, record.operation_id, amount}
    end)
    |> Enum.filter(fn {_type, _id, amount} -> is_integer(amount) and amount > 0 end)
  end

  defp application_chunks(group) do
    from(a in CreditApplication,
      where: a.group_id == ^group.id,
      order_by: [asc: a.inserted_at, asc: a.id],
      preload: [:credit_lot]
    )
    |> Repo.all()
    |> Enum.map(fn app -> {app.credit_lot, app.amount_cents} end)
    |> Enum.filter(fn {_lot, amount} -> amount > 0 end)
  end

  defp take_chunks(chunks, amount) when amount <= 0, do: {[], chunks}

  defp take_chunks(chunks, amount) do
    {taken, remaining, _left} =
      Enum.reduce(chunks, {[], [], amount}, fn {lot, chunk_amount}, {taken, remaining, left} ->
        cond do
          left <= 0 ->
            {taken, remaining ++ [{lot, chunk_amount}], 0}

          chunk_amount <= left ->
            {taken ++ [{lot, chunk_amount}], remaining, left - chunk_amount}

          true ->
            {taken ++ [{lot, left}], remaining ++ [{lot, chunk_amount - left}], 0}
        end
      end)

    {taken, remaining}
  end

  defp record_cancelled_entitlements(group, sources) do
    lot = find_converted_lot(group)

    if lot do
      sources
      |> Accounting.telescoping_entitlements()
      |> Enum.with_index()
      |> Enum.each(fn {{source_id, cash, entitlement}, position} ->
        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: source_id,
          cash_cents: cash,
          entitlement_cents: entitlement,
          position: position
        })
        |> Repo.insert!()
      end)
    end
  end

  defp find_converted_lot(group) do
    cancel =
      from(o in Operation, order_by: [asc: o.id])
      |> Repo.all()
      |> Enum.find(fn record ->
        record.type == "cancel_group" and Accounting.applied?(record) and
          Accounting.operation_group_id(record) == group.group_id and
          result_int(record.result, "credit_issued_cents") > 0
      end)

    cond do
      cancel ->
        Repo.get_by(CreditLot, source_operation_id: cancel.operation_id)

      true ->
        from(l in CreditLot,
          where: l.guest_id == ^group.guest_id,
          order_by: [asc: l.inserted_at],
          limit: 1
        )
        |> Repo.one()
    end
  end

  defp disposition_attrs(:converted, amount), do: %{converted_to_credit_cents: amount}
  defp disposition_attrs(:refunded, amount), do: %{refunded_cents: amount}
  defp disposition_attrs(:retained, amount), do: %{retained_cents: amount}
  defp disposition_attrs(:none, _amount), do: %{}

  defp insert_payment(attrs) do
    %CashPayment{}
    |> CashPayment.changeset(attrs)
    |> Repo.insert()
  end

  defp already_allocated?(%Group{rooms: rooms}) do
    ids = Enum.map(rooms, & &1.id)

    ids != [] and
      Repo.exists?(from a in GroupStay.Groups.RoomAllocation, where: a.room_id in ^ids)
  end

  defp already_cancelled_rooms?(%Group{status: "cancelled", rooms: rooms}) do
    rooms != [] and Enum.all?(rooms, &(&1.status == "cancelled"))
  end

  defp already_cancelled_rooms?(_), do: false

  defp ordered_rooms(group), do: Enum.sort_by(group.rooms, & &1.position)

  defp result_int(nil, _key), do: 0

  defp result_int(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
    if is_integer(value), do: value, else: 0
  rescue
    ArgumentError -> 0
  end
end
