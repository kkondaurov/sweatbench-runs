defmodule GroupStay.Accounting do
  @moduledoc """
  Room deposit funding and cash dispositions. All mutations participate in the
  caller's operation transaction. Funding fills vacancies in booking order. A
  shared allocation sequence orders cash and credit across rooms and groups;
  transfers create new allocations while preserving payment or lot provenance.
  """
  import Ecto.Query
  alias GroupStay.{Repo, Credits}
  alias GroupStay.Accounting.{CashAllocation, Entitlement}
  alias GroupStay.Credits.Allocation

  @dispositions [
    held_cents: "held",
    refunded_cents: "refunded",
    retained_cents: "retained",
    converted_to_credit_cents: "converted_to_credit",
    reduced_cents: "reduced",
    charged_back_cents: "charged_back"
  ]
  @ledger_keys %{
    held_cents: :cash_held_cents,
    refunded_cents: :cash_refunded_cents,
    retained_cents: :cash_retained_cents,
    converted_to_credit_cents: :cash_converted_to_credit_cents,
    reduced_cents: :cash_reduced_cents,
    charged_back_cents: :cash_charged_back_cents
  }

  defp cash(group_id) do
    Repo.all(from a in CashAllocation, where: a.group_id == ^group_id, order_by: a.id)
  end

  defp credit(group_id) do
    Repo.all(from a in Allocation, where: a.group_id == ^group_id, order_by: a.id)
  end

  def fund_cash(group, payment_id, amount) do
    for {room_id, cents} <- vacancies(group, amount) do
      Repo.insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        allocation_order: next_allocation_order(),
        payment_operation_id: payment_id,
        amount_cents: cents
      })
    end

    :ok
  end

  def fund_credit(group, lot_id, amount) do
    for {room_id, cents} <- vacancies(group, amount) do
      Repo.insert!(%Allocation{
        group_id: group.group_id,
        room_id: room_id,
        allocation_order: next_allocation_order(),
        credit_lot_id: lot_id,
        amount_cents: cents
      })
    end
  end

  defp vacancies(group, amount) do
    rooms = room_balances(group)

    {allocations, 0} =
      Enum.map_reduce(rooms, amount, fn room, needed ->
        capacity =
          if room.status == "active",
            do: room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents,
            else: 0

        used = min(needed, capacity)
        {{room.room_id, used}, needed - used}
      end)

    Enum.filter(allocations, fn {_, cents} -> cents > 0 end)
  end

  defp room_balances(group) do
    cash = cash(group.group_id) |> Enum.filter(&(&1.disposition == "held"))
    credit = credit(group.group_id)

    Enum.map(group.rooms, fn room ->
      %{
        room
        | cash_paid_cents: room_sum(cash, room.room_id),
          credit_paid_cents: room_sum(credit, room.room_id)
      }
    end)
  end

  defp room_sum(rows, id),
    do: rows |> Enum.filter(&(&1.room_id == id)) |> Enum.map(& &1.amount_cents) |> Enum.sum()

  def refresh(group, cancelled_ids \\ []) do
    rooms =
      Enum.map(room_balances(group), fn room ->
        if room.room_id in cancelled_ids, do: %{room | status: "cancelled"}, else: room
      end)

    active = Enum.filter(rooms, &(&1.status == "active"))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    settlements = totals(cash(group.group_id))

    Ecto.Changeset.change(group,
      refunded_cents: settlements.refunded_cents,
      retained_cents: settlements.retained_cents,
      converted_to_credit_cents: settlements.converted_to_credit_cents,
      rooms: rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1.deposit_due_cents)),
      deposit_paid_cents: cash + credit,
      credit_paid_cents: credit,
      revision: group.revision + 1
    )
    |> Repo.update!()
  end

  def settle(group, room_ids, source_id, on, method, refundable?) do
    held =
      Enum.filter(cash(group.group_id), &(&1.disposition == "held" and &1.room_id in room_ids))

    amount = Enum.sum(Enum.map(held, & &1.amount_cents))

    disposition =
      cond do
        method == "hotel_credit" -> "converted_to_credit"
        refundable? -> "refunded"
        true -> "retained"
      end

    issued =
      if disposition == "converted_to_credit" and amount > 0 do
        {lot, issued} = Credits.issue(group, source_id, amount, on)
        assign_entitlements(held, lot.id)
        issued
      else
        0
      end

    for row <- held, do: move(row, row.amount_cents, disposition)
    Credits.settle(group, room_ids, refundable?, on)

    {refresh(group, room_ids),
     %{
       refunded_cents: if(disposition == "refunded", do: amount, else: 0),
       retained_cents: if(disposition == "retained", do: amount, else: 0),
       credit_issued_cents: issued
     }}
  end

  # A payment may fill several rooms. Round running principal once per payment,
  # in original funding order, so all entitlements sum exactly to the lot value.
  defp assign_entitlements(rows, lot_id) do
    rows
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.sort_by(fn {id, portions} ->
      if is_nil(id), do: -1, else: portions |> Enum.map(& &1.allocation_order) |> Enum.min()
    end)
    |> Enum.reduce(0, fn {payment_id, portions}, prior ->
      total = prior + Enum.sum(Enum.map(portions, & &1.amount_cents))

      Repo.insert!(%Entitlement{
        payment_operation_id: payment_id,
        credit_lot_id: lot_id,
        amount_cents: Credits.bonus_value(total) - Credits.bonus_value(prior)
      })

      total
    end)
  end

  @doc "Moves newest held portions first, preserving draw order when filling the destination."
  def transfer(source, destination, amount) do
    held = Enum.filter(cash(source.group_id), &(&1.disposition == "held"))
    rows = newest_first(held ++ credit(source.group_id))

    Enum.reduce_while(rows, amount, fn row, needed ->
      used = min(needed, row.amount_cents)
      withdraw(row, used)

      case row do
        %CashAllocation{payment_operation_id: payment_id} ->
          fund_cash(destination, payment_id, used)

          if payment_id do
            Repo.insert_all("transferred_payments", [%{payment_operation_id: payment_id}],
              on_conflict: :nothing
            )
          end

        %Allocation{credit_lot_id: lot_id} ->
          fund_credit(destination, lot_id, used)
      end

      if used == needed, do: {:halt, 0}, else: {:cont, needed - used}
    end)

    {refresh(source), refresh(destination)}
  end

  defp withdraw(row, amount) when amount == row.amount_cents, do: Repo.delete!(row)

  defp withdraw(row, amount),
    do: Repo.update!(Ecto.Changeset.change(row, amount_cents: row.amount_cents - amount))

  def reduce_payment(group, payment_id, amount) do
    held = payment_allocations(payment_id) |> Enum.filter(&(&1.disposition == "held"))

    {0, changed_ids} =
      Enum.reduce(newest_first(held), {amount, []}, fn row, {needed, ids} ->
        used = min(needed, row.amount_cents)

        if used > 0 do
          move(row, used, "reduced")
          {needed - used, [row.group_id | ids]}
        else
          {needed, ids}
        end
      end)

    refresh_affected(group, changed_ids)
  end

  def charge_back(group, payment_id) do
    rows =
      payment_allocations(payment_id)
      |> Enum.reject(&(&1.disposition in ~w(reduced charged_back)))

    for row <- newest_first(rows), do: move(row, row.amount_cents, "charged_back")

    for entitlement <-
          Repo.all(from e in Entitlement, where: e.payment_operation_id == ^payment_id) do
      Credits.claw_back(entitlement.credit_lot_id, entitlement.amount_cents)
    end

    {refresh_affected(group, Enum.map(rows, & &1.group_id)),
     Enum.sum(Enum.map(rows, & &1.amount_cents))}
  end

  # Refresh each changed account once, including the addressed original group
  # even when its payment now funds only other reservations. Credit clawbacks
  # change lots, not the groups whose applied credit remains intact.
  defp refresh_affected(original, ids) do
    for id <- Enum.uniq(ids), id != original.group_id do
      id |> GroupStay.Reservations.get_group() |> refresh()
    end

    refresh(original)
  end

  defp payment_allocations(payment_id),
    do: Repo.all(from a in CashAllocation, where: a.payment_operation_id == ^payment_id)

  defp newest_first(rows), do: Enum.sort_by(rows, & &1.allocation_order, :desc)

  defp next_allocation_order do
    %{rows: [[id]]} =
      Repo.query!("UPDATE allocation_sequence SET value = value + 1 WHERE id = 1 RETURNING value")

    id
  end

  # Participation survives even after all allocations have settled or moved
  # back, so the expanded payment statement never loses its promised shape.
  def held_by_group(payment_id) do
    if Repo.exists?(
         from p in "transferred_payments", where: p.payment_operation_id == ^payment_id
       ) do
      rows =
        Repo.all(
          from a in CashAllocation,
            where: a.payment_operation_id == ^payment_id and a.disposition == "held",
            group_by: a.group_id,
            order_by: a.group_id,
            select: %{group_id: a.group_id, amount_cents: sum(a.amount_cents)}
        )

      %{held_by_group: rows}
    else
      %{}
    end
  end

  defp move(row, amount, disposition) when amount == row.amount_cents do
    Repo.update!(Ecto.Changeset.change(row, disposition: disposition))
  end

  defp move(row, amount, disposition) do
    Repo.update!(Ecto.Changeset.change(row, amount_cents: row.amount_cents - amount))

    Repo.insert!(%CashAllocation{
      group_id: row.group_id,
      room_id: row.room_id,
      allocation_order: row.allocation_order,
      payment_operation_id: row.payment_operation_id,
      amount_cents: amount,
      disposition: disposition
    })
  end

  def dispositions(payment_id) do
    from(a in CashAllocation, where: a.payment_operation_id == ^payment_id)
    |> query_totals()
  end

  def ledger do
    query_totals(CashAllocation)
    |> Map.new(fn {key, value} -> {Map.fetch!(@ledger_keys, key), value} end)
  end

  defp query_totals(query) do
    amounts =
      Repo.all(
        from a in query,
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    Map.new(@dispositions, fn {key, disposition} -> {key, Map.get(amounts, disposition, 0)} end)
  end

  defp totals(rows) do
    Map.new(@dispositions, fn {key, disposition} ->
      {key,
       rows
       |> Enum.filter(&(&1.disposition == disposition))
       |> Enum.map(& &1.amount_cents)
       |> Enum.sum()}
    end)
  end
end
