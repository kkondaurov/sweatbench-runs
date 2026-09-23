defmodule GroupStayWeb.PaymentCorrectionsTest do
  use GroupStayWeb.ConnCase

  # The default group is booked 2026-10-03 under flex-14 and is refundable until 2026-11-26.
  # room-a needs a 9000 cent deposit and room-b 10_500.

  defp pay(operation_id, amount, overrides \\ %{}) do
    op =
      payment_op(
        Map.merge(%{"operation_id" => operation_id, "amount_cents" => amount}, overrides)
      )

    assert %{"status" => "applied"} = result = submit_one(op)
    {op, result}
  end

  defp reduce(payment_operation_id, amount, overrides \\ %{}) do
    submit_one(
      reduce_op(
        Map.merge(
          %{"payment_operation_id" => payment_operation_id, "amount_cents" => amount},
          overrides
        )
      )
    )
  end

  defp charge_back(payment_operation_id, overrides \\ %{}) do
    submit_one(
      charge_back_op(Map.merge(%{"payment_operation_id" => payment_operation_id}, overrides))
    )
  end

  defp ledger(on \\ "2026-10-10"), do: get_ledger(%{"on" => on})

  defp statement(payment_operation_id, fields) do
    Map.merge(
      %{
        "payment_operation_id" => payment_operation_id,
        "original_group_id" => "group-81",
        "recorded_cents" => 0,
        "held_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      fields
    )
  end

  # Recorded cash always equals the sum of its dispositions in the ledger.
  defp assert_ledger_balances(recorded, on \\ "2026-10-10") do
    ledger = ledger(on)

    assert recorded ==
             ledger["cash_held_cents"] + ledger["cash_refunded_cents"] +
               ledger["cash_retained_cents"] + ledger["cash_converted_to_credit_cents"] +
               ledger["cash_reduced_cents"] + ledger["cash_charged_back_cents"]
  end

  setup do
    assert %{"status" => "applied"} = submit_one(open_group_op(%{"operation_id" => "open-81"}))
    :ok
  end

  describe "reduce_cash_payment" do
    test "removes the payment's held cash in reverse fill order and reopens the deposit" do
      pay("pay-1", 12_000)

      assert reduce("pay-1", 4000, %{"operation_id" => "red-1"}) == %{
               "operation_id" => "red-1",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "amount_cents" => 4000,
               "outstanding_deposit_cents" => 11_500,
               "revision" => 3
             }

      assert room_funding("group-81") == [
               {"room-a", "active", 8000, 0},
               {"room-b", "active", 0, 0}
             ]

      assert %{"deposit_paid_cents" => 8000, "outstanding_deposit_cents" => 11_500} =
               get_group("group-81")

      assert %{"cash_held_cents" => 8000, "cash_reduced_cents" => 4000} = ledger()
      assert_ledger_balances(12_000)

      assert get_payment("pay-1") ==
               statement("pay-1", %{
                 "recorded_cents" => 12_000,
                 "held_cents" => 8000,
                 "reduced_cents" => 4000
               })

      # The reopened deposit fills rooms in their original order again.
      pay("pay-2", 1500)

      assert room_funding("group-81") == [
               {"room-a", "active", 9000, 0},
               {"room-b", "active", 500, 0}
             ]
    end

    test "only removes cash from the target payment" do
      pay("pay-1", 5000)
      pay("pay-2", 6000)

      assert %{"status" => "applied", "outstanding_deposit_cents" => 13_500} =
               reduce("pay-1", 5000)

      assert room_funding("group-81") == [
               {"room-a", "active", 4000, 0},
               {"room-b", "active", 2000, 0}
             ]

      assert %{"code" => "payment_not_reducible"} = reduce("pay-1", 1)
      assert %{"code" => "reduction_exceeds_held_cash"} = reduce("pay-2", 6001)
      assert get_payment("pay-2")["held_cents"] == 6000
    end

    test "successive reductions compose against the remaining held cash" do
      pay("pay-1", 5000)

      assert %{"status" => "applied"} = reduce("pay-1", 2000)
      assert %{"code" => "reduction_exceeds_held_cash"} = reduce("pay-1", 3001)

      assert %{"status" => "applied", "outstanding_deposit_cents" => 19_500} =
               reduce("pay-1", 3000)

      assert %{"code" => "payment_not_reducible"} = reduce("pay-1", 1)

      assert get_payment("pay-1") ==
               statement("pay-1", %{"recorded_cents" => 5000, "reduced_cents" => 5000})

      assert_ledger_balances(5000)
    end

    test "never moves settled cash" do
      pay("pay-1", 12_000)
      submit_one(cancel_rooms_op(%{"room_ids" => ["room-a"]}))

      assert %{"code" => "reduction_exceeds_held_cash"} = reduce("pay-1", 3001)

      assert %{"status" => "applied", "outstanding_deposit_cents" => 10_500} =
               reduce("pay-1", 3000)

      assert %{"code" => "payment_not_reducible"} = reduce("pay-1", 1)

      assert get_payment("pay-1") ==
               statement("pay-1", %{
                 "recorded_cents" => 12_000,
                 "refunded_cents" => 9000,
                 "reduced_cents" => 3000
               })

      submit_one(cancel_op())
      assert %{"code" => "payment_not_reducible"} = reduce("pay-1", 1)
    end

    test "rejects targets that cannot be reduced without changing anything" do
      pay("pay-1", 5000)

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} =
               submit_one(payment_op(%{"operation_id" => "pay-big", "amount_cents" => 99_999}))

      before = db_snapshot()

      assert %{"code" => "operation_not_found"} = reduce("pay-unknown", 100)
      assert %{"code" => "payment_not_reducible"} = reduce("open-81", 100)
      assert %{"code" => "payment_not_reducible"} = reduce("pay-big", 100)

      for amount <- [0, -5, 1.5, "100"] do
        assert %{"code" => "invalid_amount"} = reduce("pay-1", amount)
      end

      assert %{"code" => "reduction_exceeds_held_cash"} = reduce("pay-1", 5001)

      assert get_group("group-81")["revision"] == 2
      assert db_snapshot() == before

      # A remembered reduction is not a payment either.
      assert %{"status" => "applied"} = reduce("pay-1", 1000, %{"operation_id" => "red-1"})
      assert %{"code" => "payment_not_reducible"} = reduce("red-1", 1)
    end

    test "requires a payment identifier and an amount" do
      assert %{"code" => "invalid_operation"} =
               submit_one(
                 Map.delete(reduce_op(%{"payment_operation_id" => "pay-1"}), "amount_cents")
               )

      assert %{"code" => "invalid_operation"} = submit_one(reduce_op())
      assert %{"code" => "invalid_operation"} = reduce("", 100)
    end

    test "checks the derived group's revision before its domain rules" do
      pay("pay-1", 5000)

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             } = reduce("pay-1", 999_999, %{"expected_revision" => 1})

      assert %{"code" => "operation_not_found"} =
               reduce("pay-unknown", 100, %{"expected_revision" => 1})

      assert %{"status" => "applied", "revision" => 3} =
               reduce("pay-1", 100, %{"expected_revision" => 2})
    end

    test "never rewrites the original payment's result, and is itself idempotent" do
      {pay_op, original} = pay("pay-1", 5000)
      op = reduce_op(%{"operation_id" => "red-1", "payment_operation_id" => "pay-1"})
      reduced = submit_one(op)
      before = db_snapshot()

      assert submit_one(pay_op) == original
      assert get_operation("pay-1") == original
      assert submit_one(op) == reduced
      assert db_snapshot() == before

      assert %{"code" => "operation_id_conflict"} =
               submit_one(Map.put(op, "amount_cents", 2000))

      assert get_payment("pay-1")["reduced_cents"] == 1000
    end
  end

  describe "charge_back_payment" do
    test "removes held cash and reopens the outstanding deposit" do
      pay("pay-1", 12_000)
      pay("pay-2", 3000)

      assert charge_back("pay-1", %{"operation_id" => "cb-1"}) == %{
               "operation_id" => "cb-1",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 4
             }

      assert room_funding("group-81") == [
               {"room-a", "active", 0, 0},
               {"room-b", "active", 3000, 0}
             ]

      assert %{"cash_held_cents" => 3000, "cash_charged_back_cents" => 12_000} = ledger()
      assert_ledger_balances(15_000)

      assert get_payment("pay-1") ==
               statement("pay-1", %{"recorded_cents" => 12_000, "charged_back_cents" => 12_000})
    end

    test "reclassifies refunded and retained cash without reversing the settlement" do
      pay("pay-1", 12_000)
      submit_one(cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-10-06"}))
      submit_one(cancel_op(%{"occurred_on" => "2026-11-30"}))

      assert %{"cash_refunded_cents" => 9000, "cash_retained_cents" => 3000} = ledger()

      assert %{
               "status" => "applied",
               "charged_back_cents" => 12_000,
               "revision" => 5,
               "outstanding_deposit_cents" => 0
             } = charge_back("pay-1")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_charged_back_cents" => 12_000
             } = ledger()

      assert %{"status" => "cancelled", "revision" => 5, "deposit_paid_cents" => 0} =
               get_group("group-81")

      assert get_payment("pay-1") ==
               statement("pay-1", %{"recorded_cents" => 12_000, "charged_back_cents" => 12_000})
    end

    test "excludes cash already reduced" do
      pay("pay-1", 5000)
      reduce("pay-1", 2000)

      assert %{"charged_back_cents" => 3000, "outstanding_deposit_cents" => 19_500} =
               charge_back("pay-1")

      assert get_payment("pay-1") ==
               statement("pay-1", %{
                 "recorded_cents" => 5000,
                 "reduced_cents" => 2000,
                 "charged_back_cents" => 3000
               })

      assert_ledger_balances(5000)
    end

    test "rejects payments that cannot be charged back without changing anything" do
      pay("pay-1", 5000)
      pay("pay-2", 1000)
      reduce("pay-2", 1000)
      submit_one(payment_op(%{"operation_id" => "pay-big", "amount_cents" => 99_999}))
      assert %{"status" => "applied"} = charge_back("pay-1", %{"operation_id" => "cb-1"})
      before = db_snapshot()

      assert %{"code" => "operation_not_found"} = charge_back("pay-unknown")
      assert %{"code" => "payment_not_chargeable"} = charge_back("open-81")
      assert %{"code" => "payment_not_chargeable"} = charge_back("pay-big")
      assert %{"code" => "payment_not_chargeable"} = charge_back("cb-1")
      assert %{"code" => "payment_not_chargeable"} = charge_back("pay-1")
      assert %{"code" => "payment_not_chargeable"} = charge_back("pay-2")
      assert %{"code" => "invalid_operation"} = submit_one(charge_back_op())

      assert db_snapshot() == before
    end

    test "checks the original group's revision" do
      pay("pay-1", 5000)

      assert %{"code" => "stale_revision", "group_id" => "group-81", "actual_revision" => 2} =
               charge_back("pay-1", %{"expected_revision" => 5})

      assert %{"status" => "applied", "revision" => 3} =
               charge_back("pay-1", %{"expected_revision" => 2})

      assert %{"code" => "stale_revision", "actual_revision" => 3} =
               charge_back("pay-1", %{"expected_revision" => 2})
    end

    test "is durably idempotent and never rewrites the payment's result" do
      {pay_op, original} = pay("pay-1", 5000)
      op = charge_back_op(%{"operation_id" => "cb-1", "payment_operation_id" => "pay-1"})
      charged = submit_one(op)
      before = db_snapshot()

      assert submit_one(op) == charged
      assert submit_one(pay_op) == original
      assert db_snapshot() == before
      assert get_group("group-81")["revision"] == 3
    end
  end

  describe "charging back converted cash" do
    # pay-1, pay-2, and pay-3 fill room-a's 9000 cent deposit (pay-3 also holds 1000 on room-b).
    # room-a is cancelled into one lot, "cr", worth 9000 + 900 = 9900. In funding order the
    # entitlements are 3335 + 334 = 3669, 7337 - 3669 = 3668, and 9900 - 7337 = 2563.
    setup do
      pay("pay-1", 3335)
      pay("pay-2", 3335)
      pay("pay-3", 3330)

      assert %{"credit_issued_cents" => 9900} =
               submit_one(
                 cancel_rooms_op(%{
                   "operation_id" => "cr",
                   "room_ids" => ["room-a"],
                   "refund_method" => "hotel_credit"
                 })
               )

      :ok
    end

    defp available(on \\ "2026-10-10"),
      do: get_guest_credit("guest-22", %{"on" => on})["available_cents"]

    defp open_spending_group(overrides \\ %{}) do
      assert %{"status" => "applied"} =
               open_group_op(
                 Map.merge(%{"operation_id" => "open-stay", "group_id" => "stay-2"}, overrides)
               )
               |> submit_one()
    end

    defp spend_credit(amount) do
      assert %{"status" => "applied"} =
               submit_one(
                 apply_credit_op(%{
                   "group_id" => "stay-2",
                   "occurred_on" => "2026-10-07",
                   "amount_cents" => amount
                 })
               )
    end

    test "revokes each payment's telescoped entitlement from the lot" do
      assert %{"charged_back_cents" => 3335} = charge_back("pay-2")
      assert available() == 9900 - 3668

      assert %{
               "cash_held_cents" => 1000,
               "cash_converted_to_credit_cents" => 5665,
               "cash_charged_back_cents" => 3335,
               "credit_liability_cents" => 6232,
               "credit_shortfall_cents" => 0
             } = ledger()

      assert %{"charged_back_cents" => 3335} = charge_back("pay-1")
      assert available() == 2563
      assert %{"credit_liability_cents" => 2563, "credit_shortfall_cents" => 0} = ledger()

      assert %{"charged_back_cents" => 3330} = charge_back("pay-3")
      assert available() == 0
      assert %{"credit_liability_cents" => 0, "cash_charged_back_cents" => 10_000} = ledger()
      assert_ledger_balances(10_000)
    end

    test "assigns entitlement in funding order regardless of chargeback order" do
      charge_back("pay-1")
      assert available() == 9900 - 3669
    end

    test "reverses a payment split across a settled and an active room" do
      assert %{
               "charged_back_cents" => 3330,
               "outstanding_deposit_cents" => 10_500,
               "revision" => 6
             } =
               charge_back("pay-3")

      assert available() == 9900 - 2563

      assert room_funding("group-81") == [
               {"room-a", "cancelled", 0, 0},
               {"room-b", "active", 0, 0}
             ]

      assert get_payment("pay-1") ==
               statement("pay-1", %{"recorded_cents" => 3335, "converted_to_credit_cents" => 3335})
    end

    test "records unrecoverable entitlement as a shortfall without touching the funded group" do
      open_spending_group()
      spend_credit(9000)

      # Only 900 cents remain in the lot; the rest of pay-1's 3669 entitlement is unrecovered.
      assert %{"status" => "applied"} = charge_back("pay-1")
      assert available() == 0
      assert %{"credit_liability_cents" => 9000, "credit_shortfall_cents" => 2769} = ledger()

      assert %{"status" => "applied"} = charge_back("pay-2")
      assert %{"credit_liability_cents" => 9000, "credit_shortfall_cents" => 6437} = ledger()

      assert %{
               "status" => "active",
               "revision" => 2,
               "credit_paid_cents" => 9000,
               "outstanding_deposit_cents" => 10_500
             } = get_group("stay-2")
    end

    test "returning credit extinguishes the unrecovered clawback before becoming available" do
      open_spending_group()
      spend_credit(9000)
      charge_back("pay-1")

      assert %{"refunded_cents" => 0, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"group_id" => "stay-2", "occurred_on" => "2026-10-20"}))

      assert available("2026-10-20") == 9000 - 2769

      assert %{"credit_liability_cents" => 6231, "credit_shortfall_cents" => 0} =
               ledger("2026-10-20")

      # Nothing is left to extinguish, so later returns are available in full.
      open_spending_group(%{"operation_id" => "open-stay-3", "group_id" => "stay-3"})

      submit_one(
        apply_credit_op(%{
          "group_id" => "stay-3",
          "occurred_on" => "2026-10-21",
          "amount_cents" => 1000
        })
      )

      submit_one(cancel_op(%{"group_id" => "stay-3", "occurred_on" => "2026-10-22"}))
      assert available("2026-10-22") == 6231
    end

    test "absorbs returning credit before expiring the excess of an expired lot" do
      open_spending_group(%{"arrival_on" => "2028-03-01", "departure_on" => "2028-03-04"})
      spend_credit(9000)
      charge_back("pay-1")

      # The lot expires on 2027-10-07; the cancellation is still refundable.
      assert %{"status" => "applied"} =
               submit_one(cancel_op(%{"group_id" => "stay-2", "occurred_on" => "2027-11-01"}))

      assert available("2027-10-01") == 0

      assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} =
               ledger("2027-10-01")
    end

    test "non-refundable settlement of the credit removes the shortfall" do
      open_spending_group()
      spend_credit(9000)
      charge_back("pay-1")

      submit_one(cancel_op(%{"group_id" => "stay-2", "occurred_on" => "2026-11-30"}))
      assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} = ledger()
    end

    test "a lot's shortfall is limited to its credit still applied to active groups" do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
      ]

      # Each room needs 6000 cents: room-a takes 6000 of the credit and room-b 1000.
      open_spending_group(%{"rooms" => rooms})
      spend_credit(7000)

      charge_back("pay-1")
      charge_back("pay-2")
      # 2900 cents remained to revoke from 7337 of entitlement.
      assert %{"credit_liability_cents" => 7000, "credit_shortfall_cents" => 4437} = ledger()

      submit_one(cancel_rooms_op(%{"group_id" => "stay-2", "occurred_on" => "2026-11-30"}))
      assert %{"credit_liability_cents" => 1000, "credit_shortfall_cents" => 1000} = ledger()
    end

    test "claws back each lot a payment contributed to independently" do
      submit_one(
        cancel_op(%{
          "operation_id" => "cg",
          "occurred_on" => "2026-10-08",
          "refund_method" => "hotel_credit"
        })
      )

      # pay-3's 1000 cents on room-b became a second lot worth 1100.
      assert available() == 11_000

      assert get_payment("pay-3") ==
               statement("pay-3", %{"recorded_cents" => 3330, "converted_to_credit_cents" => 3330})

      assert %{"charged_back_cents" => 3330, "revision" => 7} = charge_back("pay-3")
      assert available() == 9900 - 2563

      assert %{"credit_liability_cents" => 7337, "cash_converted_to_credit_cents" => 6670} =
               ledger()
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition of the payment's cash", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
        %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
        %{"room_id" => "room-d", "nightly_rate_cents" => 5000}
      ]

      open_group_op(%{"operation_id" => "open-82", "group_id" => "group-82", "rooms" => rooms})
      |> submit_one()

      # room-a 9000, room-b 10_500, room-c 6000, room-d 500 of 3000.
      pay("pay-17", 26_000, %{"group_id" => "group-82"})
      reduce("pay-17", 200)

      submit_one(cancel_rooms_op(%{"group_id" => "group-82", "room_ids" => ["room-a"]}))

      submit_one(
        cancel_rooms_op(%{
          "group_id" => "group-82",
          "room_ids" => ["room-b"],
          "refund_method" => "hotel_credit"
        })
      )

      submit_one(
        cancel_rooms_op(%{
          "group_id" => "group-82",
          "room_ids" => ["room-c"],
          "occurred_on" => "2026-11-30"
        })
      )

      before = db_snapshot()

      assert json_response(get(conn, "/api/v1/payments/pay-17"), 200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-17",
                 "original_group_id" => "group-82",
                 "recorded_cents" => 26_000,
                 "held_cents" => 300,
                 "refunded_cents" => 9000,
                 "retained_cents" => 6000,
                 "converted_to_credit_cents" => 10_500,
                 "reduced_cents" => 200,
                 "charged_back_cents" => 0
               }
             }

      assert db_snapshot() == before

      # The statement agrees with the room, group, and ledger views.
      assert room_funding("group-82") == [
               {"room-a", "cancelled", 0, 0},
               {"room-b", "cancelled", 0, 0},
               {"room-c", "cancelled", 0, 0},
               {"room-d", "active", 300, 0}
             ]

      assert %{"deposit_paid_cents" => 300, "outstanding_deposit_cents" => 2700} =
               get_group("group-82")

      assert %{
               "cash_held_cents" => 300,
               "cash_refunded_cents" => 9000,
               "cash_retained_cents" => 6000,
               "cash_converted_to_credit_cents" => 10_500,
               "cash_reduced_cents" => 200,
               "cash_charged_back_cents" => 0
             } = ledger()

      charge_back("pay-17")

      assert get_payment("pay-17") ==
               statement("pay-17", %{
                 "original_group_id" => "group-82",
                 "recorded_cents" => 26_000,
                 "reduced_cents" => 200,
                 "charged_back_cents" => 25_800
               })

      assert %{"deposit_paid_cents" => 0, "outstanding_deposit_cents" => 3000} =
               get_group("group-82")
    end

    test "reports a new payment as entirely held" do
      pay("pay-1", 5000)

      assert get_payment("pay-1") ==
               statement("pay-1", %{"recorded_cents" => 5000, "held_cents" => 5000})
    end

    test "returns 404 without a durable record", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/payments/pay-404"), 404) ==
               %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 for a record that is not an applied cash payment", %{conn: conn} do
      submit_one(payment_op(%{"operation_id" => "pay-big", "amount_cents" => 99_999}))
      pay("pay-1", 5000)
      reduce("pay-1", 100, %{"operation_id" => "red-1"})

      for operation_id <- ["open-81", "pay-big", "red-1"] do
        assert json_response(get(conn, "/api/v1/payments/#{operation_id}"), 422) ==
                 %{"error" => %{"code" => "payment_not_reconcilable"}}
      end
    end
  end
end
