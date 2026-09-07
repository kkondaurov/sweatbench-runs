defmodule GroupStay.Reservations.FinancePeriodClose do
  @moduledoc """
  Publishes immutable daily reports and advances the reporting cutoff.

  Each close snapshots only the dates that were still open. Earlier snapshots
  are never rewritten, making the publication boundary durable and explicit.
  """

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    DailyFinanceReport,
    FinanceReportSnapshot,
    FinanceReportingPeriod
  }

  @doc "Publishes every still-open report through the supplied cutoff."
  def close(period_end_on) do
    with %FinanceReportingPeriod{} = period <- Repo.get(FinanceReportingPeriod, 1),
         :ok <- valid_period(period, period_end_on) do
      first_open_date =
        case period.latest_closed_on do
          nil -> period.starts_on
          latest_closed_on -> Date.add(latest_closed_on, 1)
        end

      first_open_date
      |> Date.range(period_end_on)
      |> Enum.each(&publish_report(period, &1))

      period
      |> FinanceReportingPeriod.close_changeset(period_end_on)
      |> Repo.update!()

      :ok
    else
      nil -> {:error, :invalid_period}
      {:error, :invalid_period} = error -> error
    end
  end

  @doc "Returns the published report for a date known to be closed."
  def fetch_report!(period, report_date) do
    Repo.get_by!(FinanceReportSnapshot,
      reporting_period_id: period.id,
      report_date: report_date
    ).data
  end

  defp valid_period(period, %Date{} = period_end_on) do
    after_start_or_equal = not Date.before?(period_end_on, period.starts_on)

    after_latest_close =
      is_nil(period.latest_closed_on) or Date.after?(period_end_on, period.latest_closed_on)

    if after_start_or_equal and after_latest_close,
      do: :ok,
      else: {:error, :invalid_period}
  end

  defp valid_period(_period, _period_end_on), do: {:error, :invalid_period}

  defp publish_report(period, report_date) do
    data =
      period
      |> DailyFinanceReport.build(report_date, "closed")
      |> json_value()

    %FinanceReportSnapshot{}
    |> FinanceReportSnapshot.creation_changeset(%{
      reporting_period_id: period.id,
      report_date: report_date,
      data: data
    })
    |> Repo.insert!()
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
