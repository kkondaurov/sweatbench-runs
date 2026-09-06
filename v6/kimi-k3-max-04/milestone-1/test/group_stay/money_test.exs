defmodule GroupStay.MoneyTest do
  use ExUnit.Case, async: true

  alias GroupStay.Money

  describe "percent/2" do
    test "rounds to the nearest cent" do
      assert Money.percent(15000, 20) == 3000
      assert Money.percent(7, 20) == 1
      assert Money.percent(2, 20) == 0
    end

    test "rounds an exact half-cent upward" do
      # 50% of 1 cent is exactly half a cent.
      assert Money.percent(1, 50) == 1
    end
  end
end
