defmodule GroupStay.Finance do
  @moduledoc """
  Finance reporting: when it started, and what has moved since.

  Current balances say where money stands but not how it got there, so once
  reporting starts every finance effect of an applied operation is written down
  against the date it posts to. Reporting starts once: the first applied
  `start_finance_reporting` operation fixes `starts_on` and captures the position
  everything committed before it left behind.

  That opening position is recorded as movements dated the day before
  `starts_on`, so a report for any reportable date is simply the movements before
  that date plus the movements on it.

  A rejected operation records nothing, and neither does an operation replayed
  from its durable record, so a movement is never reported twice.

  A period close publishes every report through its cutoff. Published days never
  move again, so an operation that commits afterwards posts its whole finance
  effect on the first open day and its movements are marked as put there by a
  close, which is what a report reads back as its late adjustments.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.Close
  alias GroupStay.Finance.CreditMovement
  alias GroupStay.Finance.Posting
  alias GroupStay.Finance.Reporting
  alias GroupStay.Funding
  alias GroupStay.Repo

  @doc "The reporting inception point, or `nil` while reporting has not started."
  def reporting, do: Repo.one(from r in Reporting, limit: 1)

  @doc """
  Starts reporting on `starts_on`.

  The financial state as it stands right now becomes the opening position on that
  date. Returns `{:error, :already_started}` when reporting has already been
  started, whichever date that was.
  """
  def start(starts_on, operation_id) do
    %Reporting{}
    |> Reporting.changeset(%{singleton: 0, starts_on: starts_on, operation_id: operation_id})
    |> Repo.insert()
    |> case do
      {:ok, reporting} ->
        open_position(starts_on)
        {:ok, reporting}

      {:error, _changeset} ->
        {:error, :already_started}
    end
  end

  @doc "The latest date finance has published through, or `nil` before any close."
  def closed_through do
    Repo.one(
      from c in Close, order_by: [desc: c.period_end_on], limit: 1, select: c.period_end_on
    )
  end

  @doc """
  Publishes every report through `period_end_on`.

  A close only makes sense once reporting has started, cannot reach back before
  the reporting window, and only ever moves the cutoff forward, so anything else
  comes back as `{:error, :invalid_period}`.
  """
  def close(period_end_on, operation_id) do
    if closeable?(period_end_on) do
      %Close{}
      |> Close.changeset(%{period_end_on: period_end_on, operation_id: operation_id})
      |> Repo.insert()
      |> case do
        {:ok, close} -> {:ok, close}
        # Only the unique cutoff index can refuse the insert, and only to an
        # attempt that lost the race to close the same period.
        {:error, _changeset} -> {:error, :invalid_period}
      end
    else
      {:error, :invalid_period}
    end
  end

  defp closeable?(period_end_on) do
    case {reporting(), closed_through()} do
      {nil, _cutoff} -> false
      {%Reporting{starts_on: starts_on}, nil} -> not Date.before?(period_end_on, starts_on)
      {%Reporting{}, cutoff} -> Date.after?(period_end_on, cutoff)
    end
  end

  @doc """
  Where an operation that occurred on `occurred_on` posts its finance effects, or
  `nil` while reporting has not started.

  Nothing posts before the reporting window opens and nothing posts into a
  published period, so the effects land on the later of the operation's own date,
  `starts_on`, and the first open day. A close having been the reason is
  remembered on the posting, because that is what makes it a late adjustment.
  """
  def posting(occurred_on) do
    case reporting() do
      nil -> nil
      %Reporting{starts_on: starts_on} -> open_day(later_of(occurred_on, starts_on))
    end
  end

  defp open_day(reportable_on) do
    cutoff = closed_through()

    if cutoff && not Date.after?(reportable_on, cutoff) do
      %Posting{date: Date.add(cutoff, 1), late?: true}
    else
      %Posting{date: reportable_on, late?: false}
    end
  end

  defp later_of(date, floor) do
    if Date.before?(date, floor), do: floor, else: date
  end

  # --- recording cash -----------------------------------------------------

  @doc "Records a classified change to the cash a property holds."
  def cash(posting, property_id, classification, amount_cents)

  def cash(nil, _property_id, _classification, _amount_cents), do: :ok
  def cash(_posting, _property_id, _classification, 0), do: :ok

  def cash(%Posting{} = posting, property_id, classification, amount_cents) do
    %CashMovement{}
    |> CashMovement.changeset(%{
      posting_date: posting.date,
      late: posting.late?,
      property_id: property_id,
      classification: classification,
      amount_cents: amount_cents
    })
    |> Repo.insert!()

    :ok
  end

  # --- recording hotel credit ---------------------------------------------

  @doc "Records a lot issued by a refundable settlement."
  def credit_issued(posting, lot, amount_cents),
    do: credit(posting, lot.id, "issued", amount_cents, amount_cents, 0)

  @doc """
  Records credit redeemed into an active room deposit.

  The liability moves from the lot to the room rather than out of the business,
  so the event posts no movement.
  """
  def credit_applied(posting, lot, amount_cents),
    do: credit(posting, lot.id, "applied", 0, -amount_cents, amount_cents)

  @doc """
  Records credit returned to its lot by a refundable settlement.

  Only the part absorbed by an unrecovered clawback leaves the liability here.
  Credit returning to a lot whose expiry has passed leaves it too, but as expiry,
  which a report derives rather than records.
  """
  def credit_restored(posting, lot, amount_cents, absorbed_cents) do
    credit(
      posting,
      lot.id,
      "restored",
      absorbed_cents,
      amount_cents - absorbed_cents,
      -amount_cents
    )
  end

  @doc "Records applied credit consumed by a non-refundable settlement."
  def credit_consumed(posting, lot_ref, amount_cents),
    do: credit(posting, lot_ref, "consumed", amount_cents, 0, -amount_cents)

  @doc """
  Records entitlement a chargeback took back out of a lot.

  A lot that has already expired holds nothing the business still owes, so
  recovering from it moves the lot's balance without moving any liability.
  """
  def credit_revoked(posting, lot, recovered_cents)

  def credit_revoked(nil, _lot, _recovered_cents), do: :ok

  def credit_revoked(%Posting{} = posting, lot, recovered_cents) do
    revoked_cents = if Date.after?(lot.expires_on, posting.date), do: recovered_cents, else: 0

    credit(posting, lot.id, "revoked", revoked_cents, -recovered_cents, 0)
  end

  # --- internals ----------------------------------------------------------

  defp credit(nil, _lot_ref, _event, _amount, _remaining_delta, _applied_delta), do: :ok

  defp credit(_posting, _lot_ref, _event, 0, 0, 0), do: :ok

  defp credit(%Posting{} = posting, lot_ref, event, amount_cents, remaining_delta, applied_delta) do
    %CreditMovement{}
    |> CreditMovement.changeset(%{
      posting_date: posting.date,
      late: posting.late?,
      lot_ref: lot_ref,
      event: event,
      amount_cents: amount_cents,
      remaining_delta_cents: remaining_delta,
      applied_delta_cents: applied_delta
    })
    |> Repo.insert!()

    :ok
  end

  # The position everything committed before the start operation leaves behind,
  # dated so that it is opening balance rather than movement on every report.
  defp open_position(starts_on) do
    opened = %Posting{date: Date.add(starts_on, -1)}

    for {property_id, amount_cents} <- Funding.held_cash_by_property() do
      cash(opened, property_id, "opening", amount_cents)
    end

    for position <- Credit.positions() do
      credit(
        opened,
        position.lot_ref,
        "opening",
        0,
        position.remaining_cents,
        position.applied_cents
      )
    end

    :ok
  end
end
