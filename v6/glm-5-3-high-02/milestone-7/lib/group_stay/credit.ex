defmodule GroupStay.Credit do
  @moduledoc """
  Guest hotel credit: lots issued by credit settlements, the entitlements
  that tie a lot back to the payments whose cash created it, the room
  allocations that fund group deposits with credit, and the credit
  liability and shortfall reported on the ledger.

  Credit application evaluates a lot's expiry as of the operation's
  `occurred_on` date. A lot is spendable strictly before `expires_on`.
  """

  import Ecto.Query

  alias GroupStay.Credit.Entitlement
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups
  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @held "held"
  @restored "restored"
  @consumed "consumed"
  @credit_bonus_percent 10
  @credit_validity_days 365

  @doc "Issues a new credit lot for a guest."
  def issue_lot(attrs) do
    %Lot{}
    |> Lot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lots the guest can still spend as of `as_of`, earliest expiry first and
  then by source operation identifier. Expired and exhausted lots are
  omitted.
  """
  def available_lots(guest_id, as_of) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of,
        order_by: [l.expires_on, l.source_operation_id]
    )
  end

  @doc "The guest-credit view returned by the read API."
  def credit_view(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  @doc """
  Credit that has not expired plus credit currently funding active groups.
  Applying or restoring credit therefore does not change the liability;
  expiry, non-refundable consumption, revoked entitlement, and restorations
  absorbed by a clawback reduce it.
  """
  def liability_cents(as_of) do
    remaining_cents =
      Repo.one(
        from l in Lot,
          where: l.expires_on > ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )
      |> normalize_sum()

    applied_cents =
      Repo.one(
        from a in Allocation,
          where: a.source == "credit" and a.state == ^@held,
          select: coalesce(sum(a.amount_cents), 0)
      )
      |> normalize_sum()

    remaining_cents + applied_cents
  end

  @doc """
  The current credit shortfall: for each lot, the lesser of its unrecovered
  clawback and credit from that lot still funding active groups.
  """
  def shortfall_cents do
    held_by_lot =
      Repo.all(
        from a in Allocation,
          where: a.source == "credit" and a.state == ^@held,
          group_by: a.lot_id,
          select: {a.lot_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Map.new(fn {lot_id, value} -> {lot_id, normalize_sum(value)} end)

    Repo.all(from l in Lot, where: l.unrecovered_clawback_cents > 0, select: l)
    |> Enum.map(fn lot ->
      min(lot.unrecovered_clawback_cents, Map.get(held_by_lot, lot.id, 0))
    end)
    |> Enum.sum()
  end

  @doc """
  Consumes `amount_cents` of the guest's unexpired credit into the group's
  deposit, taking from the earliest-expiring lots first and then by source
  operation identifier, and allocating it to the group's active rooms.
  Returns `{:error, :insufficient_credit}` when the guest cannot cover the
  amount, leaving the lots untouched.
  """
  def consume_for_group(%Group{} = group, amount_cents, as_of, operation_id) do
    lots = available_lots(group.guest_id, as_of)
    available = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available < amount_cents do
      {:error, :insufficient_credit}
    else
      tranches =
        lots
        |> draw_lots(amount_cents, [])
        |> Enum.map(fn {lot, take} ->
          %{
            group_id: group.id,
            source: "credit",
            operation_id: operation_id,
            lot_id: lot.id,
            amount_cents: take
          }
        end)

      with :ok <- Groups.allocate_funding(group, tranches) do
        now = utc_now()

        Enum.each(tranches, fn tranche ->
          from(l in Lot, where: l.id == ^tranche.lot_id)
          |> Repo.update_all(
            set: [
              remaining_cents: lot_remaining(tranche.lot_id) - tranche.amount_cents,
              updated_at: now
            ]
          )
        end)

        :ok
      end
    end
  end

  defp lot_remaining(lot_id) do
    Repo.one!(from l in Lot, where: l.id == ^lot_id, select: l.remaining_cents)
  end

  defp draw_lots(_lots, 0, acc), do: Enum.reverse(acc)

  defp draw_lots([lot | rest], remaining, acc) do
    take = min(lot.remaining_cents, remaining)
    draw_lots(rest, remaining - take, [{lot, take} | acc])
  end

  @doc """
  Issues the credit lot for a conversion settlement: the combined settled
  cash plus its 10% bonus, available through the day 365 days after the
  settlement. Each contributing payment's entitlement to the lot is the
  telescoped bonus value of the settled cash through it, in funding order.
  """
  def issue_conversion_lot(%Group{} = group, held_cash_allocations, occurred_on, operation_id) do
    total_cents = Enum.sum(Enum.map(held_cash_allocations, & &1.amount_cents))

    {:ok, lot} =
      issue_lot(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: bonus_value_cents(total_cents),
        # Available through the day 365 days after the settlement, expiring
        # the following day.
        expires_on: Date.add(occurred_on, @credit_validity_days + 1),
        unrecovered_clawback_cents: 0
      })

    record_entitlements(lot, held_cash_allocations)

    lot
  end

  # Contributors in funding order — the unattributed senior block first,
  # then each payment by its place in the room allocations — share the lot
  # by telescoped bonus value: each entitlement is the 10%-bonus value of
  # the settled cash through that payment minus the value through the
  # preceding one, with half-up rounding on both running totals.
  defp record_entitlements(lot, held_cash_allocations) do
    first_positions =
      held_cash_allocations
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {allocation, index}, positions ->
        Map.put_new(positions, allocation.operation_id, index)
      end)

    contributors =
      held_cash_allocations
      |> Enum.group_by(& &1.operation_id, & &1.amount_cents)
      |> Enum.map(fn {operation_id, amounts} -> {operation_id, Enum.sum(amounts)} end)
      |> Enum.sort_by(fn {operation_id, _amount} ->
        Map.get(first_positions, operation_id, -1)
      end)

    {entitlements, _cumulative, _previous_bonus} =
      Enum.reduce(contributors, {[], 0, 0}, fn {operation_id, amount},
                                               {acc, cumulative, previous_bonus} ->
        cumulative = cumulative + amount
        bonus_value = bonus_value_cents(cumulative)
        entitlement = bonus_value - previous_bonus

        acc =
          if operation_id != nil and entitlement > 0,
            do: [{operation_id, entitlement} | acc],
            else: acc

        {acc, cumulative, bonus_value}
      end)

    entitlements
    |> Enum.reverse()
    |> Enum.each(fn {operation_id, entitlement} ->
      %Entitlement{}
      |> Entitlement.changeset(%{
        lot_id: lot.id,
        payment_operation_id: operation_id,
        entitlement_cents: entitlement
      })
      |> Repo.insert!()
    end)

    :ok
  end

  @doc """
  Revokes a charged-back payment's entitlement from each lot it
  contributed to: removed from the lot's remaining balance first, the rest
  becoming that lot's unrecovered clawback. Returns
  `{entitlement_cents, removed_cents}` — the total entitlement and the
  part actually removed from unspent balances, which is the part that
  reduces the credit liability.
  """
  def claw_back_entitlements(payment_operation_id) do
    entitlements =
      Repo.all(
        from e in Entitlement,
          join: l in Lot,
          on: e.lot_id == l.id,
          where: e.payment_operation_id == ^payment_operation_id,
          order_by: l.id,
          select: {e, l}
      )

    removed_cents =
      entitlements
      |> Enum.map(fn {entitlement, lot} ->
        removed = min(entitlement.entitlement_cents, lot.remaining_cents)
        unrecovered = entitlement.entitlement_cents - removed
        now = utc_now()

        from(l in Lot, where: l.id == ^lot.id)
        |> Repo.update_all(
          set: [
            remaining_cents: lot.remaining_cents - removed,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered,
            updated_at: now
          ]
        )

        removed
      end)
      |> Enum.sum()

    entitlement_cents =
      entitlements |> Enum.map(fn {e, _lot} -> e.entitlement_cents end) |> Enum.sum()

    {entitlement_cents, removed_cents}
  end

  @doc "The bonus value of settled cash: the cash plus its 10% bonus."
  def bonus_value_cents(0), do: 0

  def bonus_value_cents(cash_cents) do
    # The 10% bonus uses the standard rounding rule: nearest cent, an exact
    # half-cent rounds upward.
    bonus_cents = div(cash_cents * @credit_bonus_percent + 50, 100)
    cash_cents + bonus_cents
  end

  # -- settlement ------------------------------------------------------------

  @doc """
  Settles credit allocations that stop funding their rooms: restored to
  their original lots (extinguishing an unrecovered clawback first) on a
  refundable settlement, or consumed without restoring on a non-refundable
  one.

  Returns the amount of credit liability that left through the
  settlement — the shortfall absorbed by restored lots, or the whole
  settled amount when consumed — for finance reporting.
  """
  def settle_allocations(allocations, :restore) do
    Enum.reduce(allocations, 0, fn allocation, absorbed ->
      absorbed + restore_allocation(allocation)
    end)
  end

  def settle_allocations(allocations, :consume) do
    now = utc_now()

    Enum.each(allocations, fn allocation ->
      from(a in Allocation, where: a.id == ^allocation.id)
      |> Repo.update_all(set: [state: @consumed, updated_at: now])
    end)

    Enum.sum(Enum.map(allocations, & &1.amount_cents))
  end

  defp restore_allocation(allocation) do
    lot = Repo.get!(Lot, allocation.lot_id)
    now = utc_now()

    # Credit returning to a shortfalled lot extinguishes the unrecovered
    # clawback before any amount becomes available again; only an excess
    # reaches the lot's remaining balance, where the existing expiry rules
    # decide whether it is available.
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

    from(l in Lot, where: l.id == ^lot.id)
    |> Repo.update_all(
      set: [
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + allocation.amount_cents - absorbed,
        updated_at: now
      ]
    )

    from(a in Allocation, where: a.id == ^allocation.id)
    |> Repo.update_all(set: [state: @restored, updated_at: now])

    absorbed
  end

  defp normalize_sum(nil), do: 0
  defp normalize_sum(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_sum(value) when is_integer(value), do: value

  defp utc_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
