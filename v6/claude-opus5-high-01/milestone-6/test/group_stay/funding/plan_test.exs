defmodule GroupStay.Funding.PlanTest do
  use ExUnit.Case, async: true

  alias GroupStay.Funding.Plan

  describe "fill/2" do
    test "fills one capacity before moving to the next" do
      assert Plan.fill([9000, 10_500], 10_000) == {[{0, 9000}, {1, 1000}], 0}
    end

    test "stops as soon as the amount runs out" do
      assert Plan.fill([9000, 10_500], 4000) == {[{0, 4000}], 0}
    end

    test "skips a capacity that is already full" do
      assert Plan.fill([0, 10_500], 4000) == {[{1, 4000}], 0}
    end

    test "reports whatever it could not place" do
      assert Plan.fill([100, 200], 500) == {[{0, 100}, {1, 200}], 200}
    end

    test "places nothing when there is nothing to place" do
      assert Plan.fill([9000], 0) == {[], 0}
      assert Plan.fill([], 500) == {[], 500}
    end
  end

  describe "carry_forward/4" do
    test "puts the unattributed senior block ahead of the recorded funding" do
      records = [%{operation_id: "pay-2", kind: :cash, amount_cents: 2000}]

      assert Plan.carry_forward(12_000, 0, records, []) == [
               %{kind: :cash, operation_id: nil, lot_ref: nil, amount_cents: 10_000},
               %{kind: :cash, operation_id: "pay-2", lot_ref: nil, amount_cents: 2000}
             ]
    end

    test "allocates the senior block's cash before its credit lots" do
      assert Plan.carry_forward(500, 3000, [], [{7, 1800}, {9, 1200}]) == [
               %{kind: :cash, operation_id: nil, lot_ref: nil, amount_cents: 500},
               %{kind: :credit, operation_id: nil, lot_ref: 7, amount_cents: 1800},
               %{kind: :credit, operation_id: nil, lot_ref: 9, amount_cents: 1200}
             ]
    end

    test "keeps recorded funding in durable-record commit order" do
      records = [
        %{operation_id: "credit-1", kind: :credit, amount_cents: 1200},
        %{operation_id: "pay-1", kind: :cash, amount_cents: 4000}
      ]

      assert Plan.carry_forward(4000, 2000, records, [{7, 800}, {9, 1200}]) == [
               %{kind: :credit, operation_id: nil, lot_ref: 7, amount_cents: 800},
               %{kind: :credit, operation_id: "credit-1", lot_ref: 9, amount_cents: 1200},
               %{kind: :cash, operation_id: "pay-1", lot_ref: nil, amount_cents: 4000}
             ]
    end

    test "splits a recorded credit application across the lots it consumed" do
      records = [%{operation_id: "credit-1", kind: :credit, amount_cents: 3000}]

      assert Plan.carry_forward(0, 3000, records, [{7, 1800}, {9, 1200}]) == [
               %{kind: :credit, operation_id: "credit-1", lot_ref: 7, amount_cents: 1800},
               %{kind: :credit, operation_id: "credit-1", lot_ref: 9, amount_cents: 1200}
             ]
    end

    test "has no senior block when the records account for everything" do
      records = [
        %{operation_id: "pay-1", kind: :cash, amount_cents: 4000},
        %{operation_id: "credit-1", kind: :credit, amount_cents: 1000}
      ]

      assert Plan.carry_forward(4000, 1000, records, [{7, 1000}]) == [
               %{kind: :cash, operation_id: "pay-1", lot_ref: nil, amount_cents: 4000},
               %{kind: :credit, operation_id: "credit-1", lot_ref: 7, amount_cents: 1000}
             ]
    end

    test "carries nothing forward for a group that was never funded" do
      assert Plan.carry_forward(0, 0, [], []) == []
    end
  end
end
