defmodule GroupStay.Credits do
  @moduledoc """
  The hotel credit domain: credit lots issued to guests, credit applied to
  group deposits, and the credit liability reported on the ledger.

  A lot is available through the day before its `expires_on` date: a lot
  issued for a cancellation is available through the date 365 days after the
  cancellation and expires the following day. While credit funds an active
  group its expiry is paused; the liability therefore counts both available
  credit and credit applied to active groups.
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
  """
  def consume_for_group(%Group{} = group, amount_cents, occurred_on) do
    available_lots(group.guest_id, occurred_on)
    |> Enum.reduce_while({[], amount_cents}, fn lot, {applied, remaining} ->
      taken = min(remaining, lot.remaining_cents)

      lot
      |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - taken})
      |> Repo.update!()

      applied = [
        %{lot: lot, amount_cents: taken} | applied
      ]

      if remaining - taken == 0 do
        {:halt, {applied, 0}}
      else
        {:cont, {applied, remaining - taken}}
      end
    end)
    |> elem(0)
    |> Enum.each(fn %{lot: lot, amount_cents: taken} ->
      %CreditApplication{}
      |> Ecto.Changeset.change(%{
        group_id: group.id,
        credit_lot_id: lot.id,
        amount_cents: taken
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  Returns the amounts of credit applied to the group, with their lots.
  """
  def applications_for_group(%Group{} = group) do
    Repo.all(
      from a in CreditApplication,
        where: a.group_id == ^group.id,
        preload: [:credit_lot]
    )
  end

  @doc """
  Restores the credit applied to a group back to its original lots. A lot
  whose expiry is already past on `occurred_on` keeps the restored amount
  exhausted: it expires immediately instead of becoming available again.
  """
  def restore_group_credit(%Group{} = group, occurred_on) do
    group
    |> applications_for_group()
    |> Enum.each(fn %CreditApplication{credit_lot: lot, amount_cents: amount_cents} ->
      if Date.compare(lot.expires_on, occurred_on) == :gt do
        lot
        |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents + amount_cents})
        |> Repo.update!()
      end
    end)
  end

  @doc """
  The credit liability as of `as_of`: available credit plus credit currently
  applied to active groups. Applying or restoring credit does not change it;
  expiry and non-refundable consumption reduce it.
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
