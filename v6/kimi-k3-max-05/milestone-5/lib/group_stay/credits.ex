defmodule GroupStay.Credits do
  @moduledoc """
  Hotel credit lots and their application to group deposits.

  A lot is created when a refundable cancellation settles into hotel credit.
  Its value funds later deposits: while applied to an active group the amount
  is paused (expiry cannot bite), and a refundable cancellation restores it to
  the original lot. A lot's available balance is what remains unapplied and
  unexpired as of a given date.

  Each lot records the per-payment entitlements of the cash that was converted
  into it. A chargeback revokes the payment's entitlement: what cannot be
  removed from the lot's remaining balance becomes unrecovered clawback, which
  later restorations extinguish before any credit becomes available again.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Credits.CreditEntitlement
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Money
  alias GroupStay.Repo

  @doc """
  Issues a credit lot for a guest, sourced from the cancellation operation
  that created it. `contributions` are the `{payment_operation_id, cash}` that
  was converted, in funding order (the unattributed senior block, `nil`,
  first); each payment's entitlement is its slice of the lot's bonus value so
  the entitlements telescope exactly to the issued amount.
  """
  def create_lot(attrs, contributions \\ []) do
    lot =
      %CreditLot{}
      |> cast(attrs, [:guest_id, :source_operation_id, :amount_cents, :expires_on])
      |> validate_required([:guest_id, :source_operation_id, :amount_cents, :expires_on])
      |> Repo.insert!()

    {entitlements, _cash} =
      Enum.map_reduce(contributions, 0, fn {payment_operation_id, cash}, settled ->
        entitlement = Money.credit_value(settled + cash) - Money.credit_value(settled)
        {{payment_operation_id, entitlement}, settled + cash}
      end)

    entitlements
    |> Enum.with_index()
    |> Enum.each(fn {{payment_operation_id, entitlement}, position} ->
      %CreditEntitlement{}
      |> change(
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        amount_cents: entitlement,
        position: position
      )
      |> Repo.insert!()
    end)

    lot
  end

  @doc """
  The guest's credit position as of the given date: total available credit and
  the live lots, ordered by expiry and then source operation. Expired and
  exhausted lots are omitted.
  """
  def guest_credit(guest_id, on_date) do
    redeemable = redeemable_lots(guest_id, on_date)

    %{
      "guest_id" => guest_id,
      "available_cents" => available_from(redeemable),
      "lots" =>
        Enum.map(redeemable, fn {lot, remaining} ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => remaining,
            "expires_on" => Date.to_string(lot.expires_on)
          }
        end)
    }
  end

  @doc """
  The credit the guest can spend on the given date: unapplied balances of
  unexpired lots.
  """
  def available_cents(guest_id, on_date) do
    available_from(redeemable_lots(guest_id, on_date))
  end

  @doc """
  Redeems the guest's credit into the group's deposit, consuming lots by
  earliest expiry and then by source operation while filling the rooms in
  their original order. The caller guarantees the guest has enough available
  credit and that the amount fits the rooms.
  """
  def consume(guest_id, amount_cents, on_date, %Group{} = group, rooms) do
    lots = redeemable_lots(guest_id, on_date)

    {_lots, _needed} =
      Enum.reduce(rooms, {lots, amount_cents}, fn room, {lots, needed} ->
        need = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        take = min(needed, max(need, 0))
        {lots, shares} = draw(lots, take)

        Enum.each(shares, fn {lot, share} ->
          %CreditApplication{}
          |> cast(
            %{
              credit_lot_id: lot.id,
              group_id: group.id,
              room_id: room.id,
              amount_cents: share,
              allocation_seq: Funding.next_allocation_seq!()
            },
            [:credit_lot_id, :group_id, :room_id, :amount_cents, :allocation_seq]
          )
          |> Repo.insert!()

          bump_room!(room, share)
        end)

        taken = Enum.sum(Enum.map(shares, fn {_lot, share} -> share end))
        {lots, needed - taken}
      end)

    :ok
  end

  # Takes `amount` from the redeemable lots in order, returning the remaining
  # lots and the per-lot shares taken.
  defp draw(lots, amount) do
    {lots, {taken, _needed}} =
      Enum.map_reduce(lots, {[], amount}, fn {lot, remaining}, {taken, needed} ->
        take = min(needed, remaining)

        if take > 0 do
          {{lot, remaining - take}, {taken ++ [{lot, take}], needed - take}}
        else
          {{lot, remaining}, {taken, needed}}
        end
      end)

    {lots, taken}
  end

  @doc """
  Returns the given credit applications to their original lots, where they
  keep their original expiry. Returned credit first extinguishes any
  unrecovered clawback on the lot; only the excess becomes available again
  (or expires under the existing rules).
  """
  def restore_applications(applications) do
    Enum.each(applications, fn application ->
      lot = Repo.get!(CreditLot, application.credit_lot_id)
      absorbed = min(application.amount_cents, lot.unrecovered_clawback_cents)

      if absorbed > 0 do
        lot
        |> change(
          amount_cents: lot.amount_cents - absorbed,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
        )
        |> Repo.update!()
      end

      Repo.delete!(application)
    end)

    :ok
  end

  @doc """
  Permanently consumes the given credit applications (a non-refundable
  settlement): the lots shrink by the applied amounts so the credit is never
  available again.
  """
  def consume_applications(applications) do
    Enum.each(applications, fn application ->
      lot = Repo.get!(CreditLot, application.credit_lot_id)

      lot
      |> change(amount_cents: lot.amount_cents - application.amount_cents)
      |> Repo.update!()

      Repo.delete!(application)
    end)

    :ok
  end

  @doc """
  Revokes every entitlement the payment created. Each entitlement is removed
  from its lot's remaining balance first; whatever cannot be removed becomes
  that lot's unrecovered clawback.
  """
  def clawback_entitlements(payment_operation_id) do
    entitlements =
      Repo.all(
        from e in CreditEntitlement,
          where: e.payment_operation_id == ^payment_operation_id,
          order_by: [asc: e.id]
      )

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      applied = applied_by_lot([lot.id])[lot.id] || 0
      remaining = max(lot.amount_cents - applied, 0)
      removed = min(entitlement.amount_cents, remaining)

      lot
      |> change(
        amount_cents: lot.amount_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      )
      |> Repo.update!()

      Repo.delete!(entitlement)
    end)

    :ok
  end

  @doc """
  The credit applications funding the given rooms.
  """
  def applications_on_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from a in CreditApplication,
        where: a.room_id in ^room_ids,
        order_by: [asc: a.id]
    )
  end

  @doc """
  The current credit shortfall: for each lot, the lesser of its unrecovered
  clawback and the credit from that lot still applied to active groups.
  """
  def shortfall_cents do
    lots = Repo.all(CreditLot)
    applied = applied_by_lot(Enum.map(lots, & &1.id))

    Enum.sum(
      Enum.map(lots, fn lot ->
        min(lot.unrecovered_clawback_cents, Map.get(applied, lot.id, 0))
      end)
    )
  end

  @doc """
  The outstanding credit liability as of the given date: available credit plus
  credit paused inside active deposits. Applied credit counts even when its
  lot has expired, because expiry is paused while it funds a group, and even
  when it is covered by a current shortfall.
  """
  def liability_cents(on_date) do
    lots = Repo.all(CreditLot)
    applied = applied_by_lot(Enum.map(lots, & &1.id))

    Enum.sum(
      Enum.map(lots, fn lot ->
        if Date.compare(on_date, lot.expires_on) == :gt do
          Map.get(applied, lot.id, 0)
        else
          lot.amount_cents
        end
      end)
    )
  end

  defp available_from(redeemable) do
    Enum.sum(Enum.map(redeemable, fn {_lot, remaining} -> remaining end))
  end

  # Unexpired lots with an unapplied balance, in consumption order.
  defp redeemable_lots(guest_id, on_date) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.expires_on >= ^on_date,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    applied = applied_by_lot(Enum.map(lots, & &1.id))

    lots
    |> Enum.map(fn lot -> {lot, lot.amount_cents - Map.get(applied, lot.id, 0)} end)
    |> Enum.filter(fn {_lot, remaining} -> remaining > 0 end)
  end

  defp applied_by_lot(lot_ids) do
    from(a in CreditApplication,
      where: a.credit_lot_id in ^lot_ids,
      group_by: a.credit_lot_id,
      select: {a.credit_lot_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp bump_room!(%Room{} = room, credit_delta) do
    Repo.update_all(
      from(r in Room, where: r.id == ^room.id),
      inc: [credit_paid_cents: credit_delta]
    )
  end
end
