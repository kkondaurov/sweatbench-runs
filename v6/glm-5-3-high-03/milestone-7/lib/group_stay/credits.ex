defmodule GroupStay.Credits do
  @moduledoc """
  The hotel credit domain: credit lots issued to guests, credit applied to
  group deposits, and the credit liability reported on the ledger.

  A lot is available through the day before its `expires_on` date: a lot
  issued for a cancellation is available through the date 365 days after the
  cancellation and expires the following day. While credit funds an active
  group its expiry is paused; the liability therefore counts both available
  credit and credit applied to active groups.

  A chargeback revokes the credit entitlement a converted payment created.
  The clawback removes the entitlement from the lot's remaining balance
  first; any entitlement that cannot be removed becomes the lot's unrecovered
  clawback. Credit returning to a shortfalled lot is absorbed by its
  unrecovered clawback before it becomes available or expires.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @credit_bonus_percent 10
  @credit_validity_days 365

  @doc """
  Issues a credit lot worth `cash_cents` plus a 10% bonus, rounded to the
  nearest cent with an exact half-cent rounding upward. The lot is available
  through the date 365 days after `cancelled_on` and expires the following day.
  """
  def issue_lot(guest_id, source_operation_id, cash_cents, cancelled_on) do
    bonus_cents = round_half_up(cash_cents * @credit_bonus_percent, 100)

    %CreditLot{}
    |> Ecto.Changeset.change(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: cash_cents + bonus_cents,
      expires_on: Date.add(cancelled_on, @credit_validity_days + 1)
    })
    |> Repo.insert!()
  end

  @doc """
  The guest's credit lots that still hold value and are unexpired as of
  `as_of`, ordered by earliest expiry, then by `source_operation_id`.
  """
  def available_lots(guest_id, as_of) do
    Repo.all(
      from l in CreditLot,
        where:
          l.guest_id == ^guest_id and l.remaining_cents > 0 and
            l.expires_on > ^as_of,
        order_by: [l.expires_on, l.source_operation_id]
    )
  end

  @doc """
  The guest's unexpired credit, in cents, as of `as_of`.
  """
  def available_cents(guest_id, as_of) do
    Repo.one(
      from l in CreditLot,
        where:
          l.guest_id == ^guest_id and l.remaining_cents > 0 and
            l.expires_on > ^as_of,
        select: sum(l.remaining_cents)
    )
    |> Kernel.||(0)
  end

  @doc """
  Builds the JSON representation of a guest's credit, omitting expired and
  exhausted lots.
  """
  def guest_credit_data(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" => Enum.map(lots, &lot_data/1)
    }
  end

  defp lot_data(%CreditLot{} = lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  @doc """
  Applies `amount_cents` of the guest's credit to the group's deposit,
  consuming lots by earliest expiry, then by `source_operation_id` for equal
  expiries. Expiry is evaluated as of the operation's `occurred_on` date.

  Returns the consumed amounts per lot, in consumption order, so room
  allocations can attribute the funding lot by lot.
  """
  def consume_for_group(%Group{} = group, amount_cents, occurred_on) do
    position = next_application_position(group.id)

    available_lots(group.guest_id, occurred_on)
    |> Enum.reduce_while({[], amount_cents, position}, fn lot, {consumed, remaining, position} ->
      taken = min(remaining, lot.remaining_cents)

      lot
      |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - taken})
      |> Repo.update!()

      %CreditApplication{}
      |> Ecto.Changeset.change(%{
        group_id: group.id,
        credit_lot_id: lot.id,
        amount_cents: taken,
        position: position
      })
      |> Repo.insert!()

      consumed = [%{lot_id: lot.id, amount_cents: taken} | consumed]

      if remaining - taken == 0 do
        {:halt, {consumed, 0, position + 1}}
      else
        {:cont, {consumed, remaining - taken, position + 1}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp next_application_position(group_id) do
    Repo.one(
      from a in CreditApplication,
        where: a.group_id == ^group_id,
        select: max(a.position)
    )
    |> Kernel.||(-1)
    |> Kernel.+(1)
  end

  @doc """
  The credit applications of a group, in their original consumption order,
  with their lots preloaded.
  """
  def applications_in_consumption_order(%Group{} = group) do
    Repo.all(
      from a in CreditApplication,
        where: a.group_id == ^group.id,
        order_by: a.position,
        preload: [:credit_lot]
    )
  end

  @doc """
  Restores amounts to their original credit lots. A lot with an unrecovered
  clawback absorbs the restoration first; only an excess then becomes
  available again, and only if the lot has not yet expired — a restored
  amount whose expiry is already past expires immediately instead.

  Returns, per restored lot, the amount absorbed by the lot's unrecovered
  clawback and the amount that expired immediately, so the daily finance
  report can classify both.
  """
  def restore_amounts(lot_amounts, occurred_on) do
    Enum.map(lot_amounts, fn {lot, amount_cents} ->
      absorbed = min(lot.unrecovered_clawback_cents, amount_cents)
      excess = amount_cents - absorbed

      expired? = Date.compare(lot.expires_on, occurred_on) != :gt

      remaining_cents =
        if excess > 0 and not expired? do
          lot.remaining_cents + excess
        else
          lot.remaining_cents
        end

      lot
      |> Ecto.Changeset.change(%{
        remaining_cents: remaining_cents,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      })
      |> Repo.update!()

      %{absorbed_cents: absorbed, expired_cents: if(expired?, do: excess, else: 0)}
    end)
  end

  @doc """
  Removes credit applications from a group for amounts that are no longer
  applied to it, either because they were restored to their lots or because
  they were consumed by a non-refundable settlement.
  """
  def remove_applications(%Group{} = group, lot_amounts) do
    Enum.each(lot_amounts, fn {lot, amount_cents} ->
      applications =
        Repo.all(
          from a in CreditApplication,
            where: a.group_id == ^group.id and a.credit_lot_id == ^lot.id,
            order_by: a.position
        )

      remove_from_applications(applications, amount_cents)
    end)
  end

  @doc """
  Moves applied credit between two active groups of the same guest: the
  amounts leave the source group's applications and become applications of
  the destination group, in their original lots. The credit stays applied —
  its expiry stays paused — and the credit liability is unchanged.
  """
  def move_applications(%Group{} = source, %Group{} = destination, lot_amounts) do
    Enum.each(lot_amounts, fn {lot_id, amount_cents} ->
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^source.id and a.credit_lot_id == ^lot_id,
          order_by: a.position
      )
      |> remove_from_applications(amount_cents)

      %CreditApplication{}
      |> Ecto.Changeset.change(%{
        group_id: destination.id,
        credit_lot_id: lot_id,
        amount_cents: amount_cents,
        position: next_application_position(destination.id)
      })
      |> Repo.insert!()
    end)
  end

  defp remove_from_applications([], 0), do: :ok

  defp remove_from_applications([], remaining) do
    raise "cannot remove #{remaining} cents of credit applications that do not exist"
  end

  defp remove_from_applications([application | rest], remaining) do
    taken = min(application.amount_cents, remaining)

    cond do
      taken == application.amount_cents ->
        Repo.delete!(application)

      taken > 0 ->
        application
        |> Ecto.Changeset.change(%{amount_cents: application.amount_cents - taken})
        |> Repo.update!()

      true ->
        :ok
    end

    remove_from_applications(rest, remaining - taken)
  end

  @doc """
  Revokes a credit entitlement from a lot: the clawback removes it from the
  lot's remaining balance first, and any entitlement that cannot be removed
  becomes the lot's unrecovered clawback.

  When reporting has started (`posting_date` given), the portion taken from a
  lot that had already expired by the posting date left the liability through
  that lot's expiry; it is tracked against the lot so the daily report counts
  it with the expiry instead of as a revocation. Returns the amount revoked
  from the current liability.
  """
  def revoke_entitlement(%CreditLot{} = lot, entitlement_cents, posting_date \\ nil) do
    taken = min(entitlement_cents, lot.remaining_cents)

    expired_take =
      if posting_date != nil and Date.compare(lot.expires_on, posting_date) != :gt do
        taken
      else
        0
      end

    lot
    |> Ecto.Changeset.change(%{
      remaining_cents: lot.remaining_cents - taken,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + (entitlement_cents - taken),
      clawed_back_expired_cents: lot.clawed_back_expired_cents + expired_take
    })
    |> Repo.update!()

    %{revoked_cents: taken - expired_take}
  end

  @doc """
  The current credit shortfall: for each lot, the lesser of its unrecovered
  clawback and credit from that lot still applied to active groups.
  """
  def credit_shortfall_cents do
    applied_by_lot =
      from a in CreditApplication,
        join: g in Group,
        on: g.id == a.group_id,
        where: g.status == "active",
        group_by: a.credit_lot_id,
        select: %{lot_id: a.credit_lot_id, total: sum(a.amount_cents)}

    Repo.one(
      from l in CreditLot,
        join: s in subquery(applied_by_lot),
        on: s.lot_id == l.id,
        select: sum(fragment("MIN(?, ?)", l.unrecovered_clawback_cents, s.total))
    )
    |> Kernel.||(0)
  end

  @doc """
  The credit liability as of `as_of`: available credit plus credit currently
  applied to active groups. Applying or restoring credit does not change it;
  expiry, non-refundable consumption, revoked entitlement, and restorations
  absorbed by a shortfall reduce it.
  """
  def credit_liability_cents(as_of) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on > ^as_of,
          select: sum(l.remaining_cents)
      )
      |> Kernel.||(0)

    applied_to_active_groups =
      Repo.one(
        from a in CreditApplication,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          select: sum(a.amount_cents)
      )
      |> Kernel.||(0)

    available + applied_to_active_groups
  end

  # Rounds numerator / denominator to the nearest cent; an exact half-cent
  # rounds upward. Integer arithmetic keeps the rounding exact.
  defp round_half_up(numerator, denominator) do
    div(2 * numerator + denominator, 2 * denominator)
  end
end
