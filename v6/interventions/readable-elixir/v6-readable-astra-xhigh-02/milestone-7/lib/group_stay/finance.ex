defmodule GroupStay.Finance do
  @moduledoc """
  Starts and closes durable finance reporting and reads daily reports.

  Inception captures current allocations and credit lots inside the same immediate
  transaction as the start receipt. It deliberately does not reconstruct balances
  from operation dates: everything already committed belongs to the opening.
  Subsequent mutations journal their actual effects, including settlement locations.

  Closing advances an inclusive cutoff under the operation's write lock. All later
  entries, including offsets to scheduled expiry, post after that cutoff. The
  immutable journal therefore preserves published reports without storing a copy
  of every calendar day. Report reads use one snapshot of both cutoff and entries.
  """
  import Ecto.Query

  alias GroupStay.{Accounting, Repo}
  alias GroupStay.Accounting.Allocation
  alias GroupStay.Finance.{DailyReport, Entry, Journal, ReportingPeriod}
  alias GroupStay.HotelCredit.Lot
  alias GroupStay.Reservations.Booking

  def start_reporting(operation) do
    with {:ok, starts_on} <- reporting_date(operation["starts_on"]) do
      cond do
        Repo.get(ReportingPeriod, 1) ->
          {:error, :reporting_already_started}

        not match?({:ok, _}, Booking.date(operation["occurred_on"])) ->
          {:error, :invalid_operation}

        true ->
          Repo.insert!(%ReportingPeriod{id: 1, starts_on: starts_on})

          journal = %Journal{
            operation_id: operation["operation_id"],
            effective_on: starts_on,
            posted_on: starts_on
          }

          capture_opening(journal)
          {:ok, %{starts_on: starts_on}}
      end
    end
  end

  @doc "Publishes through a strictly advancing cutoff inside the operation transaction."
  def close_period(operation) do
    with {:ok, period_end_on} <- Booking.date(operation["period_end_on"]),
         %ReportingPeriod{} = period <- Repo.get(ReportingPeriod, 1),
         true <- Date.compare(period_end_on, period.starts_on) != :lt,
         true <-
           is_nil(period.closed_through) or
             Date.compare(period_end_on, period.closed_through) == :gt do
      case Booking.date(operation["occurred_on"]) do
        {:ok, _occurred_on} ->
          period
          |> Ecto.Changeset.change(closed_through: period_end_on)
          |> Repo.update!()

          {:ok, %{period_end_on: period_end_on}}

        _ ->
          {:error, :invalid_operation}
      end
    else
      _ -> {:error, :invalid_period}
    end
  end

  @doc "Builds the journal context only for a new operation, never for durable replay."
  def journal(operation) do
    with %ReportingPeriod{} = period <- Repo.get(ReportingPeriod, 1),
         {:ok, occurred_on} <- Booking.date(operation["occurred_on"]) do
      effective_on = Journal.later_date(occurred_on, period.starts_on)

      posted_on =
        if period.closed_through,
          do: Journal.later_date(effective_on, Date.add(period.closed_through, 1)),
          else: effective_on

      %Journal{
        operation_id: operation["operation_id"],
        effective_on: effective_on,
        posted_on: posted_on
      }
    else
      _ -> nil
    end
  end

  def daily_report(value) do
    with {:ok, date} <- reporting_date(value) do
      {:ok, result} = Repo.transaction(fn -> read_report(date) end)
      result
    end
  end

  defp read_report(date) do
    case Repo.get(ReportingPeriod, 1) do
      %ReportingPeriod{starts_on: starts_on, closed_through: closed_through} ->
        if Date.compare(date, starts_on) == :lt do
          {:error, :report_not_available}
        else
          entries = Repo.all(from entry in Entry, where: entry.posted_on <= ^date)

          status =
            if closed_through && Date.compare(date, closed_through) != :gt,
              do: "closed",
              else: "open"

          {:ok, DailyReport.build(date, entries, status)}
        end

      nil ->
        {:error, :report_not_available}
    end
  end

  defp capture_opening(journal) do
    from(allocation in Allocation,
      join: room in assoc(allocation, :room),
      join: group in assoc(room, :group),
      where: room.status == "active" and not is_nil(allocation.cash_payment_id),
      select: {group.property_id, allocation.amount_cents}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, amount} ->
      Journal.cash(journal, property_id, :opening_held_cents, amount)
    end)

    applied = Accounting.applied_credit_by_lot()

    for lot <- Repo.all(Lot) do
      available =
        if Date.compare(lot.expires_on, journal.posted_on) == :lt,
          do: 0,
          else: lot.remaining_cents

      Journal.credit(journal, :opening_liability_cents, available + Map.get(applied, lot.id, 0))
      Journal.schedule_expiry(journal, lot, available)
    end
  end

  defp reporting_date(value) do
    case Booking.date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_reporting_date}
    end
  end
end
