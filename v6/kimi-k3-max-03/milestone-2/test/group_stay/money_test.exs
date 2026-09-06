defmodule GroupStay.MoneyTest do
  use ExUnit.Case, async: true

  alias GroupStay.Money

  test "percent_of/2 returns exact percentages without rounding" do
    assert Money.percent_of(15_000, 20) == 3_000
    assert Money.percent_of(255, 20) == 51
  end

  test "percent_of/2 rounds to the nearest cent" do
    # 251 * 20% = 50.2 -> 50
    assert Money.percent_of(251, 20) == 50
    # 253 * 20% = 50.6 -> 51
    assert Money.percent_of(253, 20) == 51
  end

  test "percent_of/2 rounds an exact half cent upward" do
    # 33 * 50% = 16.5 -> 17
    assert Money.percent_of(33, 50) == 17
  end
end
