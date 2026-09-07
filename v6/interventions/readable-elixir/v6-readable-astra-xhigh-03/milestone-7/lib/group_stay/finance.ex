defmodule GroupStay.Finance do
  @moduledoc """
  Captures reporting inception, publishes periods, and posts financial effects
  atomically with reservation operations. Mutations require the caller to hold
  the operation's write transaction.

  Cash follows the group holding or settling each allocation. Credit is a
  company liability: application pauses expiry, restoration resumes it, and
  clawback absorption precedes expiry. No reporting entries exist before start.
  """
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Finance.{DailyReport, Entry, PeriodClose, Posting, ReportingStart}
  alias GroupStay.Reservations.{CreditLot, Group, Operation, RoomCreditAllocation}

  def start(operation) do
    with {:ok, starts_on} <- reporting_date(operation["starts_on"]),
         {:ok, _occurred_on} <- Operation.validate_payload(operation) do
      if Repo.get(ReportingStart, 1) do
        {:error, :reporting_already_started}
      else
        Repo.insert!(%ReportingStart{
          id: 1,
          operation_id: operation["operation_id"],
          starts_on: starts_on
        })

        capture_opening(operation, starts_on)
        {:ok, %{starts_on: starts_on}}
      end
    end
  end

  @doc "Publishes through an advancing cutoff in the caller's operation transaction."
  def close_period(operation) do
    with {:ok, period_end_on} <- Operation.date(operation["period_end_on"]),
         %ReportingStart{starts_on: starts_on} <- Repo.get(ReportingStart, 1),
         true <- Date.compare(period_end_on, starts_on) != :lt,
         cutoff = latest_cutoff(),
         true <- is_nil(cutoff) or Date.compare(period_end_on, cutoff) == :gt,
         {:ok, _occurred_on} <- Operation.validate_payload(operation) do
      Repo.insert!(%PeriodClose{
        operation_id: operation["operation_id"],
        period_end_on: period_end_on
      })

      {:ok, %{period_end_on: period_end_on}}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :invalid_period}
    end
  end

  def reporting_date(value) do
    case Operation.date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, :invalid_reporting_date}
    end
  end

  @doc "Reads a daily report in one database snapshot, without changing any state."
  def daily_report(date) do
    Repo.transact(fn ->
      case Repo.get(ReportingStart, 1) do
        %ReportingStart{starts_on: starts_on} ->
          if Date.compare(date, starts_on) == :lt,
            do: {:error, :report_not_available},
            else: {:ok, DailyReport.build(date, report_status(date))}

        nil ->
          {:error, :report_not_available}
      end
    end)
  end

  def record_cash(_group_id, _operation, _occurred_on, _kind, 0), do: :ok

  def record_cash(group_id, operation, occurred_on, kind, amount) do
    if posting = posting(occurred_on) do
      property_id =
        Repo.one!(from g in Group, where: g.group_id == ^group_id, select: g.property_id)

      entry(operation, :cash, posting, kind, amount, property_id: property_id)
    end

    :ok
  end

  def record_credit(_lot, _operation, _occurred_on, _kind, 0), do: :ok

  def record_credit(lot, operation, occurred_on, kind, amount) do
    if posting = posting(occurred_on) do
      post_credit(lot, operation, posting, kind, amount)
    end

    :ok
  end

  defp capture_opening(operation, starts_on) do
    posting = Posting.new(starts_on, starts_on, nil)

    cash =
      Repo.all(
        from g in Group,
          where: g.deposit_paid_cents > g.credit_paid_cents,
          select: {g.property_id, g.deposit_paid_cents - g.credit_paid_cents}
      )

    for {property_id, amount} <- cash do
      entry(operation, :cash, posting, :opening, amount, property_id: property_id)
    end

    lots =
      Repo.all(
        from lot in CreditLot, where: lot.remaining_cents > 0 and lot.expires_on >= ^starts_on
      )

    for lot <- lots do
      entry(operation, :credit, posting, :opening, lot.remaining_cents, credit_lot_id: lot.id)
      expiry(lot, operation, posting, lot.remaining_cents)
    end

    # Applied credit stays a liability even when its original lot has expired
    # or has an unrecovered clawback. Each portion is counted exactly once.
    for allocation <- Repo.all(from a in RoomCreditAllocation, where: a.active) do
      entry(operation, :credit, posting, :opening, allocation.amount_cents,
        credit_lot_id: allocation.credit_lot_id
      )
    end
  end

  defp post_credit(lot, operation, posting, :issued, amount) do
    entry(operation, :credit, posting, :issued, amount, credit_lot_id: lot.id)
    expiry(lot, operation, posting, amount)
  end

  defp post_credit(lot, operation, posting, :applied, amount),
    do: expiry(lot, operation, posting, -amount)

  defp post_credit(lot, operation, posting, :restored, amount),
    do: expiry(lot, operation, posting, amount)

  defp post_credit(lot, operation, posting, :revoked, amount) do
    # Entitlement already expired on the original reporting date has no further
    # effect. A close only moves the effect: if it published the scheduled expiry,
    # show both its reversal and the revocation on the first open day.
    if Date.compare(lot.expires_on, posting.original_date) != :lt do
      entry(operation, :credit, posting, :revoked, amount, credit_lot_id: lot.id)
      expiry(lot, operation, posting, -amount)
    end
  end

  defp post_credit(lot, operation, posting, kind, amount) when kind in [:consumed, :absorbed],
    do: entry(operation, :credit, posting, kind, amount, credit_lot_id: lot.id)

  # Only unused balances expire. A return after expiry leaves liability on the
  # return's posting date, never retroactively on the original expiry date.
  # A backdated redemption clamped past expiry can likewise offset expiry on
  # its posting date, bringing that applied amount back into the liability.
  defp expiry(lot, operation, posting, amount) do
    expiry_posting = Posting.on_or_after(posting, Date.add(lot.expires_on, 1))
    entry(operation, :credit, expiry_posting, :expired, amount, credit_lot_id: lot.id)
  end

  defp posting(occurred_on) do
    case Repo.get(ReportingStart, 1) do
      nil -> nil
      start -> Posting.new(occurred_on, start.starts_on, latest_cutoff())
    end
  end

  defp latest_cutoff do
    Repo.one(
      from c in PeriodClose, order_by: [desc: c.period_end_on], limit: 1, select: c.period_end_on
    )
  end

  defp report_status(date) do
    case latest_cutoff() do
      nil -> "open"
      cutoff -> if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
    end
  end

  defp entry(_operation, _account, _date, _kind, 0, _provenance), do: :ok

  defp entry(operation, account, posting, kind, amount, provenance) do
    %Entry{
      operation_id: operation["operation_id"],
      account: account,
      posted_on: posting.date,
      late_adjustment: Posting.late?(posting),
      kind: kind,
      amount_cents: amount
    }
    |> struct!(provenance)
    |> Repo.insert!()
  end
end
