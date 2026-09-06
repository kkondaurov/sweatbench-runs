defmodule GroupStay.OperationsTest do
  use GroupStay.DataCase, async: false

  alias GroupStay.Operations
  alias GroupStay.Operations.Operation

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
      for {amount, index} <- Enum.with_index(["100", 100.5, true]) do
        op = valid_payment()
        op = Map.put(op, "amount_cents", amount)
        op = Map.put(op, "operation_id", "op-bad-#{index}")

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

    test "rejects an apply_hotel_credit without an amount" do
      op = %{
        "operation_id" => "op-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-03",
        "group_id" => "g-1"
      }

      assert Operations.apply_operation(op)["code"] == "invalid_operation"
    end

    test "rejects an apply_hotel_credit with a non-integer amount" do
      for {amount, index} <- Enum.with_index(["100", 100.5, true]) do
        op = %{
          "operation_id" => "op-bad-#{index}",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-03",
          "group_id" => "g-1",
          "amount_cents" => amount
        }

        assert Operations.apply_operation(op)["code"] == "invalid_operation"
      end
    end

    test "rejects a cancel_group with an unrecognized refund_method" do
      for {refund_method, index} <- Enum.with_index(["bitcoin", 42, true]) do
        op = %{
          "operation_id" => "op-bad-#{index}",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "g-1",
          "refund_method" => refund_method
        }

        assert Operations.apply_operation(op)["code"] == "invalid_operation"
      end
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

  describe "durable idempotency" do
    test "remembers rejections and replays them without domain state" do
      op = %{valid_payment() | "group_id" => "missing"}

      assert Operations.apply_operation(op) ==
               %{
                 "operation_id" => "op-1",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }

      assert Operations.apply_operation(op) ==
               %{
                 "operation_id" => "op-1",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }

      assert Repo.aggregate(Operation, :count, :id) == 1
    end

    test "rejects reuse of an operation id with a different payload" do
      assert Operations.apply_operation(valid_payment())["status"] == "rejected"

      other = %{valid_payment() | "amount_cents" => 200}

      assert Operations.apply_operation(other) ==
               %{
                 "operation_id" => "op-1",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
    end

    test "does not remember operations without a string operation id" do
      for id <- [nil, 12345] do
        op = valid_payment()
        op = Map.put(op, "operation_id", id)

        assert Operations.apply_operation(op)["code"] == "invalid_operation"
      end

      assert Repo.aggregate(Operation, :count, :id) == 0
    end

    test "records the submitted content as canonical JSON" do
      Operations.apply_operation(valid_payment())

      [record] = Repo.all(Operation)
      assert record.type == "record_cash_payment"
      assert Jason.decode!(record.content) == valid_payment()
      assert Jason.decode!(record.result)["code"] == "group_not_found"
    end
  end
end
