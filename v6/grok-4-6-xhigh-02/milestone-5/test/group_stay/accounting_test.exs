defmodule GroupStay.AccountingTest do
  use ExUnit.Case, async: true

  alias GroupStay.Accounting

  test "telescoping entitlements use running 10% bonus with half-up rounding" do
    assert Accounting.telescoping_entitlements([{"pay-1", 1000}, {"pay-2", 1000}]) == [
             {"pay-1", 1000, 1100},
             {"pay-2", 1000, 1100}
           ]

    assert Accounting.telescoping_entitlements([{"pay-1", 5}, {"pay-2", 5}]) == [
             {"pay-1", 5, 6},
             {"pay-2", 5, 5}
           ]

    assert Accounting.telescoping_entitlements([{nil, 1000}, {"pay-1", 4000}]) == [
             {nil, 1000, 1100},
             {"pay-1", 4000, 4400}
           ]
  end
end
