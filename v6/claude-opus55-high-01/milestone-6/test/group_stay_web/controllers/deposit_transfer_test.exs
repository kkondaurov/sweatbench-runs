defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  # group-81 and group-92 belong to guest-22. Both are booked 2026-10-03 under flex-14, are
  # refundable until 2026-11-26, and need 9000 cents for room-a and 10_500 for room-b.

  defp open(group_id, overrides \\ %{}) do
    assert %{"status" => "applied"} =
             submit_one(
               open_group_op(
                 Map.merge(
                   %{"group_id" => group_id, "operation_id" => "open-#{group_id}"},
                   overrides
                 )
               )
             )
  end

  defp pay(operation_id, group_id, amount) do
    assert %{"status" => "applied"} =
             submit_one(
               payment_op(%{
                 "operation_id" => operation_id,
                 "group_id" => group_id,
                 "amount_cents" => amount
               })
             )
  end

  defp apply_credit(group_id, amount) do
    assert %{"status" => "applied"} =
             submit_one(apply_credit_op(%{"group_id" => group_id, "amount_cents" => amount}))
  end

  # Issues guest-22 a 5500 cent lot, "cancel-17", expiring 2027-10-07.
  defp issue_credit do
    open("group-credit")
    pay("pay-credit", "group-credit", 5000)

    assert %{"status" => "applied", "credit_issued_cents" => 5500} =
             submit_one(
               cancel_op(%{
                 "operation_id" => "cancel-17",
                 "group_id" => "group-credit",
                 "refund_method" => "hotel_credit"
               })
             )
  end

  defp transfer_op(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_operation_id("op-transfer"),
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-07",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp transfer(amount, overrides \\ %{}),
    do: submit_one(transfer_op(Map.merge(%{"amount_cents" => amount}, overrides)))

  defp ledger(on \\ "2026-10-10"), do: get_ledger(%{"on" => on})

  defp group_funding(group_id) do
    group = get_group(group_id)

    Map.take(group, [
      "revision",
      "deposit_paid_cents",
      "cash_paid_cents",
      "credit_paid_cents",
      "outstanding_deposit_cents"
    ])
  end

  describe "transfer_deposit" do
    setup do
      issue_credit()
      open("group-81")
      open("group-92")

      # group-81 is funded, in allocation order, by pay-1 (room-a), credit (room-a, then room-b),
      # and pay-2 (room-b).
      pay("pay-1", "group-81", 6000)
      apply_credit("group-81", 4000)
      pay("pay-2", "group-81", 2000)

      assert room_funding("group-81") == [
               {"room-a", "active", 6000, 3000},
               {"room-b", "active", 2000, 1000}
             ]

      :ok
    end

    test "moves the most recently allocated funding first, whatever its kind" do
      ledger_before = ledger()
      credit_before = get_guest_credit("guest-22", %{"on" => "2026-10-10"})

      assert transfer(4500, %{"operation_id" => "transfer-1"}) == %{
               "operation_id" => "transfer-1",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 4500,
               "source_outstanding_deposit_cents" => 12_000,
               "destination_outstanding_deposit_cents" => 15_000,
               "source_revision" => 5,
               "destination_revision" => 2
             }

      # pay-2's 2000, then 1000 of credit from room-b, then 1500 of credit from room-a.
      assert room_funding("group-81") == [
               {"room-a", "active", 6000, 1500},
               {"room-b", "active", 0, 0}
             ]

      # The destination fills its rooms in the order the funding was drawn.
      assert room_funding("group-92") == [
               {"room-a", "active", 2000, 2500},
               {"room-b", "active", 0, 0}
             ]

      assert group_funding("group-81") == %{
               "revision" => 5,
               "deposit_paid_cents" => 7500,
               "cash_paid_cents" => 6000,
               "credit_paid_cents" => 1500,
               "outstanding_deposit_cents" => 12_000
             }

      assert group_funding("group-92") == %{
               "revision" => 2,
               "deposit_paid_cents" => 4500,
               "cash_paid_cents" => 2000,
               "credit_paid_cents" => 2500,
               "outstanding_deposit_cents" => 15_000
             }

      # Nothing is settled or revalued.
      assert ledger() == ledger_before
      assert get_guest_credit("guest-22", %{"on" => "2026-10-10"}) == credit_before
      assert get_operation("transfer-1")["amount_cents"] == 4500
    end

    test "fills the destination's rooms in their original order around existing funding" do
      pay("pay-92", "group-92", 8000)

      assert %{"status" => "applied", "destination_outstanding_deposit_cents" => 8500} =
               transfer(3000)

      assert room_funding("group-92") == [
               {"room-a", "active", 9000, 0},
               {"room-b", "active", 1000, 1000}
             ]
    end

    test "can move all held funding and move it back" do
      assert %{"status" => "applied", "source_outstanding_deposit_cents" => 19_500} =
               transfer(12_000)

      assert room_funding("group-81") == [
               {"room-a", "active", 0, 0},
               {"room-b", "active", 0, 0}
             ]

      assert %{"code" => "transfer_exceeds_held_funding"} = transfer(1)

      assert %{"status" => "applied", "source_revision" => 3, "destination_revision" => 6} =
               transfer(2000, %{
                 "source_group_id" => "group-92",
                 "destination_group_id" => "group-81"
               })

      # group-92's most recent allocations are the last units it received: pay-1's cash.
      assert room_funding("group-81") == [
               {"room-a", "active", 2000, 0},
               {"room-b", "active", 0, 0}
             ]

      assert get_payment("pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 2000},
               %{"group_id" => "group-92", "amount_cents" => 4000}
             ]
    end

    test "is durably idempotent" do
      op = transfer_op(%{"operation_id" => "transfer-1", "amount_cents" => 2000})
      assert %{"status" => "applied"} = first = submit_one(op)
      snapshot = db_snapshot()

      assert submit_one(op) == first
      assert db_snapshot() == snapshot

      assert %{"code" => "operation_id_conflict"} =
               submit_one(Map.put(op, "amount_cents", 2001))

      assert get_operation("transfer-1") == first
    end

    test "later operations in the same batch observe the transfer" do
      assert [
               %{"status" => "applied"},
               %{"code" => "transfer_exceeds_held_funding"},
               %{"status" => "applied", "source_revision" => 6, "destination_revision" => 3}
             ] =
               submit([
                 transfer_op(%{"amount_cents" => 10_000}),
                 transfer_op(%{"amount_cents" => 2001}),
                 transfer_op(%{"amount_cents" => 2000})
               ])

      assert get_group("group-92")["deposit_paid_cents"] == 12_000
    end
  end

  describe "transfer_deposit rejections" do
    setup do
      open("group-81")
      open("group-92")
      open("group-other", %{"guest_id" => "guest-99"})
      pay("pay-1", "group-81", 5000)
      :ok
    end

    defp assert_rejected(overrides, expected) do
      snapshot = db_snapshot()
      result = transfer(Map.get(overrides, "amount_cents", 1000), overrides)
      assert Map.drop(result, ["operation_id"]) == Map.put(expected, "status", "rejected")
      assert db_snapshot() == snapshot
    end

    test "missing groups are resolved source first and identified" do
      assert_rejected(
        %{"source_group_id" => "nope-1", "destination_group_id" => "nope-2"},
        %{"code" => "group_not_found", "group_id" => "nope-1"}
      )

      assert_rejected(
        %{"destination_group_id" => "nope-2", "expected_revision" => 1},
        %{"code" => "group_not_found", "group_id" => "nope-2"}
      )
    end

    test "checks the source revision, then the destination revision, before other rules" do
      assert_rejected(
        %{"expected_revision" => 1, "destination_expected_revision" => 7},
        %{
          "code" => "stale_revision",
          "group_id" => "group-81",
          "expected_revision" => 1,
          "actual_revision" => 2
        }
      )

      assert_rejected(
        %{
          "expected_revision" => 2,
          "destination_expected_revision" => 7,
          "amount_cents" => 999_999
        },
        %{
          "code" => "stale_revision",
          "group_id" => "group-92",
          "expected_revision" => 7,
          "actual_revision" => 1
        }
      )

      assert_rejected(
        %{"destination_group_id" => "group-81", "destination_expected_revision" => 1},
        %{
          "code" => "stale_revision",
          "group_id" => "group-81",
          "expected_revision" => 1,
          "actual_revision" => 2
        }
      )

      assert %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2} =
               transfer(1000, %{"expected_revision" => 2, "destination_expected_revision" => 1})
    end

    test "rejects the same group or groups of different guests" do
      assert_rejected(%{"destination_group_id" => "group-81"}, %{"code" => "invalid_transfer"})
      assert_rejected(%{"destination_group_id" => "group-other"}, %{"code" => "invalid_transfer"})

      assert_rejected(
        %{"destination_group_id" => "group-81", "amount_cents" => 0},
        %{"code" => "invalid_transfer"}
      )
    end

    test "rejects inactive groups, identifying them" do
      assert %{"status" => "applied"} =
               submit_one(cancel_op(%{"group_id" => "group-92"}))

      assert_rejected(%{}, %{"code" => "group_not_active", "group_id" => "group-92"})

      assert_rejected(
        %{"source_group_id" => "group-92", "destination_group_id" => "group-81"},
        %{"code" => "group_not_active", "group_id" => "group-92"}
      )
    end

    test "rejects unusable amounts" do
      for amount <- [0, -5, 10.5, "1000", true] do
        assert_rejected(%{"amount_cents" => amount}, %{"code" => "invalid_amount"})
      end
    end

    test "rejects more than the source holds or the destination owes" do
      assert_rejected(%{"amount_cents" => 5001}, %{"code" => "transfer_exceeds_held_funding"})

      pay("pay-92", "group-92", 17_000)

      assert_rejected(%{"amount_cents" => 2501}, %{"code" => "transfer_exceeds_outstanding"})
      assert %{"status" => "applied"} = transfer(2500)
    end

    test "rejects operations missing what they need as invalid operations" do
      for key <- ["source_group_id", "destination_group_id", "amount_cents"] do
        assert %{"status" => "rejected", "code" => "invalid_operation"} =
                 submit_one(Map.delete(transfer_op(%{}), key))
      end

      assert %{"code" => "invalid_operation"} =
               submit_one(transfer_op(%{"destination_expected_revision" => "1"}))

      assert %{"code" => "invalid_operation"} =
               submit_one(transfer_op(%{"source_group_id" => ""}))
    end
  end

  describe "settling transferred funding" do
    setup do
      issue_credit()
      open("group-81")
      open("group-92")
      pay("pay-1", "group-81", 3000)
      apply_credit("group-81", 2000)
      :ok
    end

    test "converted cash earns the bonus on the destination's settled cash" do
      pay("pay-92", "group-92", 1005)
      assert %{"status" => "applied"} = transfer(4000)
      # The credit was allocated after pay-1, so it moved first.
      assert room_funding("group-92") == [
               {"room-a", "active", 3005, 2000},
               {"room-b", "active", 0, 0}
             ]

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 3306
             } =
               submit_one(
                 cancel_op(%{
                   "operation_id" => "cancel-92",
                   "occurred_on" => "2026-10-08",
                   "group_id" => "group-92",
                   "refund_method" => "hotel_credit"
                 })
               )

      # Transferred credit returns to "cancel-17" with its original expiry and no bonus.
      assert get_guest_credit("guest-22", %{"on" => "2026-10-10"})["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-10-07"
               },
               %{
                 "source_operation_id" => "cancel-92",
                 "remaining_cents" => 3306,
                 "expires_on" => "2027-10-09"
               }
             ]

      assert get_payment("pay-1") == %{
               "payment_operation_id" => "pay-1",
               "original_group_id" => "group-81",
               "recorded_cents" => 3000,
               "held_cents" => 1000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 2000,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 1000}]
             }

      assert %{"cash_held_cents" => 1000, "cash_converted_to_credit_cents" => 8005} =
               ledger()
    end

    test "transferred funding settles under the destination's policy" do
      open("group-adv", %{"rate_plan" => "advance_purchase"})

      assert %{"status" => "applied"} =
               transfer(5000, %{"destination_group_id" => "group-adv"})

      liability = ledger()["credit_liability_cents"]

      assert %{"code" => "refund_method_not_available"} =
               submit_one(
                 cancel_op(%{"group_id" => "group-adv", "refund_method" => "hotel_credit"})
               )

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 3000} =
               submit_one(cancel_op(%{"group_id" => "group-adv"}))

      # The source group is still refundable, but the moved funding was settled by group-adv.
      assert %{"cash_retained_cents" => 3000, "credit_liability_cents" => new_liability} =
               ledger()

      assert new_liability == liability - 2000
      assert %{"held_by_group" => []} = get_payment("pay-1")
    end

    test "transferred credit keeps its lot's expiry paused and expires on return if it lapsed" do
      # Only the credit moves: it was allocated after pay-1.
      assert %{"status" => "applied"} = transfer(2000)

      assert room_funding("group-92") == [
               {"room-a", "active", 0, 2000},
               {"room-b", "active", 0, 0}
             ]

      assert %{"status" => "applied"} =
               submit_one(
                 reschedule_op(%{"group_id" => "group-92", "new_arrival_on" => "2028-06-01"})
               )

      # "cancel-17" expires on 2027-10-07; the applied 2000 remains a liability until returned.
      assert %{"credit_liability_cents" => 2000} = ledger("2027-10-07")

      assert %{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"group_id" => "group-92", "occurred_on" => "2027-10-07"}))

      assert %{"credit_liability_cents" => 0} = ledger("2027-10-07")
      assert %{"available_cents" => 0} = get_guest_credit("guest-22", %{"on" => "2027-10-07"})
    end
  end

  describe "payment corrections after a transfer" do
    setup do
      open("group-81")
      open("group-92")
      # pay-1 funds room-a (9000) and room-b (3000) of group-81.
      pay("pay-1", "group-81", 12_000)
      # Moves room-b's 3000, then 2000 from room-a, into group-92's room-a.
      assert %{"status" => "applied"} = transfer(5000)
      :ok
    end

    test "reductions follow the payment's cash across groups in reverse allocation order" do
      assert get_payment("pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7000},
               %{"group_id" => "group-92", "amount_cents" => 5000}
             ]

      assert submit_one(
               reduce_op(%{
                 "operation_id" => "red-1",
                 "payment_operation_id" => "pay-1",
                 "amount_cents" => 6000,
                 "expected_revision" => 3
               })
             ) == %{
               "operation_id" => "red-1",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "amount_cents" => 6000,
               "outstanding_deposit_cents" => 13_500,
               "revision" => 4
             }

      assert room_funding("group-81") == [
               {"room-a", "active", 6000, 0},
               {"room-b", "active", 0, 0}
             ]

      assert room_funding("group-92") == [{"room-a", "active", 0, 0}, {"room-b", "active", 0, 0}]
      assert %{"revision" => 3, "outstanding_deposit_cents" => 19_500} = group_funding("group-92")

      assert %{
               "held_cents" => 6000,
               "reduced_cents" => 6000,
               "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 6000}]
             } = get_payment("pay-1")

      assert %{"cash_held_cents" => 6000, "cash_reduced_cents" => 6000} = ledger()

      # The original payment result is never rewritten.
      assert %{"amount_cents" => 12_000, "revision" => 2} = get_operation("pay-1")
    end

    test "a reduction that only changes another group still advances the addressed group" do
      assert %{"status" => "applied"} =
               transfer(7000)

      assert %{"status" => "applied", "revision" => 5, "outstanding_deposit_cents" => 19_500} =
               submit_one(
                 reduce_op(%{
                   "payment_operation_id" => "pay-1",
                   "amount_cents" => 1000,
                   "expected_revision" => 4
                 })
               )

      assert %{"revision" => 4, "deposit_paid_cents" => 11_000} = group_funding("group-92")
      assert %{"revision" => 5, "deposit_paid_cents" => 0} = group_funding("group-81")

      assert %{"code" => "stale_revision", "group_id" => "group-81"} =
               submit_one(
                 reduce_op(%{
                   "payment_operation_id" => "pay-1",
                   "amount_cents" => 1000,
                   "expected_revision" => 4
                 })
               )

      assert %{"status" => "applied", "revision" => 6} =
               submit_one(
                 reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 11_000})
               )

      assert %{"held_cents" => 0, "held_by_group" => []} = get_payment("pay-1")

      assert %{"code" => "payment_not_reducible"} =
               submit_one(reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 1}))
    end

    test "a payment moved out of its cancelled original group can still be reduced" do
      assert %{"status" => "applied"} = transfer(7000)

      assert %{"status" => "applied", "refunded_cents" => 0, "revision" => 5} =
               submit_one(cancel_op(%{"group_id" => "group-81", "occurred_on" => "2026-10-08"}))

      assert %{"status" => "applied", "revision" => 6, "outstanding_deposit_cents" => 0} =
               submit_one(reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 500}))

      assert %{"revision" => 4, "deposit_paid_cents" => 11_500} = group_funding("group-92")
      assert %{"status" => "cancelled"} = get_group("group-81")
    end

    test "chargebacks reclassify the payment's cash in every group" do
      # group-92 refunds its 5000 of pay-1 in cash.
      assert %{"status" => "applied", "refunded_cents" => 5000, "revision" => 3} =
               submit_one(cancel_op(%{"group_id" => "group-92", "occurred_on" => "2026-10-08"}))

      assert %{
               "status" => "applied",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             } =
               submit_one(charge_back_op(%{"payment_operation_id" => "pay-1"}))

      # The cancelled group's funding did not change, so neither did its revision.
      assert %{"revision" => 3} = group_funding("group-92")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 12_000
             } = ledger()

      assert %{"charged_back_cents" => 12_000, "held_by_group" => []} = get_payment("pay-1")
    end

    test "chargebacks remove held cash from every group holding it" do
      assert %{"status" => "applied", "revision" => 4, "outstanding_deposit_cents" => 19_500} =
               submit_one(
                 charge_back_op(%{"payment_operation_id" => "pay-1", "expected_revision" => 3})
               )

      assert %{"revision" => 3, "deposit_paid_cents" => 0, "outstanding_deposit_cents" => 19_500} =
               group_funding("group-92")

      assert room_funding("group-92") == [{"room-a", "active", 0, 0}, {"room-b", "active", 0, 0}]
      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 12_000} = ledger()
    end
  end

  describe "payment statements" do
    test "keep their earlier shape until the payment takes part in a transfer" do
      open("group-81")
      open("group-92")
      pay("pay-1", "group-81", 1000)
      pay("pay-2", "group-92", 1000)
      refute Map.has_key?(get_payment("pay-1"), "held_by_group")

      # Transferring from group-92 moves only pay-2.
      assert %{"status" => "applied"} =
               transfer(500, %{
                 "source_group_id" => "group-92",
                 "destination_group_id" => "group-81"
               })

      refute Map.has_key?(get_payment("pay-1"), "held_by_group")

      assert get_payment("pay-2")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 500},
               %{"group_id" => "group-92", "amount_cents" => 500}
             ]
    end
  end
end
