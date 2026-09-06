defmodule GroupStay.OperationsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations

  describe "percentage/2" do
    test "rounds to the nearest cent" do
      assert Operations.percentage(10_002, 20) == 2_000
      assert Operations.percentage(10_003, 20) == 2_001
      assert Operations.percentage(10_004, 20) == 2_001
      assert Operations.percentage(45_000, 20) == 9_000
      assert Operations.percentage(52_500, 20) == 10_500
    end

    test "rounds an exact half-cent upward" do
      assert Operations.percentage(5, 10) == 1
      assert Operations.percentage(1, 50) == 1
      assert Operations.percentage(3, 50) == 2
    end

    test "handles zero amounts" do
      assert Operations.percentage(0, 20) == 0
    end
  end
end
