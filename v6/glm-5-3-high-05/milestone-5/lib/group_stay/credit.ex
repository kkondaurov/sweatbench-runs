defmodule GroupStay.Credit do
  @moduledoc """
  The hotel-credit ledger.

  Refundable cancellations may convert cash into a credit lot worth 110% of
  that cash. Credit lots fund group deposits through credit applications,
  which remember the originating lot so applied credit can be restored when
  a room or group is later cancelled while refundable.

  A lot is available through its `expires_on` date (inclusive); expiry is
  evaluated as of a reference date supplied by the caller. Credit applied to
  an active group has its expiry paused: it keeps counting toward the credit
  liability until the group is settled.

  A clawback (a chargeback revoking a payment's entitlement) removes the
  entitlement from the lot's remaining balance first; whatever cannot be
  removed becomes the lot's unrecovered clawback. Credit returning to a
  shortfalled lot extinguishes the clawback before any amount becomes
  available or expires.
  """

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Entitlement
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Allocation
  alias GroupStay.Repo

  import Ecto.Query

  @bonus_percent 110
  @credit_validity_days 365

  @doc """
  The value of the credit lot issued for `cash_cents`: 110% of the cash,
  rounded to the nearest cent with an exact half-cent rounding upward.
  """
  def lot_value_cents(cash_cents) do
    div(cash_cents * @bonus_percent + 50, 100)
  end

  @doc """
  Issues a new credit lot for `guest_id`, sourced from the given operation.
  The lot is available through the date 365 days after `cancelled_on` and
  expires the following day.
  """
  def issue_lot!(guest_id, source_operation_id, remaining_cents, cancelled_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: Date.add(cancelled_on, @credit_validity_days)
    })
    |> Repo.insert!()
  end

  @doc """
  Records the per-payment entitlements for a lot issued on cancellation.

  `contributions` is the settled cash of each contributing payment in the
  funding order used by room accounting, with the unattributed block first
  (`nil` payment). Each payment's entitlement is the 10%-bonus value of the
  settled cash through that payment minus the bonus value through the
  preceding payment, applying the standard half-up rounding to both running
  totals; the entitlements telescope exactly to the issued lot.
  """
  def record_entitlements!(lot_pk, contributions) do
    contributions
    |> Enum.reduce(0, fn {payment_entry, amount_cents}, cumulative ->
      before_cents = lot_value_cents(cumulative)
      cumulative = cumulative + amount_cents
      after_cents = lot_value_cents(cumulative)
      entitlement = after_cents - before_cents

      if entitlement > 0 do
        %Entitlement{}
        |> Entitlement.changeset(%{
          lot_id: lot_pk,
          payment_entry_id: payment_entry && payment_entry.id,
          entitlement_cents: entitlement
        })
        |> Repo.insert!()
      end

      cumulative
    end)

    :ok
  end

  @doc """
  Credit lots for `guest_id` that are neither exhausted nor expired as of
  `as_of`, ordered by earliest expiry and then by `source_operation_id`.
  """
  def available_lots(guest_id, as_of) do
    from(l in Lot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [l.expires_on, l.source_operation_id]
    )
    |> Repo.all()
  end

  @doc "Unexpired, unexhausted credit held by `guest_id` as of `as_of`."
  def available_cents(guest_id, as_of) do
    from(l in Lot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      select: coalesce(sum(l.remaining_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Applies `amount_cents` of the guest's credit to the group's deposit,
  consuming lots by earliest expiry, then by `source_operation_id` for equal
  expiries. Expiry is evaluated as of `occurred_on`. The guest must hold at
  least `amount_cents` of unexpired credit. Returns the application rows in
  lot-consumption order.
  """
  def apply_to_group!(group_pk, guest_id, amount_cents, occurred_on, operation_key \\ nil) do
    guest_id
    |> available_lots(occurred_on)
    |> consume_lots(group_pk, amount_cents, operation_key, [])
  end

  defp consume_lots([], _group_pk, remaining, _operation_key, _acc) when remaining > 0 do
    raise ArgumentError, "not enough available credit"
  end

  defp consume_lots(_lots, _group_pk, 0, _operation_key, acc), do: Enum.reverse(acc)

  defp consume_lots([lot | rest], group_pk, remaining, operation_key, acc) do
    chunk = min(lot.remaining_cents, remaining)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - chunk)
    |> Repo.update!()

    application =
      %Application{}
      |> Application.changeset(%{
        group_id: group_pk,
        lot_id: lot.id,
        amount_cents: chunk,
        status: "applied",
        operation_key: operation_key
      })
      |> Repo.insert!()

    consume_lots(rest, group_pk, remaining - chunk, operation_key, [application | acc])
  end

  @doc """
  Restores applied credit to its original lot with its original expiry;
  restored credit never receives a second bonus. Absorption into the lot's
  unrecovered clawback occurs first: only the excess then becomes available
  again or, if the lot's expiry is already past on the cancellation date,
  expires immediately.
  """
  def restore_to_lot!(%Lot{} = lot, amount_cents, occurred_on) do
    absorbed = min(lot.unrecovered_clawback_cents, amount_cents)
    excess = amount_cents - absorbed
    expired? = Date.compare(lot.expires_on, occurred_on) == :lt

    lot
    |> Ecto.Changeset.change(
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
      remaining_cents: lot.remaining_cents + if(expired?, do: 0, else: excess)
    )
    |> Repo.update!()
  end

  @doc """
  The credit liability as of `as_of`: unexpired available credit plus credit
  currently applied to active rooms (whose expiry is paused while it funds
  the group). Applying or restoring credit does not change the liability
  unless the restored lot has already expired or the restoration was
  absorbed by a shortfall; expiry, non-refundable consumption, and revoked
  unspent entitlement reduce it.
  """
  def liability_cents(as_of) do
    available =
      from(l in Lot,
        where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
        select: coalesce(sum(l.remaining_cents), 0)
      )
      |> Repo.one()

    applied = applied_cents()

    available + applied
  end

  # Credit currently applied to active rooms.
  defp applied_cents do
    from(a in Allocation,
      where: a.kind == "credit" and a.remaining_cents > 0,
      select: coalesce(sum(a.remaining_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  The current credit shortfall: for each lot, the lesser of its unrecovered
  clawback and credit from that lot still applied to active groups.
  """
  def shortfall_cents do
    from(l in Lot, where: l.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, applied_to_active_cents(lot.id))
    end)
  end

  defp applied_to_active_cents(lot_pk) do
    from(a in Allocation,
      join: app in assoc(a, :credit_application),
      where: a.kind == "credit" and a.remaining_cents > 0 and app.lot_id == ^lot_pk,
      select: coalesce(sum(a.remaining_cents), 0)
    )
    |> Repo.one()
  end

  @doc "Renders a guest's credit summary as the partner API payload."
  def render(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
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
end
