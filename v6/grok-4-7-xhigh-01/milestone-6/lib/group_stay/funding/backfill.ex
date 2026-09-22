defmodule GroupStay.Funding.Backfill do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Credits.Allocation
  alias GroupStay.Credits.Lot
  alias GroupStay.Deposits
  alias GroupStay.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  def run do
    Repo.all(Group)
    |> Enum.each(&backfill_group/1)
  end

  def backfill_group(%Group{} = group) do
    assign_room_amounts!(group)

    if group.status == "cancelled" do
      backfill_cancelled_cash!(group)
      Funding.mark_rooms!(group, "cancelled")
    else
      backfill_active_funding!(group)
    end

    :ok
  end

  defp assign_room_amounts!(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])
    |> Enum.each(fn room ->
      amounts = Deposits.room_amounts(room.nightly_rate_cents, nights, group.rate_plan)

      room
      |> Ecto.Changeset.change(%{
        lodging_cents: amounts.lodging_cents,
        deposit_due_cents: amounts.deposit_due_cents,
        status: "active"
      })
      |> Repo.update!()
    end)
  end

  defp backfill_cancelled_cash!(group) do
    ops = funding_operations(group.group_id)
    durable_cash = sum_type(ops, "record_cash_payment")
    legacy_cash = group.cash_paid_cents - durable_cash
    settled = group.refunded_cents + group.retained_cents + group.cash_converted_cents

    if legacy_cash < 0 or settled != group.cash_paid_cents do
      raise "cancelled group #{group.group_id} cash cannot be allocated"
    end

    place_cash!(group, nil, legacy_cash)

    Enum.each(ops, fn
      %{type: "record_cash_payment", operation_id: operation_id, amount: amount} ->
        place_cash!(group, operation_id, amount)

      _other ->
        :ok
    end)

    reclassify_cancelled!(group)
  end

  defp reclassify_cancelled!(group) do
    cond do
      group.cash_converted_cents > 0 and group.refunded_cents == 0 and group.retained_cents == 0 ->
        Funding.reclassify_group_held!(group.id, "converted", conversion_lot_id(group))

      group.refunded_cents > 0 and group.retained_cents == 0 and group.cash_converted_cents == 0 ->
        Funding.reclassify_group_held!(group.id, "refunded")

      group.retained_cents > 0 and group.refunded_cents == 0 and group.cash_converted_cents == 0 ->
        Funding.reclassify_group_held!(group.id, "retained")

      group.cash_paid_cents == 0 ->
        :ok

      true ->
        raise "cancelled group #{group.group_id} has mixed cash dispositions"
    end
  end

  defp backfill_active_funding!(group) do
    ops = funding_operations(group.group_id)
    durable_cash = sum_type(ops, "record_cash_payment")
    durable_credit = sum_type(ops, "apply_hotel_credit")
    legacy_cash = group.cash_paid_cents - durable_cash
    legacy_credit = group.credit_paid_cents - durable_credit
    chunks = credit_chunks(group)

    if legacy_cash < 0 or legacy_credit < 0 or chunk_total(chunks) != group.credit_paid_cents do
      raise "active group #{group.group_id} funding cannot be allocated"
    end

    Repo.delete_all(from a in Allocation, where: a.group_id == ^group.id)

    place_cash!(group, nil, legacy_cash)
    chunks = place_credit!(group, chunks, legacy_credit)

    chunks =
      Enum.reduce(ops, chunks, fn op, chunks ->
        case op.type do
          "record_cash_payment" ->
            place_cash!(group, op.operation_id, op.amount)
            chunks

          "apply_hotel_credit" ->
            place_credit!(group, chunks, op.amount)
        end
      end)

    if chunks != [] do
      raise "active group #{group.group_id} left unallocated credit"
    end

    held = Funding.held_cash_total(Enum.map(Funding.active_rooms(group), & &1.id))
    credit = credit_total(group)

    if held != group.cash_paid_cents or credit != group.credit_paid_cents do
      raise "active group #{group.group_id} allocations changed aggregate balances"
    end
  end

  defp place_cash!(_group, _operation_id, 0), do: :ok

  defp place_cash!(group, operation_id, amount) do
    Funding.allocate_cash!(group, operation_id, amount)
  end

  defp place_credit!(_group, chunks, 0), do: chunks

  defp place_credit!(group, chunks, amount) do
    {taken, rest} = take_chunks(chunks, amount)
    Credits.place_existing!(group, taken)
    rest
  end

  defp take_chunks(chunks, 0), do: {[], chunks}

  defp take_chunks([{lot_id, amount} | rest], need) when amount <= need do
    {taken, rest} = take_chunks(rest, need - amount)
    {[{lot_id, amount} | taken], rest}
  end

  defp take_chunks([{lot_id, amount} | rest], need) do
    {[{lot_id, need}], [{lot_id, amount - need} | rest]}
  end

  defp take_chunks([], need) when need > 0 do
    raise "credit chunks were short by #{need}"
  end

  defp credit_chunks(group) do
    Repo.all(
      from a in Allocation,
        join: l in Lot,
        on: l.id == a.credit_lot_id,
        where: a.group_id == ^group.id,
        order_by: [asc: a.inserted_at, asc: l.expires_on, asc: l.source_operation_id, asc: a.id],
        select: {a.credit_lot_id, a.amount_cents}
    )
  end

  defp funding_operations(group_id) do
    Record
    |> where([r], r.type in ["record_cash_payment", "apply_hotel_credit"])
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.flat_map(fn record ->
      case Jason.decode(record.result) do
        {:ok, %{"status" => "applied", "group_id" => ^group_id, "amount_cents" => amount}}
        when is_integer(amount) and amount > 0 ->
          [%{operation_id: record.operation_id, type: record.type, amount: amount}]

        _other ->
          []
      end
    end)
  end

  defp conversion_lot_id(group) do
    Record
    |> where([r], r.type == "cancel_group")
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.find_value(fn record ->
      with {:ok, %{"status" => "applied", "group_id" => gid, "credit_issued_cents" => issued}}
           when gid == group.group_id and is_integer(issued) and issued > 0 <-
             Jason.decode(record.result),
           %Lot{} = lot <- Repo.get_by(Lot, source_operation_id: record.operation_id) do
        lot.id
      else
        _ -> nil
      end
    end)
  end

  defp sum_type(ops, type) do
    ops
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  defp chunk_total(chunks), do: Enum.sum(Enum.map(chunks, &elem(&1, 1)))

  defp credit_total(group) do
    Repo.one(
      from a in Allocation,
        where: a.group_id == ^group.id,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end
end
