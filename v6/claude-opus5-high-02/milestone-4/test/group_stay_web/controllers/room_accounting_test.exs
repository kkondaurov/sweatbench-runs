defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  # Two rooms for one night: room-a is priced at a 2_000 deposit and room-b at 4_000.
  defp two_rooms(overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room("room-a", 10_000), room("room-b", 20_000)]
        },
        overrides
      )
    )
  end

  describe "room accounting" do
    test "a room carries its own deposit and the funding held against it" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      assert read_rooms("group-81") == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 10_000,
                 "status" => "active",
                 "deposit_due_cents" => 2_000,
                 "cash_paid_cents" => 2_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 20_000,
                 "status" => "active",
                 "deposit_due_cents" => 4_000,
                 "cash_paid_cents" => 1_000,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "funding fills one room's deposit before the next, operation by operation" do
      submit([
        two_rooms(),
        record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 1_000}),
        record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 2_000})
      ])

      assert [
               %{"cash_paid_cents" => 2_000},
               %{"cash_paid_cents" => 1_000}
             ] = read_rooms("group-81")
    end

    test "credit fills the rooms in the same order as cash" do
      issue_credit(group_id: "group-source", cash_cents: 5_000, operation_id: "cancel-17")

      submit([
        two_rooms(),
        record_cash_payment(%{"amount_cents" => 1_000}),
        apply_hotel_credit(%{"amount_cents" => 3_000})
      ])

      assert [
               %{"cash_paid_cents" => 1_000, "credit_paid_cents" => 1_000},
               %{"cash_paid_cents" => 0, "credit_paid_cents" => 2_000}
             ] = read_rooms("group-81")
    end

    test "the group's totals are the sums of its active rooms" do
      submit([
        two_rooms(),
        record_cash_payment(%{"amount_cents" => 3_000}),
        cancel_rooms(%{"room_ids" => ["room-a"]})
      ])

      {200, %{"data" => group}} = read_group("group-81")

      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 20_000
      assert group["deposit_due_cents"] == 4_000
      assert group["cash_paid_cents"] == 1_000
      assert group["deposit_paid_cents"] == 1_000
      assert group["outstanding_deposit_cents"] == 3_000
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and leaves the others untouched" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      result = submit_one(cancel_rooms(%{"room_ids" => ["room-a"]}))

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert [
               %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
               %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 1_000}
             ] = read_rooms("group-81")

      assert read_ledger()["cash_held_cents"] == 1_000
      assert read_ledger()["cash_refunded_cents"] == 2_000
    end

    test "reports the cancelled rooms in the group's own order" do
      submit([
        two_rooms(%{
          "rooms" => [room("room-a", 10_000), room("room-b", 20_000), room("room-c", 30_000)]
        })
      ])

      result = submit_one(cancel_rooms(%{"room_ids" => ["room-c", "room-a"]}))

      assert result["cancelled_room_ids"] == ["room-a", "room-c"]
      assert [%{"room_id" => "room-b", "status" => "active"}] = active_rooms("group-81")
    end

    test "retains the cash of rooms cancelled outside the refund window" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      result =
        submit_one(cancel_rooms(%{"occurred_on" => "2026-11-27", "room_ids" => ["room-a"]}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 2_000
      assert read_ledger()["cash_retained_cents"] == 2_000
    end

    test "computes the credit bonus once on the selected rooms' combined cash" do
      submit([
        two_rooms(%{"rooms" => [room("room-a", 125), room("room-b", 125)]}),
        record_cash_payment(%{"amount_cents" => 50})
      ])

      # Each room holds 25. A bonus per room would round to 3 twice; one bonus on 50 is 5.
      result =
        submit_one(
          cancel_rooms(%{
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          })
        )

      assert result["credit_issued_cents"] == 55
      assert read_credit("guest-22")["available_cents"] == 55
    end

    test "returns the credit that funded the cancelled rooms to its lots" do
      issue_credit(group_id: "group-source", cash_cents: 5_000, operation_id: "cancel-17")

      submit([two_rooms(), apply_hotel_credit(%{"amount_cents" => 5_500})])

      assert read_credit("guest-22")["available_cents"] == 0

      # room-a holds 2_000 of the lot and room-b the other 3_500.
      submit_one(cancel_rooms(%{"room_ids" => ["room-b"]}))

      assert read_credit("guest-22")["available_cents"] == 3_500
      assert read_ledger()["credit_liability_cents"] == 5_500
    end

    test "keeps the credit that funded rooms cancelled without a refund" do
      issue_credit(group_id: "group-source", cash_cents: 5_000, operation_id: "cancel-17")

      submit([two_rooms(), apply_hotel_credit(%{"amount_cents" => 5_500})])

      submit_one(cancel_rooms(%{"occurred_on" => "2026-11-27", "room_ids" => ["room-b"]}))

      assert read_credit("guest-22")["available_cents"] == 0
      assert read_ledger()["credit_liability_cents"] == 2_000
    end

    test "cancels the group when the last active room leaves it" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      submit_one(cancel_rooms(%{"operation_id" => "op-first", "room_ids" => ["room-a"]}))

      result =
        submit_one(cancel_rooms(%{"operation_id" => "op-last", "room_ids" => ["room-b"]}))

      assert result["refunded_cents"] == 1_000

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["revision"] == 4
    end

    test "cancel_group settles only the rooms that are left" do
      submit([
        two_rooms(),
        record_cash_payment(%{"amount_cents" => 3_000}),
        cancel_rooms(%{"room_ids" => ["room-a"]})
      ])

      result = submit_one(cancel_group())

      assert result["refunded_cents"] == 1_000
      assert result["retained_cents"] == 0
      assert read_ledger()["cash_refunded_cents"] == 3_000
    end

    test "rejects room identifiers it cannot settle" do
      submit([
        two_rooms(),
        cancel_rooms(%{"operation_id" => "op-gone", "room_ids" => ["room-a"]})
      ])

      for {operation_id, room_ids} <- [
            {"op-unknown", ["room-z"]},
            {"op-repeated", ["room-b", "room-b"]},
            {"op-mixed", ["room-b", "room-z"]},
            {"op-cancelled", ["room-a"]},
            {"op-empty", []},
            {"op-not-a-list", "room-b"},
            {"op-not-strings", [7]}
          ] do
        result =
          submit_one(cancel_rooms(%{"operation_id" => operation_id, "room_ids" => room_ids}))

        assert result["status"] == "rejected", "expected #{operation_id} to be rejected"
        assert result["code"] == "invalid_rooms"
      end

      # Nothing about the group moved: the first cancellation is still the only one.
      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 2
      assert [%{"room_id" => "room-b"}] = active_rooms("group-81")
    end

    test "will not settle rooms as credit when the settlement is not refundable" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      result =
        submit_one(
          cancel_rooms(%{
            "occurred_on" => "2026-11-27",
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit"
          })
        )

      assert result["code"] == "refund_method_not_available"
      assert [%{"status" => "active"}, %{"status" => "active"}] = read_rooms("group-81")
    end

    test "cannot settle rooms of a group that is no longer active" do
      submit([two_rooms(), cancel_group()])

      result = submit_one(cancel_rooms(%{"room_ids" => ["room-a"]}))

      assert result["code"] == "group_not_active"
    end

    test "follows the revision contract" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      stale =
        submit_one(
          cancel_rooms(%{
            "operation_id" => "op-stale",
            "room_ids" => ["room-a"],
            "expected_revision" => 1
          })
        )

      assert stale == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert submit_one(
               cancel_rooms(%{
                 "operation_id" => "op-fresh",
                 "room_ids" => ["room-a"],
                 "expected_revision" => 2
               })
             )["revision"] == 3
    end

    test "a retry returns the original result without settling anything again" do
      submit([two_rooms(), record_cash_payment(%{"amount_cents" => 3_000})])

      first = submit_one(cancel_rooms(%{"room_ids" => ["room-a"]}))
      retry = submit_one(cancel_rooms(%{"room_ids" => ["room-a"]}))

      assert retry == first
      assert read_ledger()["cash_refunded_cents"] == 2_000

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 3
    end
  end

  defp active_rooms(group_id),
    do: Enum.filter(read_rooms(group_id), &(&1["status"] == "active"))
end
