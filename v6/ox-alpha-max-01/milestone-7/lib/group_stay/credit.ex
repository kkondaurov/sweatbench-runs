defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit issued by refundable cancellations and later applied to new
  reservations.

  Credit lives in per-guest lots created by a cancellation (`source_operation_id`),
  worth 110% of the cash it replaces, available through 365 days after that
  cancellation and expiring the following day. Applying credit redeems it
  into active rooms' deposits: its expiry is paused while it funds those
  rooms, because the room fundings record which original lot holds each
  amount. A refundable cancellation restores those amounts to their original
  lots; a non-refundable cancellation consumes them.

  When a charged-back payment's converted cash sits inside a lot, its bonus
  entitlement is revoked from the lot's remaining balance first; anything
  unremovable becomes the lot's unrecovered clawback, tracked per lot.
  """

  import Ecto.Query

  alias GroupStay.Credit.Entitlement
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance
  alias GroupStay.Groups.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Fundings
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
  Issues one lot for cash settled out of several funding sources.

  `sources` are `{operation_id_or_nil, settled_cash}` pairs in the funding
  order used by room accounting — the unattributed senior block first, then
  durable payments in commit order. Each payment's entitlement is the
  half-up-rounded bonus over the running settled cash through that payment
  minus the bonus through the preceding source, so entitlements telescope
  into the issued lot. Legacy sources have no operation identity and earn no
  entitlement, but they still advance the running total.
  """
  def issue_lot_for_sources(guest_id, source_operation_id, sources, cancelled_on) do
    combined_cash = Enum.sum(Enum.map(sources, fn {_op, cents} -> cents end))

    {issued, lot} = issue_lot(guest_id, source_operation_id, combined_cash, cancelled_on)

    if lot do
      Enum.reduce(sources, 0, fn {operation_id, cents}, running ->
        after_running = running + cents

        if operation_id do
          cents_entitled = bonus_value(after_running) - bonus_value(running)

          if cents_entitled > 0 do
            {:ok, _} =
              %Entitlement{}
              |> Entitlement.changeset(%{
                credit_lot_id: lot.id,
                payment_operation_id: operation_id,
                cents: cents_entitled
              })
              |> Repo.insert()
          end
        end

        after_running
      end)
    end

    {issued, lot}
  end

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
  active rooms' deposits, consuming lots earliest-expiry first and recording
  which lot funds which room. The funding rows carry the durable
  `apply_hotel_credit` operation that redeemed them. Returns the inserted
  fundings, or `{:error, :insufficient_credit}`.
  """
  def apply_to_group(%Group{} = group, amount_cents, occurred_on, operation_id \\ nil) do
    lots = available_lots(group.guest_id, occurred_on)

    if available_cents(lots) < amount_cents do
      {:error, :insufficient_credit}
    else
      slices = take_from_lots(lots, amount_cents)
      posting = Finance.posting(occurred_on)

      chunks =
        Enum.map(slices, fn {lot, taken} ->
          # Applying credit pauses expiry without changing the liability; the
          # movement row exists so the lot's later expiry can be derived.
          Finance.record_credit(posting, lot.id, :applied, taken)

          %{operation_id: operation_id, credit_lot_id: lot.id, amount: taken}
        end)

      # The caller validates the amount against the outstanding deposit
      # before this point, so every chunk finds room-capacity to fill.
      Fundings.allocate_credit(group, chunks)
    end
  end

  @doc """
  Takes `amount_cents` from lots in their given (earliest-expiry-first)
  order, returning `{lot, taken}` slices totalling exactly the amount.
  """
  def take_from_lots(lots, amount_cents) do
    Enum.map_reduce(lots, amount_cents, fn lot, remaining ->
      if remaining <= 0 do
        {nil, remaining}
      else
        taken = min(lot.remaining_cents, remaining)

        {1, _} =
          from(l in Lot, where: l.id == ^lot.id)
          |> Repo.update_all(inc: [remaining_cents: -taken])

        {{lot, taken}, remaining - taken}
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Restores funded amounts onto their original lots.

  Any unrecovered clawback on a lot absorbs the restoration before anything
  else — ahead of the expiry check — so only an excess becomes balance that
  may then be available or dead under the existing expiry rules. Reporting
  records the absorbed portion as liability leaving and the rest as either
  available again or, on a lot whose expiry has passed, expiring at once.
  """
  def restore_fundings(fundings, posting \\ {nil, false}) do
    {posting_date, _late?} = posting

    Enum.each(fundings, fn funding ->
      lot = Repo.get!(Lot, funding.credit_lot_id)
      absorbed = min(lot.clawback_cents, funding.amount_cents)
      restored = funding.amount_cents - absorbed

      Finance.record_credit(posting, lot.id, :absorbed_cents, absorbed)

      expired_destination? =
        posting_date != nil and Date.compare(lot.expires_on, posting_date) != :gt

      if expired_destination? do
        Finance.record_credit(posting, lot.id, :expired_cents, restored)
      else
        Finance.record_credit(posting, lot.id, :restored, restored)
      end

      {1, _} =
        from(l in Lot, where: l.id == ^lot.id)
        |> Repo.update_all(inc: [clawback_cents: -absorbed, remaining_cents: restored])

      Repo.delete!(funding)
    end)

    :ok
  end

  @doc """
  Consumes funded amounts without restoring them: non-refundable
  cancellations forfeit applied credit. The consumed amounts leave the
  credit liability even when their lot has already expired, because applied
  credit's expiry stays paused while it funds active rooms.
  """
  def consume_fundings(fundings, posting \\ {nil, false}) do
    Enum.each(fundings, fn funding ->
      Finance.record_credit(posting, funding.credit_lot_id, :consumed_cents, funding.amount_cents)
    end)

    Repo.delete_all(from(f in Funding, where: f.id in ^Enum.map(fundings, & &1.id)))
    :ok
  end

  @doc """
  Total credit liability as of `as_of`: unexpired available credit plus all
  credit currently applied to active groups — applying credit redeems it out
  of its lot, pausing expiry while it funds those rooms. Applying or
  restoring credit therefore leaves the liability unchanged unless a
  restored lot has already expired or a restoration was absorbed by a
  shortfall; expiry of available lots and non-refundable consumption reduce
  it, as does revoking unspent entitlement.
  """
  def liability_cents(as_of) do
    available =
      from(l in Lot, where: l.expires_on > ^as_of, select: coalesce(sum(l.remaining_cents), 0))
      |> Repo.one()

    available + Fundings.applied_to_active_groups()
  end

  @doc """
  Current credit shortfall: per lot, the lesser of its unrecovered clawback
  and that lot's credit still applied to active groups, summed over all
  lots. Non-refundable settlement shrinks it automatically because consumed
  credit no longer counts as applied to an active group.
  """
  def shortfall_cents do
    from(l in Lot, where: l.clawback_cents > 0, select: l.id)
    |> Repo.all()
    |> Enum.reduce(0, fn lot_id, total ->
      lot = Repo.get!(Lot, lot_id)
      applied = Fundings.lot_applied_to_active_groups(lot.id)
      total + min(lot.clawback_cents, applied)
    end)
  end

  @doc """
  Revokes a charged-back payment's entitlements across every lot it helped
  convert. Each entitlement is removed from its lot's remaining balance
  first; whatever cannot be removed becomes that lot's unrecovered clawback.

  Only a removal from an unexpired lot's balance reduces the credit
  liability, so that is what reporting records as revoked; clawing back dead
  (already expired) balance leaves no movement.
  """
  def claw_back_entitlements(payment_operation_id, posting \\ {nil, false}) do
    {posting_date, _late?} = posting

    entitlements =
      from(e in Entitlement, where: e.payment_operation_id == ^payment_operation_id)
      |> Repo.all()

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(Lot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.cents)
      unrecovered = entitlement.cents - removed

      if posting_date != nil and removed > 0 and
           Date.compare(lot.expires_on, posting_date) == :gt do
        Finance.record_credit(posting, lot.id, :revoked_cents, removed)
      end

      {1, _} =
        from(l in Lot, where: l.id == ^lot.id)
        |> Repo.update_all(inc: [remaining_cents: -removed, clawback_cents: unrecovered])
    end)

    :ok
  end
end
