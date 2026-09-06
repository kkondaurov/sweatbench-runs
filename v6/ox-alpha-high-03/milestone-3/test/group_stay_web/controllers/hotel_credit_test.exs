defmodule GroupStayWeb.HotelCreditTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  @booked_flex14 "2026-12-31"
  @booked_flex30 "2027-01-01"

  describe "cancellation policy versions" do
    test "flexible groups booked before 2027-01-01 use the 14-day window" do
      post_operations([
        open_operation(%{
          "group_id" => "group-old-flex",
          "occurred_on" => @booked_flex14,
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        })
      ])

      group = fetch_group("group-old-flex")

      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-05-27"
    end

    test "flexible groups booked on 2027-01-01 use the 30-day window" do
      post_operations([
        open_operation(%{
          "group_id" => "group-new-flex",
          "occurred_on" => @booked_flex30,
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        })
      ])

      group = fetch_group("group-new-flex")

      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-05-11"
    end

    test "advance purchase groups are advance-nonrefundable with no refundable date" do
      post_operations([
        open_operation(%{
          "group_id" => "group-ap-policy",
          "occurred_on" => @booked_flex30,
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        })
      ])

      group = fetch_group("group-ap-policy")

      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "a cancellation on the refundable_until date is refundable under the new window" do
      post_operations([
        open_operation(%{
          "group_id" => "group-boundary",
          "occurred_on" => @booked_flex30,
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        }),
        pay_operation("group-boundary", 19_500)
      ])

      results =
        run_and_get_results([
          cancel_operation("group-boundary", %{"occurred_on" => "2027-05-11"})
        ])

      assert hd(results)["refunded_cents"] == 19_500
    end

    test "rescheduling never moves a group to a newer policy version" do
      post_operations([
        open_operation(%{
          "group_id" => "group-fixed-policy",
          "occurred_on" => @booked_flex14,
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        }),
        reschedule_operation("group-fixed-policy", "2027-06-15", %{"occurred_on" => "2026-12-20"})
      ])

      results =
        run_and_get_results([
          reschedule_operation("group-fixed-policy", "2027-07-16", %{
            "operation_id" => "op-reschedule-2",
            "occurred_on" => "2026-12-21"
          })
        ])

      assert hd(results) == %{
               "operation_id" => "op-reschedule-2",
               "status" => "applied",
               "group_id" => "group-fixed-policy",
               "new_arrival_on" => "2027-07-16",
               "new_departure_on" => "2027-07-19",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-07-02",
               "revision" => 3
             }

      group = fetch_group("group-fixed-policy")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-07-02"
    end
  end

  describe "issuing credit on cancellation" do
    test "a refundable hotel-credit cancellation converts the cash into a bonus lot" do
      open_default_group("group-to-credit")
      run_and_get_results([pay_operation("group-to-credit", 19_500)])

      results =
        run_and_get_results([
          cancel_operation("group-to-credit", %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit",
            "operation_id" => "cancel-17"
          })
        ])

      # 19500 * 110% = 21450 exactly.
      assert hd(results) == %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "group-to-credit",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 21_450,
               "revision" => 3
             }

      assert fetch_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 19_500,
               "credit_liability_cents" => 21_450
             }

      credit = fetch_credit("guest-22")

      assert credit["available_cents"] == 21_450

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 21_450,
                 # Available through 2027-11-26 (365 days), expiring the next day.
                 "expires_on" => "2027-11-27"
               }
             ]
    end

    test "the ten percent bonus follows the standard rounding rule" do
      # A 5-cent deposit makes the bonus land exactly on a half-cent:
      # 5 * 110% = 5.5, which rounds upward to 6.
      post_operations([
        open_operation(%{
          "group_id" => "group-round-bonus",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
        }),
        pay_operation("group-round-bonus", 5),
        cancel_operation("group-round-bonus", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit",
          "operation_id" => "cancel-half"
        })
      ])

      assert fetch_credit("guest-22")["lots"] == [
               %{
                 "source_operation_id" => "cancel-half",
                 "remaining_cents" => 6,
                 "expires_on" => "2027-11-27"
               }
             ]
    end

    test "hotel credit cannot bypass a non-refundable policy" do
      open_default_group("group-late-credit")
      run_and_get_results([pay_operation("group-late-credit", 19_500)])

      results =
        run_and_get_results([
          cancel_operation("group-late-credit", %{"occurred_on" => "2026-12-05"})
          |> Map.put("refund_method", "hotel_credit")
        ])

      assert hd(results) == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = fetch_group("group-late-credit")
      assert group["status"] == "active"
      assert group["revision"] == 2

      ledger = fetch_ledger()
      assert ledger["cash_held_cents"] == 19_500
      assert ledger["credit_liability_cents"] == 0
    end

    test "an unknown refund method is rejected as invalid_operation" do
      open_default_group("group-bad-method")

      results =
        run_and_get_results([
          cancel_operation("group-bad-method", %{"refund_method" => "vouchers"})
        ])

      assert hd(results)["code"] == "invalid_operation"
      assert fetch_group("group-bad-method")["revision"] == 1
    end

    test "a refundable cash cancellation still reports zero credit issued" do
      open_default_group("group-cash-cancel")
      run_and_get_results([pay_operation("group-cash-cancel", 19_500)])

      results =
        run_and_get_results([
          cancel_operation("group-cash-cancel", %{"occurred_on" => "2026-11-26"})
        ])

      assert hd(results)["credit_issued_cents"] == 0
      assert hd(results)["refunded_cents"] == 19_500
    end
  end

  describe "apply_hotel_credit" do
    setup :two_credit_lots

    test "redeems credit into the deposit and reports the resulting state", %{guest: guest} do
      post_operations([
        open_operation(%{"operation_id" => "op-open-spend", "group_id" => "group-spend"})
      ])

      results =
        run_and_get_results([
          credit_operation("group-spend", 15_000, %{"occurred_on" => "2026-12-01"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-spend",
               "amount_cents" => 15_000,
               "outstanding_deposit_cents" => 4_500,
               "revision" => 2
             }

      group = fetch_group("group-spend")
      assert group["credit_paid_cents"] == 15_000
      assert group["cash_paid_cents"] == 0
      assert group["deposit_paid_cents"] == 15_000
      assert group["outstanding_deposit_cents"] == 4_500

      # Applying does not change the liability; it moves between buckets.
      assert fetch_ledger()["credit_liability_cents"] == 22_000

      # The early-expiry lot was consumed down to zero and omitted.
      assert fetch_credit(guest) == %{
               "guest_id" => guest,
               "available_cents" => 7_000,
               "lots" => [
                 %{
                   "source_operation_id" => "late-cancel",
                   "remaining_cents" => 7_000,
                   "expires_on" => "2027-11-21"
                 }
               ]
             }
    end

    test "consumes lots by earliest expiry then source operation id" do
      post_operations([open_operation(%{"group_id" => "group-order"})])

      run_and_get_results([
        credit_operation("group-order", 15_000, %{"operation_id" => "op-credit-order"})
      ])

      credit = fetch_credit("guest-22")

      assert credit["available_cents"] == 7_000

      assert [%{"source_operation_id" => "late-cancel", "remaining_cents" => 7_000}] =
               credit["lots"]
    end

    test "rejects amounts the guest cannot cover without advancing the revision" do
      post_operations([
        open_operation(%{"operation_id" => "op-open-poor", "group_id" => "group-poor"}),
        open_operation(%{
          "operation_id" => "op-open-drain-a",
          "group_id" => "group-poor-drain-a"
        }),
        open_operation(%{"operation_id" => "op-open-drain-b", "group_id" => "group-poor-drain-b"})
      ])

      # Drain all but 1000 cents of the guest's credit elsewhere.
      run_and_get_results([
        credit_operation("group-poor-drain-a", 19_500, %{"operation_id" => "op-drain-a"}),
        credit_operation("group-poor-drain-b", 1_500, %{"operation_id" => "op-drain-b"})
      ])

      results =
        run_and_get_results([
          credit_operation("group-poor", 2_000, %{"operation_id" => "op-credit-poor"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-credit-poor",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      assert fetch_group("group-poor")["revision"] == 1
    end

    test "rejects amounts exceeding the outstanding deposit" do
      post_operations([
        open_operation(%{"operation_id" => "op-open-big", "group_id" => "group-big"})
      ])

      results =
        run_and_get_results([
          credit_operation("group-big", 22_000, %{"operation_id" => "op-credit-big"})
        ])

      assert hd(results)["code"] == "payment_exceeds_outstanding"
      assert fetch_group("group-big")["revision"] == 1
    end

    test "evaluates expiry using the operation's occurred_on date" do
      post_operations([
        open_operation(%{"operation_id" => "op-open-stale-lot", "group_id" => "group-stale-lot"})
      ])

      # Both lots expire during November 2027; the operation happens afterwards.
      results =
        run_and_get_results([
          credit_operation("group-stale-lot", 1_000, %{
            "operation_id" => "op-credit-expired",
            "occurred_on" => "2027-12-01"
          })
        ])

      assert hd(results)["code"] == "insufficient_credit"

      # The same amount is available while the lots are unexpired.
      results =
        run_and_get_results([
          credit_operation("group-stale-lot", 1_000, %{
            "operation_id" => "op-credit-valid",
            "occurred_on" => "2027-10-01"
          })
        ])

      assert hd(results)["status"] == "applied"
    end

    test "checks the revision before domain rules" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-rev-credit",
          "group_id" => "group-rev-credit"
        })
      ])

      results =
        run_and_get_results([
          credit_operation("group-rev-credit", 99_000, %{
            "operation_id" => "op-credit-stale-rev",
            "expected_revision" => 7
          })
        ])

      assert hd(results)["code"] == "stale_revision"
      assert fetch_group("group-rev-credit")["revision"] == 1
    end

    test "rejects payments to missing or inactive groups" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-dead-credit",
          "group_id" => "group-dead-credit"
        })
      ])

      run_and_get_results([cancel_operation("group-dead-credit")])

      assert hd(
               run_and_get_results([
                 credit_operation("no-such-group", 100, %{"operation_id" => "op-credit-missing"})
               ])
             )["code"] ==
               "group_not_found"

      assert hd(
               run_and_get_results([
                 credit_operation("group-dead-credit", 100, %{
                   "operation_id" => "op-credit-inactive"
                 })
               ])
             )["code"] ==
               "group_not_active"

      assert fetch_ledger()["credit_liability_cents"] == 22_000
    end
  end

  describe "settling a group funded by credit" do
    setup :two_credit_lots

    test "refundable cash cancellation restores applied credit to its original lots" do
      post_operations([
        open_operation(%{"operation_id" => "op-open-mixed", "group_id" => "group-mixed"})
      ])

      run_and_get_results([
        pay_operation("group-mixed", 9_750, %{"operation_id" => "op-pay-mixed"}),
        credit_operation("group-mixed", 9_750, %{"operation_id" => "op-credit-mixed"})
      ])

      results =
        run_and_get_results([
          cancel_operation("group-mixed", %{"occurred_on" => "2026-11-26"})
        ])

      assert hd(results)["refunded_cents"] == 9_750
      assert hd(results)["retained_cents"] == 0
      assert hd(results)["credit_issued_cents"] == 0

      # The restored credit returns to its original lot with its original
      # expiry and no second bonus, so the liability survives the settlement.
      assert fetch_ledger()["credit_liability_cents"] == 22_000

      assert fetch_credit("guest-22")["lots"] == [
               %{
                 "source_operation_id" => "early-cancel",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-11"
               },
               %{
                 "source_operation_id" => "late-cancel",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-21"
               }
             ]
    end

    test "restored credit whose expiry already passed expires immediately" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-expire-restore",
          "group_id" => "group-expire-restore",
          "occurred_on" => "2027-06-01",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        })
      ])

      run_and_get_results([
        credit_operation("group-expire-restore", 5_000, %{
          "operation_id" => "op-credit-expire-restore"
        })
      ])

      assert fetch_ledger()["credit_liability_cents"] == 22_000

      # A refundable cancellation long after the funding lot has expired.
      results =
        run_and_get_results([
          cancel_operation("group-expire-restore", %{"occurred_on" => "2028-01-15"})
        ])

      assert hd(results)["refunded_cents"] == 0
      assert hd(results)["retained_cents"] == 0

      # The restored 5000 expires immediately instead of becoming available;
      # only the untouched 17000 remains as liability.
      assert fetch_ledger()["credit_liability_cents"] == 17_000
      assert fetch_credit("guest-22")["available_cents"] == 17_000
    end

    test "non-refundable cancellation retains cash and consumes applied credit" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-eat-credit",
          "group_id" => "group-eat-credit"
        })
      ])

      run_and_get_results([
        pay_operation("group-eat-credit", 9_750, %{"operation_id" => "op-pay-eat-credit"}),
        credit_operation("group-eat-credit", 9_750, %{"operation_id" => "op-credit-eat"})
      ])

      results =
        run_and_get_results([
          cancel_operation("group-eat-credit", %{"occurred_on" => "2026-12-05"})
        ])

      assert hd(results)["retained_cents"] == 9_750
      assert hd(results)["refunded_cents"] == 0

      ledger = fetch_ledger()
      assert ledger["cash_retained_cents"] == 9_750
      # 22000 liability minus the 9750 consumed from the early lot.
      assert ledger["credit_liability_cents"] == 12_250

      credit = fetch_credit("guest-22")
      assert credit["available_cents"] == 12_250
    end

    test "refundable cancellation with hotel_credit issues a fresh bonus lot" do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-cash-to-credit",
          "group_id" => "group-cash-to-credit"
        })
      ])

      run_and_get_results([
        pay_operation("group-cash-to-credit", 9_750, %{"operation_id" => "op-pay-cash-to-credit"})
      ])

      results =
        run_and_get_results([
          cancel_operation("group-cash-to-credit", %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit",
            "operation_id" => "cancel-second"
          })
        ])

      assert hd(results)["credit_issued_cents"] == 10_725
      assert hd(results)["refunded_cents"] == 0

      ledger = fetch_ledger()
      # 20000 of setup cash plus this group's 9750 were converted to credit.
      assert ledger["cash_converted_to_credit_cents"] == 29_750
      assert ledger["cash_refunded_cents"] == 0

      credit = fetch_credit("guest-22")
      assert credit["available_cents"] == 32_725

      new_lot =
        Enum.find(credit["lots"], &match?(%{"source_operation_id" => "cancel-second"}, &1))

      assert new_lot["remaining_cents"] == 10_725
      assert new_lot["expires_on"] == "2027-11-27"
    end
  end

  describe "credit and ledger reads" do
    setup :two_credit_lots

    test "expired and exhausted lots are omitted and lots are ordered" do
      assert fetch_credit("guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 22_000,
               "lots" => [
                 %{
                   "source_operation_id" => "early-cancel",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-11"
                 },
                 %{
                   "source_operation_id" => "late-cancel",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-21"
                 }
               ]
             }
    end

    test "the on parameter reports expiry as of that date" do
      credit = fetch_credit("guest-22", "2027-11-12")

      assert credit["available_cents"] == 11_000
      assert [%{"source_operation_id" => "late-cancel"}] = credit["lots"]

      assert fetch_ledger("2027-11-12")["credit_liability_cents"] == 11_000
      assert fetch_ledger("2027-12-31")["credit_liability_cents"] == 0
      assert fetch_ledger()["credit_liability_cents"] == 22_000
    end

    test "guests without credit read as empty" do
      assert fetch_credit("guest-nobody") == %{
               "guest_id" => "guest-nobody",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "equal expiries order by source_operation_id" do
      # Two cancellations on the same date produce equal expiries.
      for {suffix, op_id} <- [{"b", "same-cancel-b"}, {"a", "same-cancel-a"}] do
        post_operations([
          open_operation(%{
            "operation_id" => "op-open-tie-#{suffix}",
            "group_id" => "group-tie-#{suffix}",
            "guest_id" => "guest-tie",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_000}]
          }),
          pay_operation("group-tie-#{suffix}", 10_000, %{"operation_id" => "op-pay-tie-#{suffix}"}),
          cancel_operation("group-tie-#{suffix}", %{
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit",
            "operation_id" => op_id
          })
        ])
      end

      assert Enum.map(fetch_credit("guest-tie")["lots"], & &1["source_operation_id"]) ==
               ["same-cancel-a", "same-cancel-b"]
    end
  end

  # -- Setup helpers -----------------------------------------------------------

  # Funds guest-22 with two 11000-cent credit lots: "early-cancel" expiring
  # 2027-11-11 and "late-cancel" expiring 2027-11-21.
  defp two_credit_lots(_context) do
    for {suffix, occurred_on, op_id} <- [
          {"late", "2026-11-20", "late-cancel"},
          {"early", "2026-11-10", "early-cancel"}
        ] do
      post_operations([
        open_operation(%{
          "operation_id" => "op-open-source-#{suffix}",
          "group_id" => "group-source-#{suffix}",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        }),
        pay_operation("group-source-#{suffix}", 10_000, %{
          "operation_id" => "op-pay-source-#{suffix}"
        }),
        cancel_operation("group-source-#{suffix}", %{
          "occurred_on" => occurred_on,
          "refund_method" => "hotel_credit",
          "operation_id" => op_id
        })
      ])
    end

    {:ok, guest: "guest-22"}
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end
end
