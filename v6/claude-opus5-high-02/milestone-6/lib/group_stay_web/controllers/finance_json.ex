defmodule GroupStayWeb.FinanceJSON do
  @moduledoc """
  One day of finance reporting: how held cash moved at each property and how the hotel-credit
  liability moved across the company.

  Every movement column is stated even when it is zero, and each property's opening balance, its
  movements, and its closing balance add up.
  """

  def daily_report(%{report: report}) do
    %{
      data: %{
        date: report.date,
        status: report.status,
        cash: Enum.map(report.cash, &property/1),
        credit: credit(report.credit)
      }
    }
  end

  def error(%{code: code}), do: %{error: %{code: code}}

  defp property(entry) do
    %{
      property_id: entry.property_id,
      opening_held_cents: entry.opening_cents,
      movements: %{
        received_cents: movement(entry, "received"),
        transferred_in_cents: movement(entry, "transferred_in"),
        transferred_out_cents: movement(entry, "transferred_out"),
        refunded_cents: movement(entry, "refunded"),
        retained_cents: movement(entry, "retained"),
        converted_to_credit_cents: movement(entry, "converted_to_credit"),
        reduced_cents: movement(entry, "reduced"),
        charged_back_cents: movement(entry, "charged_back")
      },
      closing_held_cents: entry.closing_cents
    }
  end

  defp credit(entry) do
    %{
      opening_liability_cents: entry.opening_cents,
      movements: %{
        issued_cents: movement(entry, "issued"),
        expired_cents: movement(entry, "expired"),
        consumed_cents: movement(entry, "consumed"),
        revoked_cents: movement(entry, "revoked"),
        absorbed_cents: movement(entry, "absorbed")
      },
      closing_liability_cents: entry.closing_cents
    }
  end

  defp movement(entry, kind), do: Map.fetch!(entry.movements, kind)
end
