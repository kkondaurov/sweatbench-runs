defmodule GroupStay.OperationsTest do
  use ExUnit.Case, async: true

  alias GroupStay.Operations

  describe "parse/1" do
    test "parses a complete open_group operation" do
      {:ok, op} =
        Operations.parse(%{
          "operation_id" => "op-1001",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "group-81",
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        })

      assert op.type == :open_group
      assert op.operation_id == "op-1001"
      assert op.group_id == "group-81"
      assert op.occurred_on == ~D[2026-10-03]
      assert op.arrival_on == ~D[2026-12-10]
      assert op.departure_on == ~D[2026-12-13]

      assert op.rooms == [
               %{room_id: "room-a", nightly_rate_cents: 15_000},
               %{room_id: "room-b", nightly_rate_cents: 17_500}
             ]

      assert op.expected_revision == nil
    end

    test "rejects non-map operations and unknown types as invalid_operation" do
      assert {:error, :invalid_operation} = Operations.parse(nil)
      assert {:error, :invalid_operation} = Operations.parse([])

      assert {:error, :invalid_operation} =
               Operations.parse(%{"operation_id" => "op", "type" => ""})

      base = %{"operation_id" => "op", "occurred_on" => "2026-10-03"}

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "type", "teleport_group"))

      assert {:error, :invalid_operation} = Operations.parse(Map.put(base, "type", 7))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "type", "cancel_group"))
    end

    test "requires a string operation_id" do
      base = %{"type" => "cancel_group", "occurred_on" => "2026-10-03", "group_id" => "g1"}

      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "operation_id"))
      assert {:error, :invalid_operation} = Operations.parse(Map.put(base, "operation_id", ""))
      assert {:error, :invalid_operation} = Operations.parse(Map.put(base, "operation_id", 5))
    end

    test "requires a parseable common occurred_on date" do
      base = %{"type" => "cancel_group", "operation_id" => "op", "group_id" => "g1"}

      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "occurred_on"))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "occurred_on", "yesterday"))
    end

    test "an expected_revision must be a positive integer when present" do
      base = %{
        "type" => "cancel_group",
        "operation_id" => "op",
        "occurred_on" => "2026-10-03",
        "group_id" => "g1"
      }

      assert {:ok, %{expected_revision: 3}} =
               Operations.parse(Map.put(base, "expected_revision", 3))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "expected_revision", 0))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "expected_revision", "1"))
    end

    test "open_group structural problems are invalid_operation" do
      base = open_raw()

      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "guest_id"))
      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "property_id"))
      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "rate_plan"))
      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "rooms"))
      assert {:error, :invalid_operation} = Operations.parse(Map.put(base, "rooms", "room-a"))
      assert {:error, :invalid_operation} = Operations.parse(Map.put(base, "rooms", ["room-a"]))

      assert {:error, :invalid_operation} =
               base
               |> put_in(["rooms", Access.at!(0), "nightly_rate_cents"], "15000")
               |> Operations.parse()

      assert {:error, :invalid_operation} =
               base
               |> put_in(["rooms", Access.at!(0), "room_id"], "")
               |> Operations.parse()
    end

    test "open_group unparseable stay dates are invalid_stay" do
      base = open_raw()

      assert {:error, :invalid_stay} = Operations.parse(Map.put(base, "arrival_on", "next week"))

      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "arrival_on"))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "arrival_on", 20_261_210))

      assert {:error, :invalid_stay} =
               Operations.parse(Map.put(base, "departure_on", "2026-13-40"))
    end

    test "record_cash_payment amount validation" do
      missing_amount =
        %{
          "operation_id" => "op",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-03",
          "group_id" => "g1"
        }
        |> Map.delete("amount_cents")

      assert {:error, :invalid_operation} = Operations.parse(missing_amount)

      bad_amounts = [0, -100, "1000", 10.5]

      Enum.each(bad_amounts, fn amount ->
        raw = %{
          "operation_id" => "op",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-03",
          "group_id" => "g1",
          "amount_cents" => amount
        }

        assert {:error, :invalid_amount} = Operations.parse(raw)
      end)

      ok = %{
        "operation_id" => "op",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "g1",
        "amount_cents" => 1
      }

      assert {:ok, %{amount_cents: 1}} = Operations.parse(ok)
    end

    test "cancel_group refund_method validation" do
      base = %{
        "operation_id" => "op",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g1"
      }

      assert {:ok, %{refund_method: :cash}} = Operations.parse(base)

      assert {:ok, %{refund_method: :cash}} =
               Operations.parse(Map.put(base, "refund_method", "cash"))

      assert {:ok, %{refund_method: :hotel_credit}} =
               Operations.parse(Map.put(base, "refund_method", "hotel_credit"))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "refund_method", "store_credit"))

      assert {:error, :invalid_operation} =
               Operations.parse(Map.put(base, "refund_method", 3))
    end

    test "apply_hotel_credit amount validation" do
      base = %{
        "operation_id" => "op",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-03",
        "group_id" => "g1"
      }

      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "amount_cents"))

      assert {:ok, %{amount_cents: 500, type: :apply_hotel_credit}} =
               Operations.parse(Map.put(base, "amount_cents", 500))

      Enum.each([0, -100, "1000", 10.5], fn amount ->
        assert {:error, :invalid_amount} =
                 Operations.parse(Map.put(base, "amount_cents", amount))
      end)
    end

    test "reschedule_group new_arrival validation" do
      base = %{
        "operation_id" => "op",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "g1"
      }

      assert {:error, :invalid_operation} = Operations.parse(Map.delete(base, "new_arrival_on"))
      assert {:error, :invalid_stay} = Operations.parse(Map.put(base, "new_arrival_on", "soon"))

      assert {:ok, %{new_arrival_on: ~D[2026-12-20]}} =
               Operations.parse(Map.put(base, "new_arrival_on", "2026-12-20"))
    end

    test "accepts atom-keyed maps" do
      raw = %{
        operation_id: "op",
        type: :cancel_group,
        occurred_on: "2026-10-03",
        group_id: "g1"
      }

      assert {:ok, %{type: :cancel_group}} = Operations.parse(raw)
    end
  end

  defp open_raw do
    %{
      "operation_id" => "op",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end
end
