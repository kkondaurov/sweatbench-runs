defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  # The group is booked 2026-10-03 under flex-14 and is refundable until 2026-11-26. Over three
  # nights room-a needs a 9000 cent deposit, room-b 10_500, and room-c 6000.
  @three_rooms [
    %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
    %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
    %{"room_id" => "room-c", "nightly_rate_cents" => 10_000}
  ]

  defp open_three_rooms(overrides \\ %{}) do
    assert %{"status" => "applied"} =
             submit_one(open_group_op(Map.merge(%{"rooms" => @three_rooms}, overrides)))
  end

  defp pay(amount, overrides \\ %{}) do
    assert %{"status" => "applied"} =
             result = submit_one(payment_op(Map.merge(%{"amount_cents" => amount}, overrides)))

    result
  end

  # Issues `guest-22` a 5500 cent lot, "cancel-17", from another group's refundable cancellation.
  defp issue_credit do
    submit([
      open_group_op(%{"group_id" => "source", "operation_id" => "open-source"}),
      payment_op(%{"group_id" => "source", "amount_cents" => 5000}),
      cancel_op(%{
        "operation_id" => "cancel-17",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp ledger(on \\ "2026-10-10"), do: get_ledger(%{"on" => on})

  describe "room-level accounting" do
    test "exposes each room's status, deposit, and funding" do
      open_three_rooms()

      assert [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{"room_id" => "room-b", "deposit_due_cents" => 10_500},
               %{"room_id" => "room-c", "deposit_due_cents" => 6000}
             ] = get_group("group-81")["rooms"]

      assert %{"deposit_due_cents" => 25_500, "lodging_total_cents" => 127_500} =
               get_group("group-81")
    end

    test "fills one room's deposit before moving to the next, in operation order" do
      open_three_rooms()
      pay(5000)
      pay(6000)

      assert room_funding("group-81") == [
               {"room-a", "active", 9000, 0},
               {"room-b", "active", 2000, 0},
               {"room-c", "active", 0, 0}
             ]

      pay(14_500)

      assert room_funding("group-81") == [
               {"room-a", "active", 9000, 0},
               {"room-b", "active", 10_500, 0},
               {"room-c", "active", 6000, 0}
             ]
    end

    test "cash and credit fill rooms in the same order" do
      issue_credit()
      open_three_rooms()
      pay(7000)

      assert %{"status" => "applied"} =
               submit_one(
                 apply_credit_op(%{"amount_cents" => 5500, "occurred_on" => "2026-10-07"})
               )

      pay(1000)

      assert room_funding("group-81") == [
               {"room-a", "active", 7000, 2000},
               {"room-b", "active", 1000, 3500},
               {"room-c", "active", 0, 0}
             ]

      assert %{
               "deposit_paid_cents" => 13_500,
               "cash_paid_cents" => 8000,
               "credit_paid_cents" => 5500,
               "outstanding_deposit_cents" => 12_000
             } = get_group("group-81")
    end
  end

  describe "cancel_rooms" do
    test "refunds the selected rooms' cash and leaves other rooms unchanged" do
      open_three_rooms()
      pay(12_000)

      assert submit_one(cancel_rooms_op(%{"operation_id" => "cr-1", "room_ids" => ["room-b"]})) ==
               %{
                 "operation_id" => "cr-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 3000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }

      assert room_funding("group-81") == [
               {"room-a", "active", 9000, 0},
               {"room-b", "cancelled", 0, 0},
               {"room-c", "active", 0, 0}
             ]

      assert %{
               "status" => "active",
               "lodging_total_cents" => 75_000,
               "deposit_due_cents" => 15_000,
               "deposit_paid_cents" => 9000,
               "cash_paid_cents" => 9000,
               "outstanding_deposit_cents" => 6000
             } = get_group("group-81")

      assert %{"cash_held_cents" => 9000, "cash_refunded_cents" => 3000} = ledger()
    end

    test "retains the selected rooms' cash when non-refundable" do
      open_three_rooms()
      pay(10_000)

      assert %{"refunded_cents" => 0, "retained_cents" => 9000, "credit_issued_cents" => 0} =
               submit_one(cancel_rooms_op(%{"occurred_on" => "2026-11-27"}))

      assert %{"cash_held_cents" => 1000, "cash_retained_cents" => 9000} = ledger()
    end

    test "rejects hotel credit for a non-refundable cancellation without changing anything" do
      open_three_rooms()
      pay(10_000)
      before = db_snapshot()

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} =
               submit_one(
                 cancel_rooms_op(%{
                   "occurred_on" => "2026-11-27",
                   "refund_method" => "hotel_credit"
                 })
               )

      assert db_snapshot() == before
    end

    test "computes the hotel-credit bonus once on the selected rooms' combined cash" do
      # One night at 25 cents needs a 5 cent deposit per room. Per room the bonus would be two
      # rounded half-cents (1 + 1); on the combined 10 cents it is exactly 1.
      tiny_room = &%{"room_id" => &1, "nightly_rate_cents" => 25}

      open_three_rooms(%{
        "departure_on" => "2026-12-11",
        "rooms" => [tiny_room.("room-a"), tiny_room.("room-b"), tiny_room.("room-c")]
      })

      pay(10)

      assert %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 11} =
               submit_one(
                 cancel_rooms_op(%{
                   "operation_id" => "cr-credit",
                   "room_ids" => ["room-b", "room-a"],
                   "refund_method" => "hotel_credit"
                 })
               )

      assert get_guest_credit("guest-22", %{"on" => "2026-10-06"})["lots"] == [
               %{
                 "source_operation_id" => "cr-credit",
                 "remaining_cents" => 11,
                 "expires_on" => "2027-10-07"
               }
             ]

      assert %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 10,
               "credit_liability_cents" => 11
             } = ledger("2026-10-06")

      assert %{"status" => "active", "deposit_due_cents" => 5, "outstanding_deposit_cents" => 5} =
               get_group("group-81")
    end

    test "returns cancelled rooms in the group's original order" do
      open_three_rooms()

      assert %{"cancelled_room_ids" => ["room-a", "room-c"]} =
               submit_one(cancel_rooms_op(%{"room_ids" => ["room-c", "room-a"]}))
    end

    test "restores the selected rooms' credit to its original lot" do
      issue_credit()
      open_three_rooms()
      pay(7000)
      submit_one(apply_credit_op(%{"amount_cents" => 5500, "occurred_on" => "2026-10-07"}))

      assert %{"refunded_cents" => 7000, "credit_issued_cents" => 0} =
               submit_one(cancel_rooms_op(%{"occurred_on" => "2026-10-08"}))

      assert room_funding("group-81") == [
               {"room-a", "cancelled", 0, 0},
               {"room-b", "active", 0, 3500},
               {"room-c", "active", 0, 0}
             ]

      assert get_guest_credit("guest-22", %{"on" => "2026-10-08"})["available_cents"] == 2000
      assert %{"credit_liability_cents" => 5500, "cash_held_cents" => 0} = ledger("2026-10-08")

      assert %{
               "deposit_paid_cents" => 3500,
               "credit_paid_cents" => 3500,
               "outstanding_deposit_cents" => 13_000
             } = get_group("group-81")
    end

    test "consumes the selected rooms' credit when non-refundable" do
      issue_credit()
      open_three_rooms()
      submit_one(apply_credit_op(%{"amount_cents" => 5500, "occurred_on" => "2026-10-07"}))
      pay(4000)

      assert %{"retained_cents" => 3500} =
               submit_one(cancel_rooms_op(%{"occurred_on" => "2026-11-30"}))

      assert %{"credit_liability_cents" => 0, "cash_held_cents" => 500} = ledger("2026-11-30")
    end

    test "cancels the group when no active rooms remain" do
      open_three_rooms()
      pay(20_000)
      submit_one(cancel_rooms_op(%{"room_ids" => ["room-b"]}))

      assert %{"cancelled_room_ids" => ["room-a", "room-c"], "refunded_cents" => 9500} =
               submit_one(cancel_rooms_op(%{"room_ids" => ["room-a", "room-c"]}))

      assert %{
               "status" => "cancelled",
               "revision" => 4,
               "lodging_total_cents" => 0,
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = get_group("group-81")

      assert %{"code" => "group_not_active"} = submit_one(payment_op(%{"amount_cents" => 100}))
      assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 20_000} = ledger()
    end

    test "cancel_group settles only the remaining active rooms" do
      open_three_rooms()
      pay(20_000)
      submit_one(cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-10-06"}))

      assert submit_one(cancel_op(%{"operation_id" => "cg", "occurred_on" => "2026-11-30"})) == %{
               "operation_id" => "cg",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 11_000,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      assert %{"cash_refunded_cents" => 9000, "cash_retained_cents" => 11_000} = ledger()

      assert room_funding("group-81") == [
               {"room-a", "cancelled", 0, 0},
               {"room-b", "cancelled", 0, 0},
               {"room-c", "cancelled", 0, 0}
             ]
    end

    test "rejects identifiers that are not distinct active rooms of the group" do
      open_three_rooms()
      open_group_op(%{"group_id" => "other", "operation_id" => "open-other"}) |> submit_one()
      submit_one(cancel_rooms_op(%{"room_ids" => ["room-c"]}))
      before = db_snapshot()

      for room_ids <- [
            ["room-a", "room-z"],
            ["room-a", "room-a"],
            ["room-c"],
            ["room-a", "room-c"],
            [],
            "room-a",
            [7],
            [nil]
          ] do
        assert %{"status" => "rejected", "code" => "invalid_rooms"} =
                 submit_one(cancel_rooms_op(%{"room_ids" => room_ids})),
               "expected #{inspect(room_ids)} to be rejected"
      end

      assert db_snapshot() == before
    end

    test "requires room_ids and a known refund method" do
      open_three_rooms()

      assert %{"code" => "invalid_operation"} =
               submit_one(Map.delete(cancel_rooms_op(), "room_ids"))

      assert %{"code" => "invalid_operation"} =
               submit_one(cancel_rooms_op(%{"refund_method" => "voucher"}))

      assert %{"code" => "invalid_operation"} =
               submit_one(Map.delete(cancel_rooms_op(), "group_id"))
    end

    test "follows the group and revision rules" do
      assert %{"code" => "group_not_found"} = submit_one(cancel_rooms_op())
      open_three_rooms()

      assert %{
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 1
             } = submit_one(cancel_rooms_op(%{"expected_revision" => 2, "room_ids" => ["nope"]}))

      assert %{"status" => "applied", "revision" => 2} =
               submit_one(cancel_rooms_op(%{"expected_revision" => 1}))

      submit_one(cancel_op())

      assert %{"code" => "group_not_active"} =
               submit_one(cancel_rooms_op(%{"room_ids" => ["room-b"]}))
    end

    test "is durably idempotent" do
      open_three_rooms()
      pay(12_000)
      op = cancel_rooms_op(%{"operation_id" => "cr-retry", "room_ids" => ["room-a"]})
      original = submit_one(op)
      before = db_snapshot()

      assert submit_one(op) == original
      assert db_snapshot() == before

      assert %{"code" => "operation_id_conflict"} =
               submit_one(Map.put(op, "room_ids", ["room-b"]))
    end
  end
end
