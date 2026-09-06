defmodule GroupStay.OperationsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations

  describe "deposit math" do
    test "flexible deposit is twenty percent of lodging, rounded half up" do
      assert Operations.deposit_for_room(3, 15_000, "flexible") == 9_000
      assert Operations.deposit_for_room(3, 17_500, "flexible") == 10_500
      assert Operations.deposit_for_room(1, 101, "flexible") == 20
      assert Operations.deposit_for_room(1, 102, "flexible") == 20
      assert Operations.deposit_for_room(1, 103, "flexible") == 21
    end

    test "advance purchase deposit is the full lodging amount" do
      assert Operations.deposit_for_room(2, 10_000, "advance_purchase") == 20_000
      assert Operations.deposit_for_room(1, 15_500, "advance_purchase") == 15_500
    end

    test "round_cents_half_up rounds an exact half cent upward" do
      assert Operations.round_cents_half_up(1, 2) == 1
      assert Operations.round_cents_half_up(5, 10) == 1
      assert Operations.round_cents_half_up(4, 10) == 0
      assert Operations.round_cents_half_up(1, 3) == 0
      assert Operations.round_cents_half_up(2, 3) == 1
    end
  end

  describe "structure rejections" do
    test "rejects an unknown operation type" do
      op = %{"operation_id" => "op-1", "type" => "teleport", "occurred_on" => "2026-10-03"}

      assert Operations.apply_operation(op) ==
               %{"operation_id" => "op-1", "status" => "rejected", "code" => "invalid_operation"}
    end

    test "rejects a missing type" do
      op = %{"operation_id" => "op-1", "occurred_on" => "2026-10-03"}

      assert Operations.apply_operation(op) ==
               %{"operation_id" => "op-1", "status" => "rejected", "code" => "invalid_operation"}
    end

    test "rejects a non-object operation" do
      assert Operations.apply_operation("open now") ==
               %{"status" => "rejected", "code" => "invalid_operation"}
    end

    test "rejects an operation without an operation id" do
      op = Map.delete(valid_payment(), "operation_id")

      assert Operations.apply_operation(op) ==
               %{"status" => "rejected", "code" => "invalid_operation"}
    end

    test "rejects an unusable occurred_on" do
      op = %{valid_payment() | "occurred_on" => "tomorrow"}

      assert Operations.apply_operation(op)["code"] == "invalid_operation"
    end

    test "rejects a payment without an amount" do
      op = Map.delete(valid_payment(), "amount_cents")

      assert Operations.apply_operation(op)["code"] == "invalid_operation"
    end

    test "rejects an amount that is not an integer" do
      for amount <- ["100", 100.5, true] do
        op = valid_payment()
        op = Map.put(op, "amount_cents", amount)

        assert Operations.apply_operation(op)["code"] == "invalid_operation"
      end
    end

    test "rejects a reschedule without a new arrival date" do
      op = %{
        "operation_id" => "op-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1"
      }

      assert Operations.apply_operation(op)["code"] == "invalid_operation"
    end

    test "rejects an open_group without rooms" do
      op =
        %{
          "operation_id" => "op-1",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "g-1",
          "guest_id" => "guest-1",
          "property_id" => "prop-1",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible"
        }

      assert Operations.apply_operation(op)["code"] == "invalid_operation"
    end

    defp valid_payment do
      %{
        "operation_id" => "op-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1",
        "amount_cents" => 100
      }
    end
  end
end
