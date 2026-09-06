defmodule GroupStay.Finance.Credit do
  @moduledoc """
  Hotel credit issued to guests and applied to group deposits.

  A credit lot is available through its `expires_on` date and expires the
  following day. Expiry is always evaluated against a specific date: the
  read endpoints use their `on` parameter (or the current UTC date), and
  credit application uses the operation's `occurred_on` date.

  Applying credit to a group redeems it into the active deposit, pausing its
  expiry while it funds that group. A refundable cancellation restores the
  amount to its original lot and expiry; a non-refundable cancellation
  consumes it. When a lot carries unrecovered clawback from a chargeback,
  restored credit extinguishes that clawback before becoming available.
  """

  import Ecto.Query

  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Finance.RoomAllocations
  alias GroupStay.Repo

  @validity_days 365

  @doc """
  Returns the date on which credit issued on the given date expires. The lot
  is available through that date and expires the following day.
  """
  def expiry_for(issued_on) do
    Date.add(issued_on, @validity_days)
  end

  @doc """
  Issues a new credit lot for the guest, funded by the given settlement.

  Returns `{:ok, lot_id}`, or `{:ok, nil}` when there is nothing to issue.
  """
  def issue_lot(guest_id, source_operation_id, amount_cents, issued_on)
      when is_integer(amount_cents) and amount_cents > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    lot_id = Ecto.UUID.generate()

    fields = %{
      id: lot_id,
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expiry_for(issued_on),
      unrecovered_clawback_cents: 0,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(CreditLot, [fields])
    {:ok, lot_id}
  end

  def issue_lot(_guest_id, _source_operation_id, amount_cents, _issued_on)
      when amount_cents <= 0,
      do: {:ok, nil}

  @doc """
  Returns the guest's available lots as of the given date: unexpired lots
  with remaining credit, ordered by expiry and then source operation.
  """
  def available_lots(guest_id, on_date) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on_date,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the guest's total available credit in cents as of the given date.
  """
  def available_cents(guest_id, on_date) do
    guest_id
    |> available_lots(on_date)
    |> Enum.reduce(0, &(&1.remaining_cents + &2))
  end

  @doc """
  Applies the requested amount of the guest's credit to the group's rooms,
  consuming lots by earliest expiry (then source operation) and filling the
  rooms in their original order.

  Returns `:ok`, or `{:error, :insufficient_credit}` when the guest cannot
  cover the amount.
  """
  def apply_to_group(rooms, guest_id, amount_cents, on_date, funding_operation_id) do
    lots = available_lots(guest_id, on_date)

    case allocate(lots, amount_cents, []) do
      {:ok, consumes} ->
        Enum.each(consumes, fn {lot, taken} -> update_lot_remaining(lot, -taken) end)

        segments = Enum.map(consumes, fn {lot, taken} -> {lot.id, taken} end)

        rooms
        |> RoomAllocations.fill_credit_rows(segments, funding_operation_id)
        |> RoomAllocations.insert_fill("credit")

        :ok

      :error ->
        {:error, :insufficient_credit}
    end
  end

  defp allocate(_lots, 0, acc), do: {:ok, Enum.reverse(acc)}
  defp allocate([], _remaining, _acc), do: :error

  defp allocate([lot | lots], remaining, acc) do
    take = min(lot.remaining_cents, remaining)
    allocate(lots, remaining - take, [{lot, take} | acc])
  end

  @doc """
  Restores the credit funding the rooms to its original lots.

  Restored credit extinguishes unrecovered clawback on the lot before any
  amount becomes available. This absorption happens before checking the
  lot's expiry; only an excess becomes available, or expires when the lot's
  expiry is already past on the given date.
  """
  def restore_rooms(rooms, on_date) do
    rooms
    |> Enum.map(& &1.id)
    |> RoomAllocations.held()
    |> Enum.filter(&(&1.kind == "credit"))
    |> Enum.each(&restore_allocation(&1, on_date))

    :ok
  end

  defp restore_allocation(allocation, on_date) do
    lot = Repo.get!(CreditLot, allocation.lot_id)

    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

    if absorbed > 0 do
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [unrecovered_clawback_cents: -absorbed]
      )
    end

    available = allocation.amount_cents - absorbed

    if available > 0 and Date.compare(lot.expires_on, on_date) != :lt do
      update_lot_remaining(lot, available)
    end

    mark_allocation(allocation, "restored")
  end

  @doc """
  Consumes the credit funding the rooms: it is neither restored nor refunded.
  """
  def consume_rooms(rooms) do
    RoomAllocations.mark_held(Enum.map(rooms, & &1.id), "credit", "consumed")
  end

  @doc """
  Returns the credit liability in cents as of the given date: available
  credit plus credit currently applied to active groups, including credit
  covered by a current shortfall.
  """
  def liability_cents(on_date) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on_date,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in RoomAllocation,
          where: a.kind == "credit" and a.status == "held",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + applied
  end

  @doc """
  Returns the current credit shortfall in cents: for each lot carrying
  unrecovered clawback, the lesser of that clawback and the lot's credit
  still applied to active groups.
  """
  def shortfall_cents do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, acc ->
      applied =
        Repo.one(
          from a in RoomAllocation,
            where: a.lot_id == ^lot.id and a.kind == "credit" and a.status == "held",
            select: coalesce(sum(a.amount_cents), 0)
        )

      acc + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp update_lot_remaining(lot, delta) do
    {1, _} =
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [remaining_cents: delta]
      )

    :ok
  end

  defp mark_allocation(allocation, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(a in RoomAllocation, where: a.id == ^allocation.id),
      set: [status: status, updated_at: now]
    )

    :ok
  end
end
