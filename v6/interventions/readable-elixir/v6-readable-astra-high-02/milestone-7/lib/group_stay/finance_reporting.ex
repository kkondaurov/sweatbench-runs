defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Durable daily cash and credit reporting, independent of the live ledger's date filter.

  Domain mutations receive an explicit posting context and journal their financial
  facts inside the same transaction as the durable operation result. Inception captures
  existing balances rather than replaying old audit records, including legacy funding.

  Period closes advance the earliest posting date under the same write lock used by
  partner operations. No journal entry can subsequently change a published day.
  The late-adjustment flag records whether the close moved an entry's posting date;
  later closes never reinterpret that decision. Report balances include both ordinary
  and late movements while presenting their classifications separately.

  Unused credit schedules expiry on the day after its inclusive expiry date. Using or
  restoring it adjusts that schedule. If expiry precedes an operation's posting date,
  the adjustment posts with that operation instead: earlier reports remain untouched
  by later-dated operations. This also handles backdated uses clamped to inception.
  Reads only sum persisted entries and never advance an expiry clock or mutate state.
  """
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.FinanceReporting.{Inception, Movement, PeriodClose}
  alias GroupStay.Reservations.{CreditLot, Group, HotelCredit, Operation, Room}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                  retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  @doc "Captures inception inside the first start operation's write transaction."
  def start(operation) do
    with {:ok, starts_on} <- reporting_date(operation["starts_on"]) do
      if Repo.get(Inception, 1) do
        {:error, "reporting_already_started"}
      else
        cash =
          Repo.all(
            from group in Group,
              group_by: group.property_id,
              select: {group.property_id, sum(group.deposit_paid_cents - group.credit_paid_cents)}
          )
          |> Map.new()

        applied = Repo.one(from group in Group, select: coalesce(sum(group.credit_paid_cents), 0))

        Repo.insert!(%Inception{
          id: 1,
          starts_on: starts_on,
          opening_cash: cash,
          opening_credit_cents: applied + HotelCredit.available_liability(starts_on)
        })

        context = %{
          operation_id: operation["operation_id"],
          posted_on: starts_on,
          late_adjustment: false
        }

        Repo.all(
          from lot in CreditLot, where: lot.expires_on >= ^starts_on and lot.remaining_cents > 0
        )
        |> Enum.each(&schedule_expiry(context, &1, &1.remaining_cents))

        {:ok, %{starts_on: starts_on}}
      end
    end
  end

  @doc "Publishes a strictly advancing cutoff inside the operation's write transaction."
  def close(operation) do
    with {:ok, period_end_on} <- Operation.date(operation["period_end_on"]),
         %Inception{} = inception <- Repo.get(Inception, 1),
         true <- Date.compare(period_end_on, inception.starts_on) != :lt,
         cutoff = latest_cutoff(),
         true <- is_nil(cutoff) or Date.compare(period_end_on, cutoff) == :gt do
      Repo.insert!(%PeriodClose{
        operation_id: operation["operation_id"],
        period_end_on: period_end_on
      })

      {:ok, %{period_end_on: period_end_on}}
    else
      _ -> {:error, "invalid_period"}
    end
  end

  @doc "Builds a posting context only for first submissions; durable retries bypass this."
  def context(operation) do
    with {:ok, date} <- Operation.date(operation["occurred_on"]),
         %Inception{} = inception <- Repo.get(Inception, 1) do
      original_date = later(date, inception.starts_on)
      cutoff = latest_cutoff()
      posted_on = if cutoff, do: later(original_date, Date.add(cutoff, 1)), else: original_date

      %{
        operation_id: operation["operation_id"],
        posted_on: posted_on,
        late_adjustment: Date.compare(posted_on, original_date) == :gt
      }
    else
      _ -> nil
    end
  end

  def cash(context, property_id, classification, amount),
    do: entry(context, property_id, classification, amount)

  def credit(context, classification, amount), do: entry(context, nil, classification, amount)

  @doc "Journals cash reclassification at the room's property, including settled reversals."
  def cash_disposition(nil, _allocation, _amount, _disposition), do: :ok

  def cash_disposition(context, allocation, amount, disposition) do
    property =
      Repo.one!(
        from room in Room,
          join: group in Group,
          on: group.group_id == room.group_id,
          where: room.id == ^allocation.room_id,
          select: group.property_id
      )

    if allocation.disposition != "held",
      do: cash(context, property, allocation.disposition <> "_cents", -amount)

    cash(context, property, disposition <> "_cents", amount)
  end

  def schedule_expiry(nil, _lot, _amount), do: :ok

  def schedule_expiry(context, lot, amount) do
    expires_on = Date.add(lot.expires_on, 1)
    expiry = later(expires_on, context.posted_on)

    # Future scheduled expiry stays ordinary even when the originating operation
    # was late. Only offsets pushed past a closed expiry day are late adjustments.
    late? = context.late_adjustment and Date.compare(expires_on, context.posted_on) == :lt
    credit(%{context | posted_on: expiry, late_adjustment: late?}, "expired_cents", amount)
  end

  @doc "Expired unspent credit has already left liability and cannot leave it twice."
  def revoke(nil, _lot, _amount), do: :ok

  def revoke(context, lot, amount) do
    if Date.compare(lot.expires_on, context.posted_on) != :lt do
      credit(context, "revoked_cents", amount)
      schedule_expiry(context, lot, -amount)
    end
  end

  @doc "Returns one reporting day from a consistent database snapshot, without changing state."
  def daily_report(value) do
    with {:ok, date} <- reporting_date(value) do
      {:ok, result} = Repo.transaction(fn -> report(date) end)
      result
    end
  end

  defp report(date) do
    case Repo.get(Inception, 1) do
      %Inception{} = inception ->
        if Date.compare(date, inception.starts_on) == :lt,
          do: {:error, "report_not_available"},
          else: {:ok, build_report(inception, date)}

      nil ->
        {:error, "report_not_available"}
    end
  end

  defp build_report(inception, date) do
    # Aggregate in SQL to bound application memory by properties and classifications,
    # rather than loading every historical journal entry.
    totals =
      Repo.all(
        from movement in Movement,
          where: movement.posted_on <= ^date,
          group_by: [
            movement.property_id,
            movement.classification,
            movement.posted_on == ^date,
            movement.late_adjustment
          ],
          select:
            {movement.property_id, movement.classification, movement.posted_on == ^date,
             movement.late_adjustment, sum(movement.amount_cents)}
      )

    {credit, cash} = Enum.split_with(totals, fn {property, _, _, _, _} -> is_nil(property) end)
    cash = Enum.group_by(cash, &elem(&1, 0))

    properties =
      (Map.keys(inception.opening_cash) ++ Map.keys(cash)) |> Enum.uniq() |> Enum.sort()

    cash_rows =
      Enum.map(properties, fn property ->
        {prior, today, late} = movement_totals(Map.get(cash, property, []), @cash_fields)
        opening = Map.get(inception.opening_cash, property, 0) + cash_delta(prior)

        row = %{
          property_id: property,
          opening_held_cents: opening,
          movements: today,
          closing_held_cents: opening + cash_delta(today) + cash_delta(late)
        }

        {row, %{property_id: property, movements: late}}
      end)

    cash =
      cash_rows
      |> Enum.reject(fn {row, late} ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          zero?(row.movements) and zero?(late.movements)
      end)
      |> Enum.map(&elem(&1, 0))

    late_cash =
      cash_rows |> Enum.map(&elem(&1, 1)) |> Enum.reject(&zero?(&1.movements))

    {prior, today, late_credit} = movement_totals(credit, @credit_fields)
    opening = inception.opening_credit_cents + credit_delta(prior)
    cutoff = latest_cutoff()

    %{
      date: Date.to_iso8601(date),
      status: if(cutoff && Date.compare(date, cutoff) != :gt, do: "closed", else: "open"),
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: today,
        closing_liability_cents: opening + credit_delta(today) + credit_delta(late_credit)
      },
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp movement_totals(rows, fields) do
    zero = Map.new(fields, &{&1, 0})

    Enum.reduce(rows, {zero, zero, zero}, fn {_, field, today?, late?, amount},
                                             {prior, today, late} ->
      cond do
        not today? -> {Map.update!(prior, field, &(&1 + amount)), today, late}
        late? -> {prior, today, Map.update!(late, field, &(&1 + amount))}
        true -> {prior, Map.update!(today, field, &(&1 + amount)), late}
      end
    end)
  end

  defp zero?(movements), do: Enum.all?(movements, fn {_, amount} -> amount == 0 end)

  defp latest_cutoff,
    do: Repo.one(from close in PeriodClose, select: max(close.period_end_on))

  defp cash_delta(movements),
    do:
      movements["received_cents"] + movements["transferred_in_cents"] -
        movements["transferred_out_cents"] - movements["refunded_cents"] -
        movements["retained_cents"] -
        movements["converted_to_credit_cents"] - movements["reduced_cents"] -
        movements["charged_back_cents"]

  defp credit_delta(movements),
    do:
      movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
        movements["revoked_cents"] - movements["absorbed_cents"]

  defp entry(nil, _, _, _), do: :ok
  defp entry(_, _, _, 0), do: :ok

  defp entry(context, property, classification, amount) do
    Repo.insert!(%Movement{
      operation_id: context.operation_id,
      posted_on: context.posted_on,
      property_id: property,
      classification: classification,
      amount_cents: amount,
      late_adjustment: context.late_adjustment
    })

    :ok
  end

  defp reporting_date(value) do
    case Operation.date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
