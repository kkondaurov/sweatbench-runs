defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)
  end

  defp get_ledger(params \\ %{}) do
    conn = get(build_conn(), ~p"/api/v1/ledger?#{params}")
    json_response(conn, 200)
  end

  defp get_credit(guest_id, params \\ %{}) do
    conn = get(build_conn(), ~p"/api/v1/guests/#{guest_id}/credit?#{params}")
    json_response(conn, 200)
  end

  defp apply_ops(operations) do
    conn = post_batch(operations)
    assert %{"results" => results} = json_response(conn, 200)
    results
  end

  defp apply_ops!(operations) do
    results = apply_ops(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    results
  end

  # Opens a group, pays cash, and cancels refundable with hotel credit so the
  # guest receives a credit lot. Returns the lot's remaining balance.
  defp issue_credit(group_suffix, cash_amount, cancel_date) do
    apply_ops!([
      open_group_op(%{
        "operation_id" => "op-open-#{group_suffix}",
        "group_id" => "group-#{group_suffix}"
      }),
      record_cash_payment_op(%{
        "operation_id" => "op-pay-#{group_suffix}",
        "group_id" => "group-#{group_suffix}",
        "amount_cents" => cash_amount
      }),
      cancel_group_op(%{
        "operation_id" => "op-cancel-#{group_suffix}",
        "group_id" => "group-#{group_suffix}",
        "occurred_on" => cancel_date,
        "refund_method" => "hotel_credit"
      })
    ])

    cash_amount + GroupStay.Money.percent_of(cash_amount, 10)
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 use the 14-day window" do
      apply_ops!([open_group_op(%{"occurred_on" => "2026-12-31"})])

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             } = get_group("group-81")
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window" do
      for booked_on <- ["2027-01-01", "2027-03-05"] do
        apply_ops!([
          open_group_op(%{
            "operation_id" => "op-open-#{booked_on}",
            "group_id" => "group-#{booked_on}",
            "occurred_on" => booked_on,
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          })
        ])

        assert %{
                 "data" => %{
                   "policy_version" => "flex-30",
                   "refundable_until" => "2027-05-02"
                 }
               } = get_group("group-#{booked_on}")
      end
    end

    test "advance-purchase groups are non-refundable with no refundable_until" do
      apply_ops!([open_group_op(%{"rate_plan" => "advance_purchase"})])

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get_group("group-81")
    end
  end

  describe "reschedule_group policy reporting" do
    test "the result includes the fixed policy version and recomputed refundable_until" do
      apply_ops!([
        open_group_op(%{
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })
      ])

      conn =
        post_batch([
          reschedule_group_op(%{"occurred_on" => "2027-02-02", "new_arrival_on" => "2027-07-01"})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "new_arrival_on" => "2027-07-01",
                   "new_departure_on" => "2027-07-04",
                   "policy_version" => "flex-30",
                   "refundable_until" => "2027-06-01",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rescheduling never moves a group to a newer policy" do
      apply_ops!([open_group_op(%{"occurred_on" => "2026-12-31"})])

      conn = post_batch([reschedule_group_op(%{"new_arrival_on" => "2027-01-15"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-01-01"
                 }
               ]
             } = json_response(conn, 200)
    end
  end

  describe "cancellation windows" do
    test "a flex-30 group cancelled 30 days before arrival is refundable" do
      apply_ops!([
        open_group_op(%{
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        record_cash_payment_op(%{"amount_cents" => 5_000})
      ])

      conn =
        post_batch([cancel_group_op(%{"occurred_on" => "2027-05-02"})])

      assert %{"results" => [%{"status" => "applied", "refunded_cents" => 5_000}]} =
               json_response(conn, 200)
    end

    test "a flex-30 group cancelled 29 days before arrival retains the cash" do
      apply_ops!([
        open_group_op(%{
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        record_cash_payment_op(%{"amount_cents" => 5_000})
      ])

      conn =
        post_batch([cancel_group_op(%{"occurred_on" => "2027-05-03"})])

      assert %{"results" => [%{"status" => "applied", "retained_cents" => 5_000}]} =
               json_response(conn, 200)
    end
  end

  describe "cancel_group refund_method" do
    test "omitting refund_method refunds cash and issues no credit" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-11-20"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 10_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)
    end

    test "an explicit cash refund method behaves like the default" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "cash"})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 10_000, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "hotel credit converts refundable cash into a 110% lot" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      conn =
        post_batch([
          cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 11_000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 11_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-20"
                   }
                 ]
               }
             } = get_credit("guest-22")
    end

    test "the 10% bonus rounds to the nearest cent with half cents upward" do
      # 1 night at 525 -> deposit 105; 10% of 105 is 10.5 -> 11; issued 116.
      apply_ops!([
        open_group_op(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 525}]
        }),
        record_cash_payment_op(%{"amount_cents" => 105})
      ])

      conn =
        post_batch([
          cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
        ])

      assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 116}]} =
               json_response(conn, 200)
    end

    test "a hotel-credit cancellation moves cash to the converted ledger total" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      assert %{"data" => %{"cash_held_cents" => 10_000}} = get_ledger()

      apply_ops!([
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
               }
             } = get_ledger()
    end

    test "hotel credit is rejected for a non-refundable cancellation" do
      apply_ops!([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      # 9 days before arrival: inside the 14-day window.
      conn =
        post_batch([
          cancel_group_op(%{"occurred_on" => "2026-12-01", "refund_method" => "hotel_credit"})
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "refund_method_not_available"}
               ]
             } = json_response(conn, 200)

      # The group stays active and can still be cancelled for cash.
      assert %{"data" => %{"status" => "active", "revision" => 2}} = get_group("group-81")

      conn =
        post_batch([
          cancel_group_op(%{"operation_id" => "op-cancel-2", "occurred_on" => "2026-12-01"})
        ])

      assert %{"results" => [%{"status" => "applied", "retained_cents" => 10_000}]} =
               json_response(conn, 200)
    end

    test "hotel credit is rejected for advance-purchase cancellations" do
      apply_ops!([open_group_op(%{"rate_plan" => "advance_purchase"})])

      conn =
        post_batch([cancel_group_op(%{"refund_method" => "hotel_credit"})])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "refund_method_not_available"}]
             } = json_response(conn, 200)
    end

    test "unknown refund methods are rejected as invalid operations" do
      open_group = apply_ops!([open_group_op()])
      assert [%{"status" => "applied"}] = open_group

      conn = post_batch([cancel_group_op(%{"refund_method" => "voucher"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end
  end

  describe "apply_hotel_credit" do
    test "applies guest credit to the outstanding deposit" do
      issue_credit("81", 15_000, "2026-11-20")
      apply_ops!([open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"})])

      conn =
        post_batch([
          apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 12_000})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-credit",
                   "status" => "applied",
                   "group_id" => "group-82",
                   "amount_cents" => 12_000,
                   "outstanding_deposit_cents" => 7_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 12_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 12_000,
                 "outstanding_deposit_cents" => 7_500
               }
             } = get_group("group-82")

      assert %{"data" => %{"available_cents" => 4_500}} = get_credit("guest-22")
    end

    test "rejects when the guest cannot cover the amount" do
      issue_credit("81", 15_000, "2026-11-20")
      apply_ops!([open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"})])

      conn =
        post_batch([
          apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 16_501})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "insufficient_credit"}]} =
               json_response(conn, 200)
    end

    test "rejects credit above the outstanding deposit" do
      issue_credit("81", 15_000, "2026-11-20")
      apply_ops!([open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"})])

      conn =
        post_batch([
          apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 19_501})
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}]
             } = json_response(conn, 200)
    end

    test "uses the existing validation errors for inactive groups and bad amounts" do
      issue_credit("81", 15_000, "2026-11-20")
      apply_ops!([open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"})])

      conn =
        post_batch([
          apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 0})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_amount"}]} =
               json_response(conn, 200)

      apply_ops!([
        cancel_group_op(%{"operation_id" => "op-cancel-82", "group_id" => "group-82"})
      ])

      conn =
        post_batch([
          apply_hotel_credit_op(%{
            "operation_id" => "op-credit-2",
            "group_id" => "group-82",
            "amount_cents" => 1_000
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_active"}]} =
               json_response(conn, 200)
    end

    test "a stale revision is rejected before the credit checks" do
      issue_credit("81", 15_000, "2026-11-20")
      apply_ops!([open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"})])

      conn =
        post_batch([
          apply_hotel_credit_op(%{
            "group_id" => "group-82",
            "amount_cents" => 16_501,
            "expected_revision" => 5
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 5,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "credit on its expiry date is usable; one day later it is not" do
      issue_credit("81", 15_000, "2026-11-20")
      apply_ops!([open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"})])

      # The lot expires on 2027-11-20 and is usable through that date.
      conn =
        post_batch([
          apply_hotel_credit_op(%{
            "group_id" => "group-82",
            "amount_cents" => 5_000,
            "occurred_on" => "2027-11-20"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-3", "group_id" => "group-83"})
      ])

      conn =
        post_batch([
          apply_hotel_credit_op(%{
            "operation_id" => "op-credit-2",
            "group_id" => "group-83",
            "amount_cents" => 5_000,
            "occurred_on" => "2027-11-21"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "insufficient_credit"}]} =
               json_response(conn, 200)
    end
  end

  describe "credit lot consumption order" do
    test "lots are consumed by earliest expiry, then source_operation_id" do
      # Earlier-expiring lot (source op-cancel-b) must be consumed first even
      # though it was created second.
      issue_credit("a", 5_000, "2026-11-20")
      issue_credit("b", 5_000, "2026-11-10")

      apply_ops!([open_group_op(%{"operation_id" => "op-open-c", "group_id" => "group-c"})])

      apply_ops!([
        apply_hotel_credit_op(%{"group_id" => "group-c", "amount_cents" => 8_000})
      ])

      # The 2027-11-10 lot (5_500) is exhausted; 2_500 came out of the
      # 2027-11-20 lot, leaving 3_000.
      assert %{
               "data" => %{
                 "available_cents" => 3_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-a",
                     "remaining_cents" => 3_000,
                     "expires_on" => "2027-11-20"
                   }
                 ]
               }
             } = get_credit("guest-22")
    end

    test "equal expiries fall back to source_operation_id order" do
      issue_credit("b", 5_000, "2026-11-20")
      issue_credit("a", 5_000, "2026-11-20")

      apply_ops!([open_group_op(%{"operation_id" => "op-open-c", "group_id" => "group-c"})])

      apply_ops!([
        apply_hotel_credit_op(%{"group_id" => "group-c", "amount_cents" => 6_000})
      ])

      # Both lots expire 2027-11-20; op-cancel-a (5_500) goes first, then 500
      # from op-cancel-b.
      assert %{
               "data" => %{
                 "available_cents" => 5_000,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-b", "remaining_cents" => 5_000}
                 ]
               }
             } = get_credit("guest-22")
    end
  end

  describe "settling credit-funded groups" do
    test "a refundable cancellation restores applied credit and refunds cash" do
      issue_credit("81", 15_000, "2026-11-20")

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 12_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 6_000
        })
      ])

      conn =
        post_batch([
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2026-11-20"
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 6_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      # The applied credit returns to its original lot with its original expiry.
      assert %{
               "data" => %{
                 "available_cents" => 16_500,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-81",
                     "remaining_cents" => 16_500,
                     "expires_on" => "2027-11-20"
                   }
                 ]
               }
             } = get_credit("guest-22")
    end

    test "a refundable hotel-credit settlement never issues a second bonus" do
      issue_credit("81", 15_000, "2026-11-20")

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 12_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 6_000
        })
      ])

      conn =
        post_batch([
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2026-11-25",
            "refund_method" => "hotel_credit"
          })
        ])

      # The cash portion (6_000) becomes a new 6_600 lot; the restored 12_000
      # returns without a second bonus.
      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 6_600
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 23_100,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-81",
                     "remaining_cents" => 16_500,
                     "expires_on" => "2027-11-20"
                   },
                   %{
                     "source_operation_id" => "op-cancel-82",
                     "remaining_cents" => 6_600,
                     "expires_on" => "2027-11-25"
                   }
                 ]
               }
             } = get_credit("guest-22")
    end

    test "a non-refundable cancellation retains cash and consumes applied credit" do
      issue_credit("81", 15_000, "2026-11-20")

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 12_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "amount_cents" => 6_000
        })
      ])

      # 9 days before arrival: non-refundable.
      conn =
        post_batch([
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2026-12-01"
          })
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 6_000,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      # The applied 12_000 is consumed; only the unapplied remainder is left.
      assert %{"data" => %{"available_cents" => 4_500}} = get_credit("guest-22")

      assert %{
               "data" => %{"cash_retained_cents" => 6_000, "credit_liability_cents" => 4_500}
             } = get_ledger()
    end

    test "restored credit whose original expiry has passed reduces the liability" do
      # Issue a lot expiring 2028-04-30 for guest-22.
      apply_ops!([
        open_group_op(%{
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_000}]
        }),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      apply_ops!([
        cancel_group_op(%{"occurred_on" => "2027-05-01", "refund_method" => "hotel_credit"})
      ])

      # Fund a later group with the credit.
      apply_ops!([
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "arrival_on" => "2029-01-01",
          "departure_on" => "2029-01-02",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 60_000}]
        }),
        apply_hotel_credit_op(%{
          "group_id" => "group-82",
          "amount_cents" => 11_000,
          "occurred_on" => "2027-06-01"
        })
      ])

      # Refundable, but the original lot expired on 2028-04-30, before the
      # cancellation date of 2028-12-01.
      conn =
        post_batch([
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2028-12-01"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit("guest-22")
      assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger()
    end
  end

  describe "credit reads" do
    test "lots are ordered by expiry then source, and exhausted lots are omitted" do
      issue_credit("b", 5_000, "2026-11-20")
      issue_credit("a", 5_000, "2026-11-10")

      assert %{
               "data" => %{
                 "available_cents" => 11_000,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-a", "expires_on" => "2027-11-10"},
                   %{"source_operation_id" => "op-cancel-b", "expires_on" => "2027-11-20"}
                 ]
               }
             } = get_credit("guest-22")

      apply_ops!([open_group_op(%{"operation_id" => "op-open-c", "group_id" => "group-c"})])

      apply_ops!([
        apply_hotel_credit_op(%{"group_id" => "group-c", "amount_cents" => 5_500})
      ])

      # op-cancel-a's lot is exhausted and disappears.
      assert %{
               "data" => %{
                 "available_cents" => 5_500,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-b", "remaining_cents" => 5_500}
                 ]
               }
             } = get_credit("guest-22")
    end

    test "expiry is reported as of the on query parameter" do
      issue_credit("a", 10_000, "2026-11-20")

      assert %{"data" => %{"available_cents" => 11_000}} =
               get_credit("guest-22", %{"on" => "2027-11-20"})

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get_credit("guest-22", %{"on" => "2027-11-21"})
    end

    test "a guest without credit has an empty response" do
      assert %{"data" => %{"guest_id" => "guest-99", "available_cents" => 0, "lots" => []}} =
               get_credit("guest-99")
    end

    test "applied credit keeps counting toward the liability until expiry" do
      issue_credit("81", 15_000, "2026-11-20")

      apply_ops!([
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"group_id" => "group-82", "amount_cents" => 12_000})
      ])

      # Applying credit does not change the liability.
      assert %{"data" => %{"credit_liability_cents" => 16_500}} = get_ledger()

      # After the lot's expiry the available remainder stops counting, while
      # the applied credit (expiry paused) still counts.
      assert %{"data" => %{"credit_liability_cents" => 12_000}} =
               get_ledger(%{"on" => "2027-11-21"})

      assert %{"data" => %{"credit_liability_cents" => 16_500}} =
               get_ledger(%{"on" => "2027-11-20"})
    end
  end
end
