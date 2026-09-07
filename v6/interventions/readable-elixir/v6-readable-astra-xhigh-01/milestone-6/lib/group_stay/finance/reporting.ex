defmodule GroupStay.Finance.Reporting do
  @moduledoc """
  Captures finance inception and journals subsequent economic effects.

  Writers run inside the operation's existing transaction and savepoint, so
  domain changes, reporting entries, and the durable result commit together.
  Cash follows its holding or settlement property, including corrections.

  Unused credit has a scheduled expiry. Changing an available balance adjusts
  that schedule; applied credit has no scheduled expiry. This records expiry
  without a clock-driven job, and preserves history when credit returns after
  expiry. Partner dates can arrive out of order: entries remain additive, and
  dates before inception are clamped to inception.
  """

  import Ecto.Query

  alias GroupStay.{Credits, Repo}
  alias GroupStay.Credits.Lot
  alias GroupStay.Finance.CashAllocation
  alias GroupStay.Finance.Reporting.{DailyReport, Entry, Inception}
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

  @doc "Reads one open report from a consistent snapshot, without changing any state."
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
              {:ok, DailyReport.build(inception.opening_position, entries, date)}
            end
        end
      end)

    result
  end

  @doc false
  def cash!(operation, group_id, movements) do
    if on = posting_date(operation) do
      group = Repo.get!(Group, group_id)
      insert!(operation, on, group.property_id, movements)
    end
  end

  @doc false
  def credit!(operation, movements) do
    if on = posting_date(operation), do: insert!(operation, on, nil, movements)
  end

  @doc """
  Journals a change to a lot's unused balance and its associated movements.

  After expiry, a revocation removes no live liability. Other changes to unused
  credit expire on the posting date instead of rewriting a past expiry. Signed
  expiry also handles a backdated application clamped to an inception after the
  lot expired: the previously expired credit now funds an active reservation.
  """
  def available_credit!(operation, lot, change, movements \\ %{}) do
    if on = posting_date(operation) do
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

  defp posting_date(operation) do
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
      Repo.insert!(%Entry{
        operation_id: operation.operation_id,
        posted_on: on,
        property_id: property,
        movements: movements
      })
    end
  end
end
