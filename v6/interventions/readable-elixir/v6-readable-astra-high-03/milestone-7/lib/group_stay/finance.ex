defmodule GroupStay.Finance do
  @moduledoc """
  Owns finance reporting inception, period close, and daily report reads.

  Inception captures committed balances rather than replaying submission dates.
  Thereafter the journal explains changes by posting date. Reads use a single
  database snapshot and never expire credit or otherwise mutate domain state.
  """
  import Ecto.Query
  alias GroupStay.{Ledger, Repo}
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.{DailyReport, Journal, Reporting}
  alias GroupStay.Reservations.{Booking, Group}

  def start(operation) do
    with {:ok, starts_on} <- reporting_date(operation["starts_on"]) do
      if Repo.get(Reporting, 1) do
        {:error, "reporting_already_started"}
      else
        Repo.insert!(%Reporting{id: 1, starts_on: starts_on})
        context = %{operation_id: operation["operation_id"], posted_on: starts_on}

        Repo.all(
          from g in Group,
            group_by: g.property_id,
            select: {g.property_id, sum(g.deposit_paid_cents - g.credit_paid_cents)}
        )
        |> Enum.each(fn {property, held} -> Journal.entry(context, property, :opening, held) end)

        Journal.credit(context, :opening, Ledger.totals(starts_on).credit_liability_cents)

        Repo.all(from l in Lot, where: l.expires_on >= ^starts_on and l.remaining_cents > 0)
        |> Enum.each(&Journal.available_changed(context, &1.expires_on, &1.remaining_cents))

        {:ok, %{starts_on: starts_on}}
      end
    end
  end

  @doc """
  Publishes all reporting days through the cutoff inside the operation transaction.

  Journal writes share that transaction's write lock and can only post after the
  latest cutoff. Closing therefore needs no per-day copies or journal rewrites.
  """
  def close(operation) do
    with {:ok, period_end_on} <- Booking.date(operation["period_end_on"]),
         %Reporting{} = reporting <- Repo.get(Reporting, 1),
         true <- Date.compare(period_end_on, reporting.starts_on) != :lt,
         true <- later_cutoff?(period_end_on, reporting.closed_through) do
      reporting
      |> Ecto.Changeset.change(closed_through: period_end_on)
      |> Repo.update!()

      {:ok, %{period_end_on: period_end_on}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  def daily_report(value) do
    with {:ok, date} <- reporting_date(value) do
      {:ok, result} = Repo.transaction(fn -> read_report(date) end)
      result
    end
  end

  defp later_cutoff?(_date, nil), do: true
  defp later_cutoff?(date, cutoff), do: Date.compare(date, cutoff) == :gt

  defp reporting_date(value) do
    case Booking.date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp read_report(date) do
    case Repo.get(Reporting, 1) do
      nil ->
        {:error, "report_not_available"}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt,
          do: {:error, "report_not_available"},
          else: {:ok, DailyReport.build(date, reporting)}
    end
  end
end
