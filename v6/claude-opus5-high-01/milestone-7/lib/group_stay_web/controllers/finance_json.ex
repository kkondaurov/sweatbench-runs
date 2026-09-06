defmodule GroupStayWeb.FinanceJSON do
  @moduledoc """
  Renders one day of finance movements.

  A published day has to read back byte for byte across processes, and the order
  a map happens to iterate in does not, so the report is rendered field by field
  in the order finance publishes it.
  """

  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditMovement
  alias Jason.OrderedObject

  @cash_columns Enum.map(CashMovement.columns(), &elem(&1, 1))
  @credit_columns CreditMovement.columns()

  def daily_report(%{report: report}) do
    %{
      data:
        object([
          {"date", report.date},
          {"status", report.status},
          {"cash", Enum.map(report.cash, &cash_entry/1)},
          {"credit", credit(report.credit)},
          {"late_adjustments", late_adjustments(report.late_adjustments)}
        ])
    }
  end

  defp cash_entry(entry) do
    object([
      {"property_id", entry.property_id},
      {"opening_held_cents", entry.opening_held_cents},
      {"movements", movements(entry.movements, @cash_columns)},
      {"closing_held_cents", entry.closing_held_cents}
    ])
  end

  defp credit(credit) do
    object([
      {"opening_liability_cents", credit.opening_liability_cents},
      {"movements", movements(credit.movements, @credit_columns)},
      {"closing_liability_cents", credit.closing_liability_cents}
    ])
  end

  # A late adjustment reports only what it moved: the balances it belongs to are
  # the day's own.
  defp late_adjustments(late) do
    object([
      {"cash", Enum.map(late.cash, &late_cash_entry/1)},
      {"credit", movements(late.credit, @credit_columns)}
    ])
  end

  defp late_cash_entry(entry) do
    object([
      {"property_id", entry.property_id},
      {"movements", movements(entry.movements, @cash_columns)}
    ])
  end

  defp movements(movements, columns),
    do: object(for column <- columns, do: {to_string(column), Map.fetch!(movements, column)})

  defp object(values), do: OrderedObject.new(values)
end
