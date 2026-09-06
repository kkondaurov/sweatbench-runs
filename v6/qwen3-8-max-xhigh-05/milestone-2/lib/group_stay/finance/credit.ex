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
  consumes it.
  """

  import Ecto.Query

  alias GroupStay.Finance.CreditApplication
  alias GroupStay.Finance.CreditLot
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
  """
  def issue_lot(guest_id, source_operation_id, amount_cents, issued_on)
      when is_integer(amount_cents) and amount_cents > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    fields = %{
      id: Ecto.UUID.generate(),
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expiry_for(issued_on),
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(CreditLot, [fields])
    :ok
  end

  def issue_lot(_guest_id, _source_operation_id, amount_cents, _issued_on)
      when amount_cents <= 0,
      do: :ok

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
  Applies the requested amount of the guest's credit to the group, consuming
  lots by earliest expiry (then source operation) and recording which lots
  funded the group.

  Returns `:ok`, or `{:error, :insufficient_credit}` when the guest cannot
  cover the amount.
  """
  def apply_to_group(group, guest_id, amount_cents, on_date) do
    lots = available_lots(guest_id, on_date)

    case allocate(lots, amount_cents, []) do
      {:ok, allocations} ->
        record_allocations(group, allocations)
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

  defp record_allocations(group, allocations) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(allocations, fn {lot, amount_cents} ->
      update_lot_remaining(lot, -amount_cents)

      Repo.insert_all(CreditApplication, [
        %{
          id: Ecto.UUID.generate(),
          group_id: group.id,
          lot_id: lot.id,
          amount_cents: amount_cents,
          status: "active",
          inserted_at: now,
          updated_at: now
        }
      ])
    end)
  end

  @doc """
  Restores the credit funding the group to its original lots.

  Amounts whose lot expiry is already past on the given date expire
  immediately instead of becoming available again.
  """
  def restore_for_group(group, on_date) do
    group
    |> active_applications()
    |> Enum.each(fn application ->
      lot = Repo.get!(CreditLot, application.lot_id)

      if Date.compare(lot.expires_on, on_date) != :lt do
        update_lot_remaining(lot, application.amount_cents)
      end

      mark_application(application, "restored")
    end)

    :ok
  end

  @doc """
  Consumes the credit funding the group: it is neither restored nor refunded.
  """
  def consume_for_group(group) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(a in CreditApplication, where: a.group_id == ^group.id and a.status == "active"),
      set: [status: "consumed", updated_at: now]
    )

    :ok
  end

  @doc """
  Returns the credit liability in cents as of the given date: available
  credit plus credit currently applied to active groups.
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
        from a in CreditApplication,
          where: a.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + applied
  end

  defp active_applications(group) do
    Repo.all(
      from a in CreditApplication,
        where: a.group_id == ^group.id and a.status == "active",
        order_by: [asc: a.inserted_at]
    )
  end

  defp update_lot_remaining(lot, delta) do
    {1, _} =
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [remaining_cents: delta]
      )

    :ok
  end

  defp mark_application(application, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(a in CreditApplication, where: a.id == ^application.id),
      set: [status: status, updated_at: now]
    )

    :ok
  end
end
