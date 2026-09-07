defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  Captures finance inception, publishes periods, and journals economic effects.

  Writers run inside the operation's existing transaction and savepoint, so
  domain changes, reporting entries, and the durable result commit together.
  Cash follows its holding or settlement property, including corrections.

  Unused credit has a scheduled expiry. Changing an available balance adjusts
  that schedule; applied credit has no scheduled expiry. This records expiry
  without a clock-driven job, and preserves history when credit returns after
  expiry. Partner dates can arrive out of order: entries remain additive, and
  dates before inception are clamped to inception.

  Closing advances a durable cutoff. Every new entry, including corrections to
  scheduled expiry, is posted after that cutoff. The immediate transaction held
  by Operations serializes closes with writers, so reports through the cutoff
  stay unchanged without storing a separate copy of every daily report.
  """

  import Ecto.Query

  alias GroupStay.{Credits, Repo}
  alias GroupStay.Credits.Lot
  alias GroupStay.Finance.CashAllocation
  alias GroupStay.Finance.Reporting.{DailyReport, Entry, Inception, PeriodClose}
  alias GroupStay.Reservations.{Group, Operation}

  @doc false
  def start(%Operation{} = operation) do
    with {:ok, starts_on} <-
           Operation.date(operation.params["starts_on"], "invalid_reporting_date"),
         {:ok, _occurred_on} <-
           Operation.date(operation.params["occurred_on"], "invalid_operation"),
         :ok <- require_not_started() do
      Repo.insert!(%Inception{
        starts_on: starts_on,
        opening_position: %{
          "cash" => opening_cash(),
          "credit_liability_cents" => Credits.liability_cents(starts_on)
        }
      })

      Repo.all(from lot in Lot, where: lot.expires_on >= ^starts_on and lot.remaining_cents > 0)
      |> Enum.each(&schedule_expiry!(operation, &1, &1.remaining_cents))

      {:ok, %{starts_on: starts_on}}
    end
  end

  @doc false
  def close(%Operation{} = operation) do
    with {:ok, period_end_on} <-
           Operation.date(operation.params["period_end_on"], "invalid_period"),
         {:ok, _occurred_on} <-
           Operation.date(operation.params["occurred_on"], "invalid_operation"),
         :ok <- require_open_period(period_end_on) do
      Repo.insert!(%PeriodClose{
        operation_id: operation.operation_id,
        period_end_on: period_end_on
      })

      {:ok, %{period_end_on: period_end_on}}
    end
  end

  @doc "Reads a daily report from a consistent snapshot, without changing any state."
  def daily_report(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(Inception, 1) do
          nil ->
            {:error, "report_not_available"}

          inception ->
            if Date.compare(date, inception.starts_on) == :lt do
              {:error, "report_not_available"}
            else
              entries = Repo.all(from entry in Entry, where: entry.posted_on <= ^date)
              status = if closed?(date, latest_cutoff()), do: "closed", else: "open"
              {:ok, DailyReport.build(inception.opening_position, entries, date, status)}
            end
        end
      end)

    result
  end

  @doc false
  def cash!(operation, group_id, movements) do
    if on = base_posting_date(operation) do
      group = Repo.get!(Group, group_id)
      insert!(operation, on, group.property_id, movements)
    end
  end

  @doc false
  def credit!(operation, movements) do
    if on = base_posting_date(operation), do: insert!(operation, on, nil, movements)
  end

  @doc """
  Journals a change to a lot's unused balance and its associated movements.

  After expiry, a revocation removes no live liability. Other changes to unused
  credit expire on the posting date instead of rewriting a past expiry. Signed
  expiry also handles a backdated application clamped to an inception after the
  lot expired: the previously expired credit now funds an active reservation.
  """
  def available_credit!(operation, lot, change, movements \\ %{}) do
    if on = base_posting_date(operation) do
      if Date.compare(lot.expires_on, on) == :lt do
        revoked = Map.get(movements, :revoked_cents, 0)

        movements =
          movements
          |> Map.delete(:revoked_cents)
          |> Map.update(:expired_cents, change + revoked, &(&1 + change + revoked))

        insert!(operation, on, nil, movements)
      else
        insert!(operation, on, nil, movements)
        schedule_expiry!(operation, lot, change)
      end
    end
  end

  defp require_not_started do
    if Repo.exists?(Inception), do: {:error, "reporting_already_started"}, else: :ok
  end

  defp require_open_period(period_end_on) do
    case Repo.get(Inception, 1) do
      nil ->
        {:error, "invalid_period"}

      inception ->
        if Date.compare(period_end_on, inception.starts_on) == :lt or
             closed?(period_end_on, latest_cutoff()),
           do: {:error, "invalid_period"},
           else: :ok
    end
  end

  defp latest_cutoff,
    do: Repo.one(from period in PeriodClose, select: max(period.period_end_on))

  defp closed?(_date, nil), do: false
  defp closed?(date, cutoff), do: Date.compare(date, cutoff) != :gt

  defp opening_cash do
    Repo.all(
      from allocation in CashAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: allocation.disposition == :held,
        select: {group.property_id, allocation.amount_cents}
    )
    |> Enum.reduce(%{}, fn {property, amount}, balances ->
      Map.update(balances, property, amount, &(&1 + amount))
    end)
  end

  # Inception determines which liability is live for classification. A close
  # then moves the resulting entries without changing their economic meaning.
  defp base_posting_date(operation) do
    case Repo.one(from inception in Inception, select: inception.starts_on) do
      nil ->
        nil

      starts_on ->
        later_date(Date.from_iso8601!(operation.params["occurred_on"]), starts_on)
    end
  end

  defp later_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  # No API date can reach the day after the largest supported expiry date.
  defp schedule_expiry!(_operation, %Lot{expires_on: ~D[9999-12-31]}, _amount), do: :ok

  defp schedule_expiry!(operation, lot, amount),
    do: insert!(operation, Date.add(lot.expires_on, 1), nil, %{expired_cents: amount})

  defp insert!(operation, on, property, movements) do
    movements = Map.reject(movements, fn {_kind, amount} -> amount == 0 end)

    if map_size(movements) > 0 do
      # Classify the complete economic effect before moving its posting date.
      # For example, revoking credit before its expiry reverses scheduled expiry
      # as well. If both days are closed, preserve both signed classifications
      # together on the first open day, even though their net effect is zero.
      cutoff = latest_cutoff()
      late_adjustment = closed?(on, cutoff)

      Repo.insert!(%Entry{
        operation_id: operation.operation_id,
        posted_on: if(late_adjustment, do: Date.add(cutoff, 1), else: on),
        property_id: property,
        movements: movements,
        late_adjustment: late_adjustment
      })
    end
  end
end
