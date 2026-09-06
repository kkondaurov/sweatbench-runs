defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit issued by refundable cancellations and later applied to new
  reservations.

  Credit lives in per-guest lots created by a cancellation (`source_operation_id`),
  worth 110% of the cash it replaces, available through 365 days after that
  cancellation and expiring the following day. Applying credit redeems it
  into the active deposit: its expiry is paused while it funds that group,
  because the funding link records which original lot holds the amount.
  A refundable cancellation restores those amounts to their original lots;
  a non-refundable cancellation consumes them.
  """

  import Ecto.Query

  alias GroupStay.Credit.Funding
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @availability_days 365

  @doc """
  The date through which a lot issued by a cancellation on `cancelled_on`
  is available; it expires the following day.
  """
  def availability_limit(%Date{} = cancelled_on), do: Date.add(cancelled_on, @availability_days)

  def expires_on(%Date{} = cancelled_on), do: Date.add(availability_limit(cancelled_on), 1)

  @doc """
  Issues a credit lot worth `amount_cents`, applying the standard rounding
  rule to the 10% bonus over the cash-funded portion. Zero amounts issue no
  lot.
  """
  def issue_lot(nil, _source_operation_id, _cash_cents, _cancelled_on), do: {0, nil}

  def issue_lot(guest_id, source_operation_id, cash_cents, cancelled_on)
      when is_integer(cash_cents) and cash_cents > 0 do
    amount_cents = bonus_value(cash_cents)

    {:ok, lot} =
      %Lot{}
      |> Lot.changeset(%{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount_cents,
        expires_on: expires_on(cancelled_on)
      })
      |> Repo.insert()

    {amount_cents, lot}
  end

  def issue_lot(_guest_id, _source_operation_id, _cash_cents, _cancelled_on),
    do: {0, nil}

  @doc """
  The standard rounding rule applied to the 10% bonus: the cash plus its
  half-up-rounded tenth.
  """
  def bonus_value(cash_cents), do: div(cash_cents * 110 + 50, 100)

  @doc """
  The guest's unexpired, unexhausted lots ordered by earliest expiry, then
  `source_operation_id`.
  """
  def available_lots(guest_id, as_of) do
    from(l in Lot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  def available_cents(guest_id, as_of) do
    available_cents(available_lots(guest_id, as_of))
  end

  def available_cents(lots) when is_list(lots) do
    Enum.reduce(lots, 0, &(&1.remaining_cents + &2))
  end

  @doc """
  Redeems `amount_cents` of the guest's unexpired credit into the group's
  deposit, consuming lots earliest-expiry first and recording which lot
  funded the group. Returns `{:ok, fundings}` or `{:error, :insufficient_credit}`.
  """
  def apply_to_group(%Group{} = group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    if available_cents(lots) < amount_cents do
      {:error, :insufficient_credit}
    else
      {:ok, take_from_lots(lots, amount_cents, group)}
    end
  end

  @doc """
  Credit currently applied to the group's deposit across its funding links.
  """
  def applied_cents(group_id) do
    from(f in Funding, where: f.group_id == ^group_id, select: coalesce(sum(f.amount_cents), 0))
    |> Repo.one()
  end

  @doc """
  Restores every amount the group's funding links hold back onto their
  original lots with their original expiry.
  """
  def restore_for_group(group_id) do
    fundings =
      from(f in Funding, where: f.group_id == ^group_id)
      |> Repo.all()

    Enum.each(fundings, fn funding ->
      {1, _} =
        from(l in Lot, where: l.id == ^funding.credit_lot_id)
        |> Repo.update_all(inc: [remaining_cents: funding.amount_cents])

      Repo.delete!(funding)
    end)

    :ok
  end

  @doc """
  Consumes every amount the group's funding links hold without restoring
  them: non-refundable cancellations forfeit applied credit.
  """
  def consume_for_group(group_id) do
    from(f in Funding, where: f.group_id == ^group_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Total credit liability as of `as_of`: unexpired available credit plus all
  credit currently applied to active groups — applying credit redeems it out
  of its lot, pausing expiry while it funds the group. Applying or restoring
  credit therefore leaves the liability unchanged unless a restored lot has
  already expired; expiry of available lots and non-refundable consumption
  reduce it.
  """
  def liability_cents(as_of) do
    available =
      from(l in Lot, where: l.expires_on > ^as_of, select: coalesce(sum(l.remaining_cents), 0))
      |> Repo.one()

    applied =
      from(f in Funding,
        join: g in Group,
        on: g.id == f.group_id,
        where: g.status == "active",
        select: coalesce(sum(f.amount_cents), 0)
      )
      |> Repo.one()

    available + applied
  end

  defp take_from_lots(lots, amount_cents, group) do
    Enum.map_reduce(lots, amount_cents, fn lot, remaining ->
      if remaining <= 0 do
        {nil, remaining}
      else
        taken = min(lot.remaining_cents, remaining)

        {1, _} =
          from(l in Lot, where: l.id == ^lot.id)
          |> Repo.update_all(inc: [remaining_cents: -taken])

        {:ok, funding} =
          %Funding{}
          |> Funding.changeset(%{
            group_id: group.id,
            credit_lot_id: lot.id,
            amount_cents: taken
          })
          |> Repo.insert()

        {funding, remaining - taken}
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end
end
