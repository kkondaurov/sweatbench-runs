defmodule GroupStay.MoneyTest do
  use ExUnit.Case, async: true

  alias GroupStay.Money

  test "rounds a percentage to the nearest cent" do
    assert Money.percent(1002, 20) == 200
    assert Money.percent(1003, 20) == 201
    assert Money.percent(1000, 20) == 200
  end

  test "rounds an exact half-cent upward" do
    assert Money.percent(1, 50) == 1
    assert Money.percent(5, 10) == 1
    assert Money.percent(15, 10) == 2
  end
end
