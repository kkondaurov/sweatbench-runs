defmodule GroupStayWeb.Acceptance.DepositTransfersTest do
  @moduledoc """
  Acceptance tests for the deposit-transfer request: moving held funding
  between two active groups of the same guest with `transfer_deposit`, the
  cross-group revision rules, later settlement of transferred funding, and
  the `held_by_group` evolution of the payment statement.
  """

  use GroupStayWeb.ConnCase, async: true

  describe "moving held funding" do
    setup do
      open_group!(build_conn(), %{"group_id" => "group-81"})
      open_group!(build_conn(), %{"group_id" => "group-92"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-81", "amount_cents" => 5000})
      )

      :ok
    end

    test "moves cash from the source to the destination" do
      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"amount_cents" => 2000})
        )

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 2000,
               "source_outstanding_deposit_cents" => 16_500,
               "destination_outstanding_deposit_cents" => 17_500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      assert %{
               "cash_paid_cents" => 3000,
               "deposit_paid_cents" => 3000,
               "outstanding_deposit_cents" => 16_500,
               "revision" => 3,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 3000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = group_data("group-81")

      assert %{
               "cash_paid_cents" => 2000,
               "outstanding_deposit_cents" => 17_500,
               "revision" => 2,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = group_data("group-92")
    end

    test "settles and revalues nothing: no ledger total changes" do
      before = ledger()

      apply_one!(build_conn(), transfer_deposit_operation(%{"amount_cents" => 2000}))

      assert ledger() == before
      assert %{"cash_held_cents" => 5000} = ledger()
    end

    test "transfers are durably idempotent" do
      operation =
        transfer_deposit_operation(%{"operation_id" => "op-transfer-1", "amount_cents" => 2000})

      original = apply_one!(build_conn(), operation)
      assert %{"status" => "applied"} = original

      retry = apply_one!(build_conn(), operation)

      assert retry == original
      assert %{"cash_paid_cents" => 3000, "revision" => 3} = group_data("group-81")
      assert %{"cash_paid_cents" => 2000, "revision" => 2} = group_data("group-92")
    end

    test "an operation observes a transfer made earlier in the same batch" do
      conn =
        post_batch(build_conn(), [
          transfer_deposit_operation(%{"amount_cents" => 2000}),
          record_cash_operation(%{"group_id" => "group-92", "amount_cents" => 1000})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "destination_revision" => 2},
                 %{"status" => "applied", "outstanding_deposit_cents" => 16_500}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "draw and fill order" do
    setup do
      open_group!(build_conn(), %{
        "group_id" => "group-src",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-1", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-2", "nightly_rate_cents" => 10_000}
        ]
      })

      open_group!(build_conn(), %{
        "group_id" => "group-dst",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-x", "nightly_rate_cents" => 8000},
          %{"room_id" => "room-y", "nightly_rate_cents" => 8000}
        ]
      })

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-src",
          "operation_id" => "op-pay-1",
          "amount_cents" => 10_000
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-src",
          "operation_id" => "op-pay-2",
          "amount_cents" => 10_000
        })
      )

      :ok
    end

    test "draws in reverse allocation order and fills the destination rooms in order" do
      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{
            "source_group_id" => "group-src",
            "destination_group_id" => "group-dst",
            "amount_cents" => 12_000
          })
        )

      assert %{"status" => "applied"} = result

      # The most recently created allocation (op-pay-2 on room-2) is drawn
      # first: all of op-pay-2's cash moves, then 2000 of op-pay-1's.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-1", "cash_paid_cents" => 8000},
                 %{"room_id" => "room-2", "cash_paid_cents" => 0}
               ]
             } = group_data("group-src")

      # The destination fills room-x before room-y, preserving draw order.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-x", "cash_paid_cents" => 8000},
                 %{"room_id" => "room-y", "cash_paid_cents" => 4000}
               ]
             } = group_data("group-dst")

      # Each moved allocation keeps its payment operation identity.
      assert %{
               "held_cents" => 10_000,
               "held_by_group" => [%{"group_id" => "group-dst", "amount_cents" => 10_000}]
             } = payment_data("op-pay-2")

      assert %{
               "held_cents" => 10_000,
               "held_by_group" => [
                 %{"group_id" => "group-dst", "amount_cents" => 2000},
                 %{"group_id" => "group-src", "amount_cents" => 8000}
               ]
             } = payment_data("op-pay-1")
    end

    test "a payment that never participated keeps the earlier statement shape" do
      assert payment_data("op-pay-1") == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-src",
               "recorded_cents" => 10_000,
               "held_cents" => 10_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end
  end

  describe "transferring hotel credit" do
    setup do
      open_group!(build_conn(), %{
        "group_id" => "group-src",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
      })

      open_group!(build_conn(), %{
        "group_id" => "group-dst",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}]
      })

      # A lot worth 5500 (from 5000 cash cancelled on 2026-11-20, expiring
      # 2027-11-20) funds group-src together with 5000 of cash. The credit is
      # applied first, so a full transfer draws the cash before the credit.
      fund_credit_lot("group-lot", 5000, "2026-11-20")

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-src",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-21"
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-src",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-22"
        })
      )

      :ok
    end

    test "keeps the original lot and changes no credit total" do
      before = ledger()

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{
            "source_group_id" => "group-src",
            "destination_group_id" => "group-dst",
            "amount_cents" => 8000,
            "occurred_on" => "2026-11-25"
          })
        )

      assert %{
               "status" => "applied",
               "source_outstanding_deposit_cents" => 8000,
               "destination_outstanding_deposit_cents" => 2000
             } = result

      # The cash (applied most recently) is drawn first; 3000 of credit
      # follows it.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-1", "cash_paid_cents" => 0, "credit_paid_cents" => 2000}
               ]
             } = group_data("group-src")

      assert %{
               "rooms" => [
                 %{"room_id" => "room-x", "cash_paid_cents" => 5000, "credit_paid_cents" => 3000}
               ]
             } = group_data("group-dst")

      # The credit stays applied with its expiry paused: nothing becomes
      # available and no liability, lot, or ledger total changes.
      assert %{"available_cents" => 500, "lots" => [%{"remaining_cents" => 500}]} =
               guest_credit("guest-22")

      assert ledger() == before

      assert %{
               "cash_held_cents" => 5000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             } = ledger()
    end

    test "a non-refundable settlement consumes transferred credit normally" do
      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-src",
          "destination_group_id" => "group-dst",
          "amount_cents" => 10_000,
          "occurred_on" => "2026-11-25"
        })
      )

      # The destination is advance purchase, so cancelling it is
      # non-refundable: the transferred cash is retained and the transferred
      # credit is consumed.
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "group-dst", "occurred_on" => "2026-11-25"})
        )

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5000} = result

      # Only the lot's unspent 500 remains, with no second bonus.
      assert %{
               "available_cents" => 500,
               "lots" => [%{"source_operation_id" => "cancel-lot", "remaining_cents" => 500}]
             } = guest_credit("guest-22")

      assert %{"credit_liability_cents" => 500} = ledger()
    end

    test "a refundable settlement restores transferred credit to its original lot and expiry" do
      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-src",
          "destination_group_id" => "group-dst",
          "amount_cents" => 10_000,
          "occurred_on" => "2026-11-25"
        })
      )

      open_group!(build_conn(), %{"group_id" => "group-flex"})

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-dst",
          "destination_group_id" => "group-flex",
          "amount_cents" => 10_000,
          "occurred_on" => "2026-11-26"
        })
      )

      # group-flex is flexible and 2026-11-25 is within its window: the cash
      # is refunded and the credit returns to its original lot.
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "group-flex", "occurred_on" => "2026-11-25"})
        )

      assert %{"status" => "applied", "refunded_cents" => 5000, "credit_issued_cents" => 0} =
               result

      # The credit returns to its original lot, worth exactly its own amount
      # again (no second bonus), with its original expiry.
      assert %{
               "available_cents" => 5500,
               "lots" => [
                 %{"source_operation_id" => "cancel-lot", "remaining_cents" => 5500}
               ]
             } = guest_credit("guest-22", "2027-01-01")

      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22", "2027-11-21")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             } = ledger()
    end
  end

  describe "transferred cash settles under the destination policy" do
    setup do
      # The source is booked on or after 2027-01-01 (flex-30, refundable
      # through 2027-05-02); the destination is booked earlier (flex-14,
      # refundable through 2027-05-18). Both arrive 2027-06-01.
      open_group!(build_conn(), %{
        "group_id" => "group-flex30",
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

      open_group!(build_conn(), %{
        "group_id" => "group-flex14",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-flex30",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000
        })
      )

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-flex30",
          "destination_group_id" => "group-flex14",
          "amount_cents" => 5000
        })
      )

      :ok
    end

    test "refunds cash the source's stricter policy would have retained" do
      # 2027-05-10 is within the destination's flex-14 window but past the
      # source's flex-30 window.
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "group-flex14", "occurred_on" => "2027-05-10"})
        )

      assert %{"status" => "applied", "refunded_cents" => 5000, "retained_cents" => 0} = result
      assert %{"cash_refunded_cents" => 5000, "cash_retained_cents" => 0} = ledger()

      assert %{
               "held_cents" => 0,
               "refunded_cents" => 5000,
               "held_by_group" => []
             } = payment_data("op-pay-1")
    end

    test "converted transferred cash earns the bonus where it settles" do
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{
            "group_id" => "group-flex14",
            "occurred_on" => "2027-05-10",
            "refund_method" => "hotel_credit"
          })
        )

      assert %{"status" => "applied", "credit_issued_cents" => 5500} = result
      assert %{"cash_converted_to_credit_cents" => 5000} = ledger()

      assert %{
               "held_cents" => 0,
               "converted_to_credit_cents" => 5000,
               "held_by_group" => []
             } = payment_data("op-pay-1")
    end
  end

  describe "rejections" do
    setup do
      open_group!(build_conn(), %{"group_id" => "group-81"})
      open_group!(build_conn(), %{"group_id" => "group-92"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-81", "amount_cents" => 5000})
      )

      :ok
    end

    test "rejects the same group or different guests with invalid_transfer" do
      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{
            "source_group_id" => "group-81",
            "destination_group_id" => "group-81"
          })
        )

      assert %{"status" => "rejected", "code" => "invalid_transfer"} = result

      open_group!(build_conn(), %{"group_id" => "group-other-guest", "guest_id" => "guest-33"})

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"destination_group_id" => "group-other-guest"})
        )

      assert %{"status" => "rejected", "code" => "invalid_transfer"} = result
      assert %{"revision" => 2, "cash_paid_cents" => 5000} = group_data("group-81")
      assert %{"revision" => 1, "cash_paid_cents" => 0} = group_data("group-other-guest")
    end

    test "resolves source existence before destination existence" do
      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{
            "source_group_id" => "group-none",
            "destination_group_id" => "group-also-none"
          })
        )

      assert %{
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             } = result

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"source_group_id" => "group-none"})
        )

      assert %{
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             } = result

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"destination_group_id" => "group-none"})
        )

      assert %{
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             } = result
    end

    test "rejects when either group is not active, naming that group" do
      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-26"})
      )

      result = apply_one!(build_conn(), transfer_deposit_operation(%{}))

      assert %{
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-92"
             } = result

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-81", "occurred_on" => "2026-11-26"})
      )

      open_group!(build_conn(), %{"group_id" => "group-93"})

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"destination_group_id" => "group-93"})
        )

      assert %{
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             } = result
    end

    test "rejects a non-positive or missing amount with invalid_amount" do
      for attrs <- [%{"amount_cents" => 0}, %{"amount_cents" => -100}, %{"amount_cents" => nil}] do
        result = apply_one!(build_conn(), transfer_deposit_operation(attrs))

        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end

      result =
        apply_one!(
          build_conn(),
          Map.delete(transfer_deposit_operation(), "amount_cents")
        )

      assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      assert %{"revision" => 2} = group_data("group-81")
      assert %{"revision" => 1} = group_data("group-92")
    end

    test "rejects an amount exceeding the source's held funding" do
      result = apply_one!(build_conn(), transfer_deposit_operation(%{"amount_cents" => 5001}))

      assert %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} = result
      assert %{"cash_paid_cents" => 5000} = group_data("group-81")
      assert %{"cash_paid_cents" => 0} = group_data("group-92")
    end

    test "rejects an amount exceeding the destination's outstanding deposit" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-92",
          "operation_id" => "op-pay-dst",
          "amount_cents" => 19_500
        })
      )

      result = apply_one!(build_conn(), transfer_deposit_operation(%{"amount_cents" => 5000}))

      assert %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"} = result
      assert %{"cash_paid_cents" => 5000} = group_data("group-81")
      assert %{"cash_paid_cents" => 19_500} = group_data("group-92")
    end

    test "checks the source revision before the destination revision" do
      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"expected_revision" => 99, "amount_cents" => 1000})
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
          transfer_deposit_operation(%{
            "expected_revision" => 2,
            "destination_expected_revision" => 99,
            "amount_cents" => 1000
          })
        )

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 99,
               "actual_revision" => 1
             } = result

      # A rejected transfer advances neither revision.
      assert %{"revision" => 2} = group_data("group-81")
      assert %{"revision" => 1} = group_data("group-92")
    end

    test "accepts matching revision guards and advances both revisions" do
      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{
            "expected_revision" => 2,
            "destination_expected_revision" => 1,
            "amount_cents" => 1000
          })
        )

      assert %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2} =
               result
    end

    test "a missing identifier is rejected with invalid_operation" do
      result =
        apply_one!(
          build_conn(),
          Map.delete(transfer_deposit_operation(), "source_group_id")
        )

      assert %{"status" => "rejected", "code" => "invalid_operation"} = result

      result =
        apply_one!(
          build_conn(),
          Map.delete(transfer_deposit_operation(), "destination_group_id")
        )

      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end
  end

  describe "reductions and chargebacks across groups" do
    setup do
      open_group!(build_conn(), %{
        "group_id" => "group-81",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      })

      open_group!(build_conn(), %{
        "group_id" => "group-92",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}]
      })

      # op-pay-1 fills room-a, then room-b's first 5000; the transfer moves
      # that 5000 to group-92, so the payment now funds rooms in both groups.
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 15_000
        })
      )

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-81",
          "destination_group_id" => "group-92",
          "amount_cents" => 5000
        })
      )

      :ok
    end

    test "a reduction removes held allocations across groups in reverse fill order" do
      result =
        apply_one!(
          build_conn(),
          reduce_cash_operation(%{"payment_operation_id" => "op-pay-1", "amount_cents" => 6000})
        )

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "amount_cents" => 6000,
               "outstanding_deposit_cents" => 11_000,
               "revision" => 4
             }

      # The most recently created allocation (the transferred unit on
      # group-92's room-x) is removed first, then 1000 of room-a's cash.
      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = group_data("group-81")

      assert %{"rooms" => [%{"room_id" => "room-x", "cash_paid_cents" => 0}]} =
               group_data("group-92")

      # Both groups whose funding changed advance: the addressed group-81 and
      # group-92, whose transferred allocation was removed.
      assert %{"revision" => 4, "outstanding_deposit_cents" => 11_000} = group_data("group-81")
      assert %{"revision" => 3, "outstanding_deposit_cents" => 10_000} = group_data("group-92")

      assert %{
               "held_cents" => 9000,
               "reduced_cents" => 6000,
               "held_by_group" => [%{"group_id" => "group-81", "amount_cents" => 9000}]
             } = payment_data("op-pay-1")
    end

    test "a chargeback reverses held cash across groups" do
      result =
        apply_one!(
          build_conn(),
          charge_back_operation(%{"payment_operation_id" => "op-pay-1"})
        )

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "charged_back_cents" => 15_000,
               "outstanding_deposit_cents" => 20_000,
               "revision" => 4
             }

      assert %{"revision" => 4, "outstanding_deposit_cents" => 20_000} = group_data("group-81")
      assert %{"revision" => 3, "outstanding_deposit_cents" => 10_000} = group_data("group-92")

      assert %{
               "held_cents" => 0,
               "charged_back_cents" => 15_000,
               "held_by_group" => []
             } = payment_data("op-pay-1")

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 15_000} = ledger()
    end

    test "the original payment result is never rewritten" do
      apply_one!(
        build_conn(),
        reduce_cash_operation(%{"payment_operation_id" => "op-pay-1", "amount_cents" => 1000})
      )

      retry =
        apply_one!(
          build_conn(),
          record_cash_operation(%{
            "group_id" => "group-81",
            "operation_id" => "op-pay-1",
            "amount_cents" => 15_000
          })
        )

      assert retry == %{
               "operation_id" => "op-pay-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 15_000,
               "outstanding_deposit_cents" => 5000,
               "revision" => 2
             }
    end
  end

  describe "payment statement evolution" do
    test "held_by_group follows settlement of the transferred cash" do
      open_group!(build_conn(), %{"group_id" => "group-81"})
      open_group!(build_conn(), %{"group_id" => "group-92"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000
        })
      )

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{"amount_cents" => 5000})
      )

      assert %{
               "held_cents" => 5000,
               "held_by_group" => [%{"group_id" => "group-92", "amount_cents" => 5000}]
             } = payment_data("op-pay-1")

      # After the destination settles the cash, none remains held but the
      # list is still reported, now empty.
      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-26"})
      )

      assert %{
               "held_cents" => 0,
               "refunded_cents" => 5000,
               "held_by_group" => []
             } = payment_data("op-pay-1")
    end

    test "a transfer of only credit does not add held_by_group to any payment" do
      open_group!(build_conn(), %{"group_id" => "group-81"})
      open_group!(build_conn(), %{"group_id" => "group-92"})
      fund_credit_lot("group-lot", 5000, "2026-11-20")

      # Cash first, credit second: the credit allocations are the most
      # recently created, so a 5000 transfer draws only credit.
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-21"
        })
      )

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-22"
        })
      )

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"amount_cents" => 5000, "occurred_on" => "2026-11-23"})
        )

      assert %{"status" => "applied"} = result

      assert %{"cash_paid_cents" => 2000, "credit_paid_cents" => 0} = group_data("group-81")
      assert %{"cash_paid_cents" => 0, "credit_paid_cents" => 5000} = group_data("group-92")

      data = payment_data("op-pay-1")

      refute Map.has_key?(data, "held_by_group")
      assert %{"held_cents" => 2000} = data
    end

    test "unattributed funding moves without gaining a payment identity" do
      open_group!(build_conn(), %{"group_id" => "group-81"})
      open_group!(build_conn(), %{"group_id" => "group-92"})

      # Funding without a durable operation identity moves like any other.
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => %{"legacy" => true},
          "amount_cents" => 5000
        })
      )

      result =
        apply_one!(
          build_conn(),
          transfer_deposit_operation(%{"amount_cents" => 2000})
        )

      assert %{"status" => "applied"} = result

      assert %{"cash_paid_cents" => 3000} = group_data("group-81")
      assert %{"cash_paid_cents" => 2000} = group_data("group-92")
      assert %{"cash_held_cents" => 5000} = ledger()

      # Its refundable settlement at the destination stays unattributed.
      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-26"})
      )

      assert %{"cash_refunded_cents" => 2000, "cash_held_cents" => 3000} = ledger()
    end
  end

  defp fund_credit_lot(group_id, amount_cents, cancelled_on) do
    open_group!(build_conn(), %{"group_id" => group_id})

    apply_one!(
      build_conn(),
      record_cash_operation(%{"group_id" => group_id, "amount_cents" => amount_cents})
    )

    apply_one!(
      build_conn(),
      cancel_operation(%{
        "group_id" => group_id,
        "occurred_on" => cancelled_on,
        "refund_method" => "hotel_credit",
        "operation_id" => "cancel-lot"
      })
    )

    :ok
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
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
