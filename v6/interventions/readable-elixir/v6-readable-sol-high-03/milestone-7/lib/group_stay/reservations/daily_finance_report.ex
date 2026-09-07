defmodule GroupStay.Reservations.DailyFinanceReport do
  @moduledoc """
  Builds a daily finance report from the reporting inception and journal.

  The builder is deliberately read-only. Automatic credit expiry is derived
  from its schedule, so open reports remain independent of read order. Closed
  reports are persisted by `FinanceReporting` instead of being rebuilt.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    FinanceCashOpening,
    FinanceCreditExpiryAdjustment,
    FinanceCreditExpirySchedule,
    FinanceMovement
  }

  @cash_classifications ~w(
    received transferred_in transferred_out refunded retained
    converted_to_credit reduced charged_back
  )
  @credit_classifications ~w(issued expired consumed revoked absorbed)

  @doc "Builds the report value for a date from the current journal."
  def build(period, date, status \\ "open") do
    ordinary_cash_movements = movements("cash", date, false)
    late_cash_movements = movements("cash", date, true)
    all_cash_movements = ordinary_cash_movements ++ late_cash_movements

    opening_cash =
      Repo.all(
        from opening in FinanceCashOpening,
          where: opening.reporting_period_id == ^period.id,
          select: {opening.property_id, opening.held_cents}
      )
      |> Map.new()
      |> apply_cash_movements(earlier_movements("cash", date))

    ordinary_credit_movements = credit_movement_totals(date, false)
    late_credit_movements = credit_movement_totals(date, true)
    prior_credit_movements = prior_credit_movement_totals(date)
    opening_credit = period.opening_credit_liability_cents + credit_impact(prior_credit_movements)

    %{
      date: date,
      status: status,
      cash: build_cash_entries(opening_cash, ordinary_cash_movements, all_cash_movements),
      credit: %{
        opening_liability_cents: opening_credit,
        movements: ordinary_credit_movements,
        closing_liability_cents:
          opening_credit + credit_impact(ordinary_credit_movements) +
            credit_impact(late_credit_movements)
      },
      late_adjustments: %{
        cash: build_late_cash_entries(late_cash_movements),
        credit: late_credit_movements
      }
    }
  end

  defp movements(account, date, late_adjustment) do
    Repo.all(
      from movement in FinanceMovement,
        where:
          movement.account == ^account and movement.posting_date == ^date and
            movement.late_adjustment == ^late_adjustment,
        group_by: [movement.property_id, movement.classification],
        select: {movement.property_id, movement.classification, sum(movement.amount_cents)}
    )
  end

  defp earlier_movements(account, date) do
    Repo.all(
      from movement in FinanceMovement,
        where:
          movement.account == ^account and not is_nil(movement.posting_date) and
            movement.posting_date < ^date,
        group_by: [movement.property_id, movement.classification],
        select: {movement.property_id, movement.classification, sum(movement.amount_cents)}
    )
  end

  defp apply_cash_movements(opening, movements) do
    Enum.reduce(movements, opening, fn {property_id, classification, amount}, balances ->
      Map.update(balances, property_id, cash_impact(classification, amount), fn balance ->
        balance + cash_impact(classification, amount)
      end)
    end)
  end

  defp build_cash_entries(opening_cash, ordinary_movements, all_movements) do
    ordinary_by_property = Enum.group_by(ordinary_movements, &elem(&1, 0))
    all_by_property = Enum.group_by(all_movements, &elem(&1, 0))

    (Map.keys(opening_cash) ++ Map.keys(all_by_property))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      ordinary_totals =
        empty_cash_movements()
        |> add_classified_movements(Map.get(ordinary_by_property, property_id, []))

      all_totals =
        empty_cash_movements()
        |> add_classified_movements(Map.get(all_by_property, property_id, []))

      opening = Map.get(opening_cash, property_id, 0)

      %{
        property_id: property_id,
        opening_held_cents: opening,
        movements: ordinary_totals,
        closing_held_cents: opening + cash_impact(all_totals),
        all_movements: all_totals
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        all_zero?(entry.all_movements)
    end)
    |> Enum.map(&Map.delete(&1, :all_movements))
  end

  defp build_late_cash_entries(movements) do
    movements
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {property_id, property_movements} ->
      %{
        property_id: property_id,
        movements: add_classified_movements(empty_cash_movements(), property_movements)
      }
    end)
    |> Enum.reject(&all_zero?(&1.movements))
  end

  defp empty_cash_movements,
    do: Map.new(@cash_classifications, &{String.to_atom(&1 <> "_cents"), 0})

  defp add_classified_movements(totals, movements) do
    Enum.reduce(movements, totals, fn {_property, classification, amount}, result ->
      Map.update!(result, String.to_existing_atom(classification <> "_cents"), &(&1 + amount))
    end)
  end

  defp all_zero?(totals), do: Enum.all?(totals, fn {_field, amount} -> amount == 0 end)

  defp cash_impact("received", amount), do: amount
  defp cash_impact("transferred_in", amount), do: amount
  defp cash_impact(_classification, amount), do: -amount

  defp cash_impact(totals) do
    totals.received_cents + totals.transferred_in_cents - totals.transferred_out_cents -
      totals.refunded_cents - totals.retained_cents - totals.converted_to_credit_cents -
      totals.reduced_cents - totals.charged_back_cents
  end

  defp credit_movement_totals(date, false) do
    totals = classified_credit_movements(:on, date, false)
    Map.update!(totals, :expired_cents, &(&1 + scheduled_expiry_on(date)))
  end

  defp credit_movement_totals(date, true),
    do: classified_credit_movements(:on, date, true)

  defp prior_credit_movement_totals(date) do
    totals = classified_credit_movements(:before, date, :all)
    Map.update!(totals, :expired_cents, &(&1 + scheduled_expiry_before(date)))
  end

  defp classified_credit_movements(comparison, date, late_adjustment) do
    query =
      from movement in FinanceMovement,
        where: movement.account == "credit" and not is_nil(movement.posting_date),
        group_by: movement.classification,
        select: {movement.classification, sum(movement.amount_cents)}

    query =
      case comparison do
        :on -> from movement in query, where: movement.posting_date == ^date
        :before -> from movement in query, where: movement.posting_date < ^date
      end

    query =
      case late_adjustment do
        :all -> query
        value -> from movement in query, where: movement.late_adjustment == ^value
      end

    Enum.reduce(Repo.all(query), empty_credit_movements(), fn {classification, amount}, totals ->
      Map.update!(totals, String.to_existing_atom(classification <> "_cents"), &(&1 + amount))
    end)
  end

  defp empty_credit_movements,
    do: Map.new(@credit_classifications, &{String.to_atom(&1 <> "_cents"), 0})

  defp scheduled_expiry_on(date) do
    Repo.all(from schedule in FinanceCreditExpirySchedule, where: schedule.expires_on == ^date)
    |> Enum.sum_by(&scheduled_expiry_amount/1)
  end

  defp scheduled_expiry_before(date) do
    Repo.all(from schedule in FinanceCreditExpirySchedule, where: schedule.expires_on < ^date)
    |> Enum.sum_by(&scheduled_expiry_amount/1)
  end

  defp scheduled_expiry_amount(schedule) do
    adjustments =
      Repo.one(
        from adjustment in FinanceCreditExpiryAdjustment,
          where:
            adjustment.credit_expiry_schedule_id == ^schedule.id and
              adjustment.posting_date < ^schedule.expires_on,
          select: coalesce(sum(adjustment.amount_cents), 0)
      )

    max(schedule.opening_available_cents + adjustments, 0)
  end

  defp credit_impact(totals) do
    totals.issued_cents - totals.expired_cents - totals.consumed_cents -
      totals.revoked_cents - totals.absorbed_cents
  end
end
