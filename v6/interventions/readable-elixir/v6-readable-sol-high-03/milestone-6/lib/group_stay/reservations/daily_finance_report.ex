defmodule GroupStay.Reservations.DailyFinanceReport do
  @moduledoc """
  Builds a daily finance report from the reporting inception and journal.

  The builder is deliberately read-only. Automatic credit expiry is derived
  from its schedule, so reports remain independent of read order and can be
  revised by a later operation posted to an earlier open day.
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

  def build(period, date) do
    cash_movements = movements("cash", date)
    earlier_cash = earlier_movements("cash", date)

    opening_cash =
      Repo.all(
        from opening in FinanceCashOpening,
          where: opening.reporting_period_id == ^period.id,
          select: {opening.property_id, opening.held_cents}
      )
      |> Map.new()
      |> apply_cash_movements(earlier_cash)

    credit_movements = credit_movement_totals(date)
    prior_credit_movements = prior_credit_movement_totals(date)
    opening_credit = period.opening_credit_liability_cents + credit_impact(prior_credit_movements)

    %{
      date: date,
      status: "open",
      cash: build_cash_entries(opening_cash, cash_movements),
      credit: %{
        opening_liability_cents: opening_credit,
        movements: credit_movements,
        closing_liability_cents: opening_credit + credit_impact(credit_movements)
      }
    }
  end

  defp movements(account, date) do
    Repo.all(
      from movement in FinanceMovement,
        where: movement.account == ^account and movement.posting_date == ^date,
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

  defp build_cash_entries(opening_cash, movements) do
    by_property = Enum.group_by(movements, &elem(&1, 0))

    (Map.keys(opening_cash) ++ Map.keys(by_property))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      totals =
        Map.new(@cash_classifications, &{String.to_atom(&1 <> "_cents"), 0})
        |> add_classified_movements(Map.get(by_property, property_id, []))

      opening = Map.get(opening_cash, property_id, 0)
      closing = opening + cash_impact(totals)

      %{
        property_id: property_id,
        opening_held_cents: opening,
        movements: totals,
        closing_held_cents: closing
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        Enum.all?(entry.movements, fn {_field, amount} -> amount == 0 end)
    end)
  end

  defp add_classified_movements(totals, movements) do
    Enum.reduce(movements, totals, fn {_property, classification, amount}, result ->
      Map.update!(result, String.to_existing_atom(classification <> "_cents"), &(&1 + amount))
    end)
  end

  defp cash_impact("received", amount), do: amount
  defp cash_impact("transferred_in", amount), do: amount
  defp cash_impact(_classification, amount), do: -amount

  defp cash_impact(totals) do
    totals.received_cents + totals.transferred_in_cents - totals.transferred_out_cents -
      totals.refunded_cents - totals.retained_cents - totals.converted_to_credit_cents -
      totals.reduced_cents - totals.charged_back_cents
  end

  defp credit_movement_totals(date) do
    totals = classified_credit_movements(:on, date)
    Map.update!(totals, :expired_cents, &(&1 + scheduled_expiry_on(date)))
  end

  defp prior_credit_movement_totals(date) do
    totals = classified_credit_movements(:before, date)
    Map.update!(totals, :expired_cents, &(&1 + scheduled_expiry_before(date)))
  end

  defp classified_credit_movements(comparison, date) do
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
