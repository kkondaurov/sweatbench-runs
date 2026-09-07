defmodule GroupStay.FinanceHelpers do
  @moduledoc false
  import GroupStay.PartnerOperations
  import ExUnit.Assertions

  def start_reporting(starts_on \\ "2026-11-01", attributes \\ %{}) do
    operation("start_finance_reporting", Map.put(attributes, "starts_on", starts_on))
    |> Map.delete("group_id")
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
    assert Map.keys(report) |> Enum.sort() == ~w(cash credit date status)
    assert report["status"] == "open"
    rows = report["cash"]
    properties = Enum.map(rows, & &1["property_id"])
    assert properties == Enum.sort(Enum.uniq(properties))

    for row <- rows do
      movements = row["movements"]
      assert map_size(row) == 4
      assert map_size(movements) == 8

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + movements["received_cents"] +
                 movements["transferred_in_cents"] - movements["transferred_out_cents"] -
                 movements["refunded_cents"] - movements["retained_cents"] -
                 movements["converted_to_credit_cents"] - movements["reduced_cents"] -
                 movements["charged_back_cents"]
    end

    assert Enum.sum(Enum.map(rows, & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(rows, & &1["movements"]["transferred_out_cents"]))

    credit = report["credit"]
    movements = credit["movements"]
    assert map_size(credit) == 3
    assert map_size(movements) == 5

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + movements["issued_cents"] -
               movements["expired_cents"] - movements["consumed_cents"] -
               movements["revoked_cents"] - movements["absorbed_cents"]

    report
  end
end
