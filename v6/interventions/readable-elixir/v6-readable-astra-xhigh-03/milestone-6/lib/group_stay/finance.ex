defmodule GroupStay.Finance do
  @moduledoc """
  Captures the reporting inception and posts financial effects atomically with
  reservation operations. Callers must hold the operation's write transaction.

  Cash follows the group holding or settling each allocation. Credit is a
  company liability: application pauses expiry, restoration resumes it, and
  clawback absorption precedes expiry. No reporting entries exist before start.
  """
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Finance.{DailyReport, Entry, ReportingStart}
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
            else: {:ok, DailyReport.build(date)}

        nil ->
          {:error, :report_not_available}
      end
    end)
  end

  def record_cash(_group_id, _operation, _occurred_on, _kind, 0), do: :ok

  def record_cash(group_id, operation, occurred_on, kind, amount) do
    if posted_on = posting_date(occurred_on) do
      property_id =
        Repo.one!(from g in Group, where: g.group_id == ^group_id, select: g.property_id)

      entry(operation, :cash, posted_on, kind, amount, property_id: property_id)
    end

    :ok
  end

  def record_credit(_lot, _operation, _occurred_on, _kind, 0), do: :ok

  def record_credit(lot, operation, occurred_on, kind, amount) do
    if posted_on = posting_date(occurred_on) do
      post_credit(lot, operation, posted_on, kind, amount)
    end

    :ok
  end

  defp capture_opening(operation, starts_on) do
    cash =
      Repo.all(
        from g in Group,
          where: g.deposit_paid_cents > g.credit_paid_cents,
          select: {g.property_id, g.deposit_paid_cents - g.credit_paid_cents}
      )

    for {property_id, amount} <- cash do
      entry(operation, :cash, starts_on, :opening, amount, property_id: property_id)
    end

    lots =
      Repo.all(
        from lot in CreditLot, where: lot.remaining_cents > 0 and lot.expires_on >= ^starts_on
      )

    for lot <- lots do
      entry(operation, :credit, starts_on, :opening, lot.remaining_cents, credit_lot_id: lot.id)
      expiry(lot, operation, starts_on, lot.remaining_cents)
    end

    # Applied credit stays a liability even when its original lot has expired
    # or has an unrecovered clawback. Each portion is counted exactly once.
    for allocation <- Repo.all(from a in RoomCreditAllocation, where: a.active) do
      entry(operation, :credit, starts_on, :opening, allocation.amount_cents,
        credit_lot_id: allocation.credit_lot_id
      )
    end
  end

  defp post_credit(lot, operation, date, :issued, amount) do
    entry(operation, :credit, date, :issued, amount, credit_lot_id: lot.id)
    expiry(lot, operation, date, amount)
  end

  defp post_credit(lot, operation, date, :applied, amount),
    do: expiry(lot, operation, date, -amount)

  defp post_credit(lot, operation, date, :restored, amount),
    do: expiry(lot, operation, date, amount)

  defp post_credit(lot, operation, date, :revoked, amount) do
    # Removing already expired, unused entitlement cannot reduce liability a
    # second time. Applied entitlement remains liable until it is settled.
    if Date.compare(lot.expires_on, date) != :lt do
      entry(operation, :credit, date, :revoked, amount, credit_lot_id: lot.id)
      expiry(lot, operation, date, -amount)
    end
  end

  defp post_credit(lot, operation, date, kind, amount) when kind in [:consumed, :absorbed],
    do: entry(operation, :credit, date, kind, amount, credit_lot_id: lot.id)

  # Only unused balances expire. A return after expiry leaves liability on the
  # return's posting date, never retroactively on the original expiry date.
  # A backdated redemption clamped past expiry can likewise offset expiry on
  # its posting date, bringing that applied amount back into the liability.
  defp expiry(lot, operation, date, amount) do
    expires_on = later(date, Date.add(lot.expires_on, 1))
    entry(operation, :credit, expires_on, :expired, amount, credit_lot_id: lot.id)
  end

  defp posting_date(occurred_on) do
    case Repo.get(ReportingStart, 1) do
      nil -> nil
      start -> later(occurred_on, start.starts_on)
    end
  end

  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  defp entry(_operation, _account, _date, _kind, 0, _provenance), do: :ok

  defp entry(operation, account, date, kind, amount, provenance) do
    %Entry{
      operation_id: operation["operation_id"],
      account: account,
      posted_on: date,
      kind: kind,
      amount_cents: amount
    }
    |> struct!(provenance)
    |> Repo.insert!()
  end
end
