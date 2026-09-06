defmodule GroupStayWeb.Acceptance.CancellationEconomicsTest do
  @moduledoc """
  Acceptance tests for the cancellation-economics request: policy versions,
  hotel credit issued on cancellation, applying credit to deposits, settling
  credit-funded groups, and the credit/ledger reads.
  """

  use GroupStayWeb.ConnCase, async: true

  describe "policy versions" do
    test "a flexible group booked before 2027-01-01 keeps the 14-day window" do
      open_group!(build_conn(), %{"occurred_on" => "2026-12-31"})

      assert %{
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26"
             } = group_data("group-81")
    end

    test "a flexible group booked on or after 2027-01-01 uses the 30-day window" do
      open_group!(build_conn(), %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      assert %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-02-08"
             } = group_data("group-81")
    end

    test "an advance-purchase group is non-refundable with no refundable_until" do
      open_group!(build_conn(), %{"rate_plan" => "advance_purchase"})

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = group_data("group-81")
    end

    test "cancellation on the refundable_until date is refundable under flex-30" do
      open_group!(build_conn(), %{
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"occurred_on" => "2027-02-08", "refund_method" => "cash"})
        )

      assert %{
               "status" => "applied",
               "refunded_cents" => 1000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = result

      open_group!(build_conn(), %{
        "group_id" => "group-late",
        "occurred_on" => "2027-01-05",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-late", "amount_cents" => 1000})
      )

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "group-late", "occurred_on" => "2027-02-09"})
        )

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 1000} = result
    end

    test "rescheduling never moves a group to a newer policy" do
      open_group!(build_conn())

      result =
        apply_one!(
          build_conn(),
          reschedule_operation(%{
            "occurred_on" => "2026-10-04",
            "new_arrival_on" => "2027-06-10"
          })
        )

      assert %{
               "status" => "applied",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-05-27"
             } = result

      assert %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-05-27",
               "arrival_on" => "2027-06-10"
             } = group_data("group-81")
    end

    test "a flex-30 group keeps its policy across a reschedule" do
      open_group!(build_conn(), %{
        "occurred_on" => "2027-02-01",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      })

      apply_one!(
        build_conn(),
        reschedule_operation(%{"occurred_on" => "2027-02-02", "new_arrival_on" => "2028-01-10"})
      )

      assert %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-12-11"
             } = group_data("group-81")
    end
  end

  describe "issuing credit on cancellation" do
    test "a refundable cash cancellation may take hotel credit at 110%" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 5000}))

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{
            "operation_id" => "cancel-17",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert result == %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             }

      assert %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             } == guest_credit("guest-22")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             } == ledger()
    end

    test "the 10% bonus follows the standard rounding rule" do
      # One night at 525: the deposit is exactly 105.
      open_group!(build_conn(), %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 525}]
      })

      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 105}))

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        )

      # 105 * 1.10 = 115.5, which rounds up to 116.
      assert %{"credit_issued_cents" => 116} = result
    end

    test "an unpaid refundable cancellation issues no credit" do
      open_group!(build_conn())

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        )

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = result

      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22")
      assert %{"cash_converted_to_credit_cents" => 0, "credit_liability_cents" => 0} = ledger()
    end

    test "hotel credit is not a way around a non-refundable policy" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))

      # 2026-12-01 is 9 days before the 2026-12-10 arrival: non-refundable.
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"occurred_on" => "2026-12-01", "refund_method" => "hotel_credit"})
        )

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = result

      assert %{"status" => "active", "revision" => 2} = group_data("group-81")
      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22")
      assert %{"cash_held_cents" => 1000, "cash_converted_to_credit_cents" => 0} = ledger()
    end

    test "advance purchase rejects hotel credit" do
      open_group!(build_conn(), %{"rate_plan" => "advance_purchase"})
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 9999}))

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"occurred_on" => "2026-10-04", "refund_method" => "hotel_credit"})
        )

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = result
      assert %{"status" => "active"} = group_data("group-81")
    end

    test "an unknown refund method is rejected without advancing the revision" do
      open_group!(build_conn())

      result =
        apply_one!(build_conn(), cancel_operation(%{"refund_method" => "cheque"}))

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = result
      assert %{"status" => "active", "revision" => 1} = group_data("group-81")
    end

    test "omitting refund_method means cash" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 5000}))

      result = apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert %{"refunded_cents" => 5000, "credit_issued_cents" => 0} = result
      assert %{"cash_refunded_cents" => 5000, "cash_converted_to_credit_cents" => 0} = ledger()
    end
  end

  describe "applying credit" do
    setup do
      # Cancel a refundable group with hotel credit to fund the guest's lots.
      open_group!(build_conn(), %{"group_id" => "group-source"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-source", "amount_cents" => 5000})
      )

      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{
            "operation_id" => "cancel-17",
            "group_id" => "group-source",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert %{"credit_issued_cents" => 5500} = result
      open_group!(build_conn(), %{"group_id" => "group-target"})
      :ok
    end

    test "applies credit to an active group's outstanding deposit" do
      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{
            "operation_id" => "op-credit",
            "group_id" => "group-target",
            "amount_cents" => 2000
          })
        )

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-target",
               "amount_cents" => 2000,
               "outstanding_deposit_cents" => 17500,
               "revision" => 2
             }

      assert %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 2000,
               "deposit_paid_cents" => 2000,
               "outstanding_deposit_cents" => 17500,
               "revision" => 2
             } = group_data("group-target")

      assert %{"available_cents" => 3500} = guest_credit("guest-22")
    end

    test "applying credit does not change the credit liability" do
      assert %{"credit_liability_cents" => 5500} = ledger()

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-target", "amount_cents" => 2000})
      )

      # 3500 still available plus 2000 applied to an active group.
      assert %{"credit_liability_cents" => 5500} = ledger()
    end

    test "credit applied to an active group has its expiry paused" do
      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-target", "amount_cents" => 2000})
      )

      # After the lot's 2027-11-26 expiry the available portion is gone, but
      # the portion funding the active group still counts.
      assert %{"credit_liability_cents" => 2000} = ledger("2028-06-01")
    end

    test "cash payments share the deposit with applied credit" do
      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-target", "amount_cents" => 2000})
      )

      result =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"group_id" => "group-target", "amount_cents" => 3000})
        )

      assert %{"outstanding_deposit_cents" => 14500} = result

      assert %{
               "cash_paid_cents" => 3000,
               "credit_paid_cents" => 2000,
               "deposit_paid_cents" => 5000
             } = group_data("group-target")
    end

    test "credit cannot exceed the group's outstanding deposit" do
      open_group!(build_conn(), %{
        "group_id" => "group-small",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1002}]
      })

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-small", "amount_cents" => 201})
        )

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = result

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-small", "amount_cents" => 200})
        )

      assert %{"status" => "applied", "outstanding_deposit_cents" => 0} = result
    end

    test "insufficient credit is rejected" do
      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-target", "amount_cents" => 5501})
        )

      assert %{"status" => "rejected", "code" => "insufficient_credit"} = result
      assert %{"revision" => 1, "credit_paid_cents" => 0} = group_data("group-target")
    end

    test "a guest without credit cannot apply any" do
      open_group!(build_conn(), %{"group_id" => "group-other", "guest_id" => "guest-99"})

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-other", "amount_cents" => 100})
        )

      assert %{"status" => "rejected", "code" => "insufficient_credit"} = result
    end

    test "unusable amounts are rejected" do
      for amount <- [0, -100, 500.5, "500", nil] do
        result =
          apply_one!(
            build_conn(),
            apply_hotel_credit_operation(%{
              "group_id" => "group-target",
              "amount_cents" => amount
            })
          )

        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end
    end

    test "existing group errors and the revision contract apply" do
      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "ghost", "amount_cents" => 100})
        )

      assert %{"status" => "rejected", "code" => "group_not_found"} = result

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{
            "group_id" => "group-target",
            "amount_cents" => 100,
            "expected_revision" => 99
          })
        )

      assert %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 1} =
               result

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{
            "group_id" => "group-target",
            "amount_cents" => 100,
            "expected_revision" => 1
          })
        )

      assert %{"status" => "applied", "revision" => 2} = result

      apply_one!(build_conn(), cancel_operation(%{"group_id" => "group-target"}))

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-target", "amount_cents" => 100})
        )

      assert %{"status" => "rejected", "code" => "group_not_active"} = result
    end

    test "a stale revision is rejected before the credit domain rules" do
      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{
            "group_id" => "group-target",
            "amount_cents" => 999_999,
            "expected_revision" => 42
          })
        )

      assert %{"status" => "rejected", "code" => "stale_revision"} = result
    end
  end

  describe "consuming lots" do
    test "lots are consumed by earliest expiry, then by source_operation_id" do
      open_group!(build_conn())

      open_group!(build_conn(), %{"group_id" => "group-a"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-a", "amount_cents" => 3000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "cancel-a",
          "group_id" => "group-a",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      )

      open_group!(build_conn(), %{"group_id" => "group-b"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-b", "amount_cents" => 2000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      )

      # cancel-a expires 2027-11-10 (3300 remaining) and cancel-b expires
      # 2027-11-20 (2200 remaining).
      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-81", "amount_cents" => 4000})
        )

      assert %{"status" => "applied", "amount_cents" => 4000} = result

      assert %{
               "available_cents" => 1500,
               "lots" => [%{"source_operation_id" => "cancel-b", "remaining_cents" => 1500}]
             } = guest_credit("guest-22")

      assert %{"credit_liability_cents" => 5500} = ledger()
    end

    test "equal expirities are consumed in source_operation_id order" do
      open_group!(build_conn())

      for {group_id, operation_id, amount} <- [
            {"group-z", "cancel-z", 1000},
            {"group-a2", "cancel-a", 2000}
          ] do
        open_group!(build_conn(), %{"group_id" => group_id})

        apply_one!(
          build_conn(),
          record_cash_operation(%{"group_id" => group_id, "amount_cents" => amount})
        )

        apply_one!(
          build_conn(),
          cancel_operation(%{
            "operation_id" => operation_id,
            "group_id" => group_id,
            "occurred_on" => "2026-11-15",
            "refund_method" => "hotel_credit"
          })
        )
      end

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{"group_id" => "group-81", "amount_cents" => 1500})
        )

      assert %{"status" => "applied"} = result

      assert %{
               "lots" => [
                 %{"source_operation_id" => "cancel-a", "remaining_cents" => 700},
                 %{"source_operation_id" => "cancel-z", "remaining_cents" => 1100}
               ]
             } = guest_credit("guest-22")
    end

    test "credit application evaluates expiry using occurred_on" do
      open_group!(build_conn())

      open_group!(build_conn(), %{"group_id" => "group-src"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-src", "amount_cents" => 1000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-src",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      )

      # The lot expires after 2027-11-26: usable on that date, not the next.
      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 1100,
            "occurred_on" => "2027-11-26"
          })
        )

      assert %{"status" => "applied"} = result

      result =
        apply_one!(
          build_conn(),
          apply_hotel_credit_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 1100,
            "occurred_on" => "2027-11-27"
          })
        )

      assert %{"status" => "rejected", "code" => "insufficient_credit"} = result
    end
  end

  describe "settling a group funded by credit" do
    setup do
      open_group!(build_conn(), %{"group_id" => "group-src"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-src", "amount_cents" => 5000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "cancel-17",
          "group_id" => "group-src",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      )

      open_group!(build_conn(), %{"group_id" => "group-mixed"})

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-mixed", "amount_cents" => 2000})
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-mixed", "amount_cents" => 1000})
      )

      :ok
    end

    test "a refundable cash cancellation restores credit without a second bonus" do
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{
            "group_id" => "group-mixed",
            "occurred_on" => "2026-11-26",
            "refund_method" => "cash"
          })
        )

      assert %{
               "status" => "applied",
               "refunded_cents" => 1000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = result

      assert %{
               "available_cents" => 5500,
               "lots" => [%{"source_operation_id" => "cancel-17", "remaining_cents" => 5500}]
             } = guest_credit("guest-22")

      assert %{
               "cash_refunded_cents" => 1000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             } = ledger()

      assert %{
               "status" => "cancelled",
               "cash_paid_cents" => 1000,
               "credit_paid_cents" => 2000,
               "deposit_paid_cents" => 3000,
               "outstanding_deposit_cents" => 0
             } = group_data("group-mixed")
    end

    test "a refundable hotel-credit cancellation converts cash and restores credit" do
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{
            "operation_id" => "cancel-mixed",
            "group_id" => "group-mixed",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1100
             } = result

      assert %{
               "available_cents" => 6600,
               "lots" => [
                 %{"source_operation_id" => "cancel-17", "remaining_cents" => 5500},
                 %{"source_operation_id" => "cancel-mixed", "remaining_cents" => 1100}
               ]
             } = guest_credit("guest-22")

      assert %{
               "cash_converted_to_credit_cents" => 6000,
               "credit_liability_cents" => 6600
             } = ledger()
    end

    test "a non-refundable cancellation retains cash and consumes credit" do
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "group-mixed", "occurred_on" => "2026-12-01"})
        )

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 1000,
               "credit_issued_cents" => 0
             } = result

      # The consumed 2000 is not restored to the lot.
      assert %{
               "available_cents" => 3500,
               "lots" => [%{"source_operation_id" => "cancel-17", "remaining_cents" => 3500}]
             } = guest_credit("guest-22")

      assert %{
               "cash_retained_cents" => 1000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 3500
             } = ledger()
    end

    test "restored credit whose expiry has passed expires immediately" do
      open_group!(build_conn(), %{
        "group_id" => "group-far",
        "occurred_on" => "2026-11-20",
        "arrival_on" => "2029-01-01",
        "departure_on" => "2029-01-03"
      })

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-far", "amount_cents" => 2000})
      )

      assert %{"credit_liability_cents" => 5500} = ledger()

      # Refundable (arrival 2029-01-01 minus 14 days) but after the lot's
      # 2027-11-26 expiry.
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "group-far", "occurred_on" => "2028-01-05"})
        )

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = result

      # The restored 2000 expired immediately: it is neither available again
      # nor part of the credit liability.
      assert %{"available_cents" => 1500} = guest_credit("guest-22")
      assert %{"credit_liability_cents" => 3500} = ledger()
    end
  end

  describe "credit and ledger reads" do
    setup do
      open_group!(build_conn(), %{"group_id" => "group-one"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-one", "amount_cents" => 5000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "cancel-one",
          "group_id" => "group-one",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      )

      open_group!(build_conn(), %{"group_id" => "group-two"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-two", "amount_cents" => 2000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "operation_id" => "cancel-two",
          "group_id" => "group-two",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      )

      :ok
    end

    test "lots are returned ordered by expiry and then source_operation_id" do
      assert %{
               "guest_id" => "guest-22",
               "available_cents" => 7700,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-two",
                   "remaining_cents" => 2200,
                   "expires_on" => "2027-11-10"
                 },
                 %{
                   "source_operation_id" => "cancel-one",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             } == guest_credit("guest-22")
    end

    test "a guest without credit reports an empty summary" do
      assert %{"guest_id" => "guest-none", "available_cents" => 0, "lots" => []} =
               guest_credit("guest-none")
    end

    test "the on parameter reports expiry as of that date" do
      assert %{"available_cents" => 7700, "lots" => [_, _]} = guest_credit("guest-22")

      assert %{"available_cents" => 7700, "lots" => [_, _]} =
               guest_credit("guest-22", "2027-11-10")

      assert %{"available_cents" => 5500, "lots" => [%{"source_operation_id" => "cancel-one"}]} =
               guest_credit("guest-22", "2027-11-11")

      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22", "2028-01-01")

      assert %{"credit_liability_cents" => 7700} = ledger("2027-11-10")
      assert %{"credit_liability_cents" => 5500} = ledger("2027-11-11")
      assert %{"credit_liability_cents" => 0} = ledger("2028-01-01")
    end

    test "exhausted lots are omitted from the guest credit read" do
      open_group!(build_conn(), %{"group_id" => "group-three"})

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{"group_id" => "group-three", "amount_cents" => 7700})
      )

      assert %{"available_cents" => 0, "lots" => []} = guest_credit("guest-22")
      assert %{"credit_liability_cents" => 7700} = ledger()
    end
  end

  describe "batches containing credit operations" do
    test "credit issued by one operation funds a later one in the same batch" do
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"group_id" => "group-a"}),
          record_cash_operation(%{"group_id" => "group-a", "amount_cents" => 5000}),
          cancel_operation(%{
            "operation_id" => "cancel-a",
            "group_id" => "group-a",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          }),
          open_group_operation(%{"group_id" => "group-b"}),
          apply_hotel_credit_operation(%{
            "operation_id" => "op-apply",
            "group_id" => "group-b",
            "amount_cents" => 5500
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied", "credit_issued_cents" => 5500},
                 %{"status" => "applied"},
                 %{"status" => "applied", "outstanding_deposit_cents" => 14000, "revision" => 2}
               ]
             } = json_response(conn, 200)

      assert %{"credit_paid_cents" => 5500, "cash_paid_cents" => 0} = group_data("group-b")
    end
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
end
