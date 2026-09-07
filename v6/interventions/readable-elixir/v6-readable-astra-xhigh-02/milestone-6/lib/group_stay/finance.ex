defmodule GroupStay.Finance do
  @moduledoc """
  Starts durable finance reporting and reads open daily reports.

  Inception captures current allocations and credit lots inside the same immediate
  transaction as the start receipt. It deliberately does not reconstruct balances
  from operation dates: everything already committed belongs to the opening.
  Subsequent mutations journal their actual effects, including settlement locations.
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
          journal = %Journal{operation_id: operation["operation_id"], posted_on: starts_on}
          capture_opening(journal)
          {:ok, %{starts_on: starts_on}}
      end
    end
  end

  @doc "Builds the journal context only for a new operation, never for durable replay."
  def journal(operation) do
    with %ReportingPeriod{starts_on: starts_on} <- Repo.get(ReportingPeriod, 1),
         {:ok, occurred_on} <- Booking.date(operation["occurred_on"]) do
      %Journal{
        operation_id: operation["operation_id"],
        posted_on: Journal.later_date(occurred_on, starts_on)
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
      %ReportingPeriod{starts_on: starts_on} ->
        if Date.compare(date, starts_on) == :lt do
          {:error, :report_not_available}
        else
          entries = Repo.all(from entry in Entry, where: entry.posted_on <= ^date)
          {:ok, DailyReport.build(date, entries)}
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
