defmodule GroupStay.FinanceHelpers do
  @moduledoc false
  import GroupStay.PartnerOperations
  import ExUnit.Assertions

  def start_reporting(starts_on \\ "2026-11-01", attributes \\ %{}) do
    operation("start_finance_reporting", Map.put(attributes, "starts_on", starts_on))
    |> Map.delete("group_id")
  end

  def close_period(period_end_on \\ "2026-11-01", attributes \\ %{}) do
    operation("close_finance_period", Map.put(attributes, "period_end_on", period_end_on))
    |> Map.delete("group_id")
  end

  def late_adjustments(cash \\ [], credit \\ %{}) do
    %{"cash" => cash, "credit" => credit_row(0, credit, 0)["movements"]}
  end

  def late_cash_row(property, movements) do
    cash_row(property, 0, movements, 0) |> Map.take(~w(property_id movements))
  end

  def cash_row(property, opening, movements, closing) do
    %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" =>
        Map.merge(
          Map.new(
            ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
            &{&1, 0}
          ),
          movements
        ),
      "closing_held_cents" => closing
    }
  end

  def credit_row(opening \\ 0, movements \\ %{}, closing \\ 0) do
    %{
      "opening_liability_cents" => opening,
      "movements" =>
        Map.merge(
          Map.new(
            ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
            &{&1, 0}
          ),
          movements
        ),
      "closing_liability_cents" => closing
    }
  end

  def assert_balanced(report) do
    assert Map.keys(report) |> Enum.sort() == ~w(cash credit date late_adjustments status)
    assert report["status"] in ["open", "closed"]
    rows = report["cash"]
    properties = Enum.map(rows, & &1["property_id"])
    assert properties == Enum.sort(Enum.uniq(properties))

    late = report["late_adjustments"]
    assert Map.keys(late) |> Enum.sort() == ~w(cash credit)
    late_properties = Enum.map(late["cash"], & &1["property_id"])
    assert late_properties == Enum.sort(Enum.uniq(late_properties))

    for row <- late["cash"] do
      assert Map.keys(row) |> Enum.sort() == ~w(movements property_id)

      assert Map.keys(row["movements"]) |> Enum.sort() ==
               Map.keys(cash_row("", 0, %{}, 0)["movements"]) |> Enum.sort()

      assert Enum.any?(row["movements"], fn {_kind, amount} -> amount != 0 end)
      assert row["property_id"] in properties
    end

    for row <- rows do
      assert map_size(row) == 4

      assert Map.keys(row["movements"]) |> Enum.sort() ==
               Map.keys(cash_row("", 0, %{}, 0)["movements"]) |> Enum.sort()

      adjustment = Enum.find(late["cash"], &(&1["property_id"] == row["property_id"]))

      movements =
        combined_movements(
          row["movements"],
          if(adjustment, do: adjustment["movements"], else: %{})
        )

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + movements["received_cents"] +
                 movements["transferred_in_cents"] - movements["transferred_out_cents"] -
                 movements["refunded_cents"] - movements["retained_cents"] -
                 movements["converted_to_credit_cents"] - movements["reduced_cents"] -
                 movements["charged_back_cents"]
    end

    for cash <- [rows, late["cash"]] do
      assert Enum.sum(Enum.map(cash, & &1["movements"]["transferred_in_cents"])) ==
               Enum.sum(Enum.map(cash, & &1["movements"]["transferred_out_cents"]))
    end

    credit = report["credit"]
    assert map_size(credit) == 3

    for movements <- [credit["movements"], late["credit"]] do
      assert Map.keys(movements) |> Enum.sort() ==
               Map.keys(credit_row()["movements"]) |> Enum.sort()
    end

    movements = combined_movements(credit["movements"], late["credit"])

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + movements["issued_cents"] -
               movements["expired_cents"] - movements["consumed_cents"] -
               movements["revoked_cents"] - movements["absorbed_cents"]

    report
  end

  defp combined_movements(ordinary, late),
    do: Map.merge(ordinary, late, fn _kind, left, right -> left + right end)
end
