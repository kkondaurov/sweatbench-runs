defmodule GroupStayWeb.Acceptance.PaymentCorrectionsTest do
  @moduledoc """
  Acceptance tests for reducing recorded cash (`reduce_cash_payment`),
  charging back a payment (`charge_back_payment`), and reconciling one
  payment through `GET /api/v1/payments/:payment_operation_id`.
  """

  use GroupStayWeb.ConnCase, async: true

  describe "reduce_cash_payment" do
    setup do
      open_group!(build_conn(), %{"operation_id" => "op-open-1"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      :ok
    end

    test "reduces held cash and reopens the outstanding deposit" do
      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"amount_cents" => 2000})
        )

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "amount_cents" => 2000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 3
             }

      assert %{
               "cash_paid_cents" => 3000,
               "deposit_paid_cents" => 3000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 3
             } = group_data("group-81")

      assert %{
               "cash_held_cents" => 3000,
               "cash_reduced_cents" => 2000,
               "cash_refunded_cents" => 0
             } = ledger()

      assert %{
               "recorded_cents" => 5000,
               "held_cents" => 3000,
               "reduced_cents" => 2000
             } = payment_data("op-pay-1")
    end

    test "the reopened deposit accepts new funding" do
      apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 2000}))

      result =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 2000})
        )

      assert %{"status" => "applied", "outstanding_deposit_cents" => 14_500} = result

      assert %{"cash_paid_cents" => 5000, "outstanding_deposit_cents" => 14_500} =
               group_data("group-81")
    end

    test "removes held allocations in reverse fill order" do
      open_group!(build_conn(), %{"group_id" => "group-fill"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-fill",
          "operation_id" => "op-fill-1",
          "amount_cents" => 12_000
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-fill",
          "operation_id" => "op-fill-3",
          "amount_cents" => 3000
        })
      )

      # op-fill-1 filled room-a (9000) then room-b (3000); op-fill-3 filled
      # room-b. Reducing op-fill-1 by 3000 removes its room-b allocation.
      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"payment_operation_id" => "op-fill-1", "amount_cents" => 3000})
        )

      assert %{"status" => "applied", "outstanding_deposit_cents" => 7500} = result

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 3000}
               ]
             } = group_data("group-fill")

      assert %{
               "held_cents" => 9000,
               "reduced_cents" => 3000
             } = payment_data("op-fill-1")

      assert %{"held_cents" => 3000, "reduced_cents" => 0} = payment_data("op-fill-3")
    end

    test "successive reductions compose against the remaining held cash" do
      apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 2000}))
      apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 2000}))
      result = apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 1000}))

      assert %{"status" => "applied", "outstanding_deposit_cents" => 19_500} = result

      assert %{
               "held_cents" => 0,
               "reduced_cents" => 5000
             } = payment_data("op-pay-1")

      # No held cash remains: the payment can never accept another reduction.
      result = apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 100}))

      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result
      assert %{"revision" => 5} = group_data("group-81")
    end

    test "rejects a reduction exceeding the held cash" do
      result = apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 5001}))

      assert %{"status" => "rejected", "code" => "reduction_exceeds_held_cash"} = result
      assert %{"cash_reduced_cents" => 0} = ledger()
      assert %{"held_cents" => 5000} = payment_data("op-pay-1")
    end

    test "rejects a non-positive reduction" do
      for amount <- [0, -100] do
        result = apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => amount}))

        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end

      assert %{"revision" => 2} = group_data("group-81")
    end

    test "rejects an unknown payment identifier" do
      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"payment_operation_id" => "op-unknown", "amount_cents" => 100})
        )

      assert %{"status" => "rejected", "code" => "operation_not_found"} = result
    end

    test "rejects targets that can never accept a reduction" do
      # A non-payment operation.
      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"payment_operation_id" => "op-open-1", "amount_cents" => 100})
        )

      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result

      # A rejected payment.
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "operation_id" => "op-pay-rejected",
          "group_id" => "group-81",
          "amount_cents" => 999_999
        })
      )

      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{
            "payment_operation_id" => "op-pay-rejected",
            "amount_cents" => 100
          })
        )

      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result

      # A payment whose group was cancelled holds no cash on active rooms.
      apply_one!(
        build_conn(),
        cancel_operation(%{"occurred_on" => "2026-11-26"})
      )

      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"amount_cents" => 100})
        )

      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result
    end

    test "follows the revision contract against the derived group" do
      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"amount_cents" => 1000, "expected_revision" => 99})
        )

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 2
             } = result

      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"amount_cents" => 1000, "expected_revision" => 2})
        )

      assert %{"status" => "applied", "revision" => 3} = result
    end

    test "reductions are durably idempotent" do
      operation =
        reduce_cash_operation(%{"operation_id" => "op-reduce-1", "amount_cents" => 2000})

      original = apply_one!(build_conn(), operation)

      retry = apply_one!(build_conn(), operation)

      assert retry == original
      assert %{"cash_reduced_cents" => 2000} = ledger()
      assert %{"held_cents" => 3000} = payment_data("op-pay-1")
    end

    test "retrying the original payment replays its exact stored result" do
      apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 2000}))

      retry =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
        )

      assert retry == %{
               "operation_id" => "op-pay-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      assert %{"cash_paid_cents" => 3000, "revision" => 3} = group_data("group-81")
    end
  end

  describe "charge_back_payment" do
    setup do
      open_group!(build_conn(), %{"operation_id" => "op-open-1"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      :ok
    end

    test "reverses held cash and reopens the outstanding deposit" do
      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{})
        )

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "charged_back_cents" => 5000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      assert %{
               "status" => "active",
               "cash_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             } = group_data("group-81")

      assert %{
               "cash_held_cents" => 0,
               "cash_charged_back_cents" => 5000,
               "credit_shortfall_cents" => 0
             } = ledger()

      assert %{
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "charged_back_cents" => 5000
             } = payment_data("op-pay-1")

      # A payment can be charged back only once.
      result = apply_one!(build_conn(), charge_back_operation(%{}))

      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = result
      assert %{"revision" => 3} = group_data("group-81")
    end

    test "reclassifies refunded cash on a cancelled group" do
      apply_one!(
        build_conn(),
        cancel_operation(%{"occurred_on" => "2026-11-26"})
      )

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{})
        )

      assert %{"status" => "applied", "charged_back_cents" => 5000, "revision" => 4} = result

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 5000
             } = ledger()

      assert %{
               "held_cents" => 0,
               "refunded_cents" => 0,
               "charged_back_cents" => 5000
             } = payment_data("op-pay-1")
    end

    test "reverses all cash except the portion already reduced" do
      apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 1000}))

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{})
        )

      assert %{"status" => "applied", "charged_back_cents" => 4000} = result

      assert %{
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 4000
             } = payment_data("op-pay-1")

      assert %{
               "cash_held_cents" => 0,
               "cash_reduced_cents" => 1000,
               "cash_charged_back_cents" => 4000
             } = ledger()
    end

    test "rejects a fully reduced payment" do
      apply_one!(build_conn(), reduce_cash_operation(%{"amount_cents" => 5000}))

      result = apply_one!(build_conn(), charge_back_operation(%{}))

      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = result
      assert %{"cash_charged_back_cents" => 0} = ledger()
    end

    test "reverses both held and refunded portions after selected-room cancellation" do
      open_group!(build_conn(), %{"group_id" => "group-mixed-cb"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-mixed-cb",
          "operation_id" => "op-mixed-cb-pay",
          "amount_cents" => 12_000
        })
      )

      # Cancelling room-b refundably refunds its 3000; room-a's 9000 stays held.
      apply_one!(
        build_conn(),
        cancel_rooms_operation(%{"group_id" => "group-mixed-cb", "room_ids" => ["room-b"]})
      )

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{"payment_operation_id" => "op-mixed-cb-pay"})
        )

      assert %{"status" => "applied", "charged_back_cents" => 12_000} = result

      assert %{
               "recorded_cents" => 12_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "charged_back_cents" => 12_000
             } = payment_data("op-mixed-cb-pay")

      assert %{
               "cash_held_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 12_000
             } = ledger()

      # The reopened deposit of the still-active room-a.
      assert %{"status" => "active", "outstanding_deposit_cents" => 9000} =
               group_data("group-mixed-cb")
    end

    test "rejects unknown and non-payment targets" do
      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{"payment_operation_id" => "op-unknown"})
        )

      assert %{"status" => "rejected", "code" => "operation_not_found"} = result

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{"payment_operation_id" => "op-open-1"})
        )

      assert %{"status" => "rejected", "code" => "payment_not_chargeable"} = result
    end

    test "is durably idempotent" do
      operation = charge_back_operation(%{"operation_id" => "op-chargeback-1"})
      original = apply_one!(build_conn(), operation)

      retry = apply_one!(build_conn(), operation)

      assert retry == original
      assert %{"cash_charged_back_cents" => 5000} = ledger()
      assert %{"revision" => 3} = group_data("group-81")
    end
  end

  describe "charging back converted cash" do
    setup do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "cancel-conv",
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      )

      :ok
    end

    test "revokes unspent entitlement and clears the liability" do
      assert %{"available_cents" => 5500} = guest_credit("guest-22")

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{"occurred_on" => "2026-11-21"})
        )

      assert %{"status" => "applied", "charged_back_cents" => 5000} = result

      assert %{
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 5000
             } = payment_data("op-pay-1")

      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22")

      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 5000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = ledger()
    end

    test "spending is never attributed back to individual payments" do
      open_group!(build_conn(), %{"group_id" => "group-two"})

      # 3300 of the 5500 lot funds group-two; 2200 stays available.
      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-two", "amount_cents" => 3300})
      )

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{"occurred_on" => "2026-11-22"})
        )

      assert %{"status" => "applied", "charged_back_cents" => 5000} = result

      # The entitlement is 5500: 2200 comes out of the lot's remaining
      # balance, the unrecovered 3300 becomes the current shortfall.
      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22")

      assert %{
               "credit_liability_cents" => 3300,
               "credit_shortfall_cents" => 3300
             } = ledger()

      # Only the original payment's group advances its revision.
      assert %{"revision" => 4} = group_data("group-81")
      assert %{"revision" => 2} = group_data("group-two")
    end

    test "a refundable restoration absorbs the unrecovered clawback" do
      open_group!(build_conn(), %{"group_id" => "group-two"})

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-two",
          "amount_cents" => 3300,
          "occurred_on" => "2026-11-21"
        })
      )

      apply_one!(
        build_conn(),
        charge_back_operation(%{"occurred_on" => "2026-11-22"})
      )

      assert %{"credit_liability_cents" => 3300, "credit_shortfall_cents" => 3300} = ledger()

      # Cancelling group-two refundably returns the 3300 to the shortfalled
      # lot: the clawback is extinguished before anything becomes available.
      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-two", "occurred_on" => "2026-11-25"})
      )

      assert %{
               "available_cents" => 0,
               "lots" => []
             } = guest_credit("guest-22")

      assert %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = ledger()
    end

    test "a non-refundable settlement reduces the shortfall automatically" do
      open_group!(build_conn(), %{"group_id" => "group-two"})

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-two", "amount_cents" => 3300})
      )

      apply_one!(
        build_conn(),
        charge_back_operation(%{"occurred_on" => "2026-11-22"})
      )

      assert %{"credit_shortfall_cents" => 3300} = ledger()

      # The consumed credit is no longer applied to an active group.
      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-two", "occurred_on" => "2026-12-01"})
      )

      assert %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = ledger()
    end

    test "entitlements telescope across several payments" do
      open_group!(build_conn(), %{
        "group_id" => "group-split",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 2000}]
      })

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-split",
          "operation_id" => "op-split-1",
          "amount_cents" => 505
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-split",
          "operation_id" => "op-split-2",
          "amount_cents" => 505
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-split",
          "operation_id" => "cancel-split",
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      )

      # The combined 1010 converts to one lot of 1111. Charging back both
      # payments removes 556 and then 555: exactly the issued lot.
      assert %{"remaining_cents" => 1111} = split_lot_summary()

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{
            "payment_operation_id" => "op-split-1",
            "occurred_on" => "2026-11-21"
          })
        )

      assert %{"status" => "applied", "charged_back_cents" => 505} = result
      assert %{"remaining_cents" => 555} = split_lot_summary()

      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{
            "payment_operation_id" => "op-split-2",
            "occurred_on" => "2026-11-22"
          })
        )

      assert %{"status" => "applied", "charged_back_cents" => 505} = result

      # Only the setup's unrelated 5500 lot remains.
      assert %{
               "credit_liability_cents" => 5500,
               "credit_shortfall_cents" => 0
             } = ledger()
    end
  end

  describe "reconciling one payment" do
    test "returns the current disposition of an applied payment's cash" do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      conn = get_payment(build_conn(), "op-pay-1")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay-1",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5000,
                 "held_cents" => 5000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end

    test "the disposition fields always sum exactly to the recorded cash" do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      apply_one!(
        build_conn(),
        reduce_cash_operation(%{"payment_operation_id" => "op-pay-1", "amount_cents" => 1000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"occurred_on" => "2026-11-26"})
      )

      data = payment_data("op-pay-1")

      assert %{
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "refunded_cents" => 4000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             } = data

      disposition_total =
        data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
          data["converted_to_credit_cents"] + data["reduced_cents"] + data["charged_back_cents"]

      assert disposition_total == data["recorded_cents"]

      # The statement agrees with the ledger: recorded cash equals held plus
      # refunded, retained, converted, reduced, and charged-back cash.
      ledger_data = ledger()

      recorded =
        ledger_data["cash_held_cents"] + ledger_data["cash_refunded_cents"] +
          ledger_data["cash_retained_cents"] + ledger_data["cash_converted_to_credit_cents"] +
          ledger_data["cash_reduced_cents"] + ledger_data["cash_charged_back_cents"]

      assert recorded == 5000
    end

    test "returns 404 for an unknown payment identifier" do
      conn = get_payment(build_conn(), "op-none")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "returns 422 for records that are not applied cash payments" do
      open_group!(build_conn(), %{"operation_id" => "op-open-1"})

      conn = get_payment(build_conn(), "op-open-1")

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "operation_id" => "op-pay-rejected",
          "amount_cents" => 999_999
        })
      )

      conn = get_payment(build_conn(), "op-pay-rejected")

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)
    end

    test "reading a statement never changes state" do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5000})
      )

      before = group_data("group-81")
      payment_data("op-pay-1")
      assert group_data("group-81") == before
    end
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end

  defp split_lot_summary do
    assert %{status: 200} = conn = get_guest_credit(build_conn(), "guest-22")
    %{"lots" => lots} = json_response(conn, 200)["data"]

    lot = Enum.find(lots, &(&1["source_operation_id"] == "cancel-split"))
    assert lot != nil
    lot
  end

  defp ledger(on \\ nil) do
    assert %{status: 200} = conn = get_ledger(build_conn(), on)
    json_response(conn, 200)["data"]
  end

  defp guest_credit(guest_id, on \\ nil) do
    assert %{status: 200} = conn = get_guest_credit(build_conn(), guest_id, on)
    json_response(conn, 200)["data"]
  end

  defp payment_data(payment_operation_id) do
    assert %{status: 200} = conn = get_payment(build_conn(), payment_operation_id)
    json_response(conn, 200)["data"]
  end
end
