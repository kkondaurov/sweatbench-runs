defmodule GroupStayWeb.FinanceJSON do
  @moduledoc """
  One day of finance reporting: how held cash moved at each property and how the hotel-credit
  liability moved across the company.

  Every movement column is stated even when it is zero, and each property's opening balance, its
  movements, and its closing balance add up. Movements a period close pushed onto the day are
  stated again under `late_adjustments`, so the day's total movement in a classification is its
  ordinary value plus its late-adjustment value.
  """

  def daily_report(%{report: report}) do
    %{
      data: %{
        date: report.date,
        status: report.status,
        cash: Enum.map(report.cash, &property/1),
        credit: credit(report.credit),
        late_adjustments: %{
          cash: Enum.map(report.late_cash, &late/1),
          credit: credit_movements(report.credit.late_movements)
        }
      }
    }
  end

  def error(%{code: code}), do: %{error: %{code: code}}

  defp property(entry) do
    %{
      property_id: entry.property_id,
      opening_held_cents: entry.opening_cents,
      movements: cash_movements(entry.movements),
      closing_held_cents: entry.closing_cents
    }
  end

  # A late adjustment states only what moved: the day's balances already account for it.
  defp late(entry) do
    %{property_id: entry.property_id, movements: cash_movements(entry.late_movements)}
  end

  defp credit(entry) do
    %{
      opening_liability_cents: entry.opening_cents,
      movements: credit_movements(entry.movements),
      closing_liability_cents: entry.closing_cents
    }
  end

  defp cash_movements(movements) do
    %{
      received_cents: movement(movements, "received"),
      transferred_in_cents: movement(movements, "transferred_in"),
      transferred_out_cents: movement(movements, "transferred_out"),
      refunded_cents: movement(movements, "refunded"),
      retained_cents: movement(movements, "retained"),
      converted_to_credit_cents: movement(movements, "converted_to_credit"),
      reduced_cents: movement(movements, "reduced"),
      charged_back_cents: movement(movements, "charged_back")
    }
  end

  defp credit_movements(movements) do
    %{
      issued_cents: movement(movements, "issued"),
      expired_cents: movement(movements, "expired"),
      consumed_cents: movement(movements, "consumed"),
      revoked_cents: movement(movements, "revoked"),
      absorbed_cents: movement(movements, "absorbed")
    }
  end

  defp movement(movements, kind), do: Map.fetch!(movements, kind)
end
