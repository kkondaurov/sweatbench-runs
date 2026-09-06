defmodule GroupStay.OperationsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations

  describe "round_half_up_cents/2" do
    test "rounds percentage amounts to the nearest cent" do
      assert Operations.round_half_up_cents(45000, 20) == 9000
      assert Operations.round_half_up_cents(52500, 20) == 10500
      assert Operations.round_half_up_cents(30007, 20) == 6001
      assert Operations.round_half_up_cents(30008, 20) == 6002
      assert Operations.round_half_up_cents(30009, 20) == 6002
      assert Operations.round_half_up_cents(0, 20) == 0
    end

    test "rounds an exact half cent upward" do
      assert Operations.round_half_up_cents(1, 50) == 1
      assert Operations.round_half_up_cents(3, 50) == 2
      assert Operations.round_half_up_cents(5, 10) == 1
    end
  end
end
