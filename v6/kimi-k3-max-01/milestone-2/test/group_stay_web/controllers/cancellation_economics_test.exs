defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  alias GroupStay.Groups

  # Opens group-81 for guest-22, funds it with cash, and cancels it choosing
  # hotel credit. The default group is flexible, booked 2026-10-03 with
  # arrival 2026-12-10 and a 19_500 deposit due.
  defp issue_credit!(conn, cash_cents, cancel_overrides \\ %{}) do
    apply_batch!(conn, [
      open_group_op(),
      record_cash_payment_op(%{"amount_cents" => cash_cents})
    ])

    [result] =
      apply_batch!(conn, [
        cancel_group_op(Map.merge(%{"refund_method" => "hotel_credit"}, cancel_overrides))
      ])

    result
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      open_group!(conn, %{"occurred_on" => "2026-12-31"})

      group = get_group!(fresh_conn(), "group-81")
      assert group["policy_version"] == "flex-14"
      # Arrival 2026-12-10 minus 14 days.
      assert group["refundable_until"] == "2026-11-26"
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window", %{conn: _conn} do
      for booked_on <- ["2027-01-01", "2027-06-15"] do
        open_group!(fresh_conn(), %{
          "occurred_on" => booked_on,
          "group_id" => "group-#{booked_on}",
          "arrival_on" => "2027-08-10",
          "departure_on" => "2027-08-13"
        })

        group = get_group!(fresh_conn(), "group-#{booked_on}")
        assert group["policy_version"] == "flex-30"
        # Arrival 2027-08-10 minus 30 days.
        assert group["refundable_until"] == "2027-07-11"
      end
    end

    test "advance-purchase groups are always non-refundable", %{conn: _conn} do
      for booked_on <- ["2026-10-03", "2027-03-01"] do
        open_group!(fresh_conn(), %{
          "occurred_on" => booked_on,
          "group_id" => "group-#{booked_on}",
          "rate_plan" => "advance_purchase"
        })

        group = get_group!(fresh_conn(), "group-#{booked_on}")
        assert group["policy_version"] == "advance-nonrefundable"
        assert group["refundable_until"] == nil
      end
    end

    test "the 30-day window governs cancellation outcomes for newly booked groups", %{conn: conn} do
      # Booked 2027-02-01, arrival 2027-06-10: refundable through 2027-05-11.
      apply_batch!(conn, [
        open_group_op(%{
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        }),
        record_cash_payment_op(%{"amount_cents" => 19_500, "occurred_on" => "2027-02-02"})
      ])

      # 29 days before arrival is inside the 30-day window: non-refundable,
      # even though it would have been refundable under the 14-day window.
      [inside] = post_batch!(fresh_conn(), [cancel_group_op(%{"occurred_on" => "2027-05-12"})])
      assert inside["refunded_cents"] == 0
      assert inside["retained_cents"] == 19_500
    end

    test "cancellation exactly on refundable_until is refundable under each window", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(%{
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        }),
        record_cash_payment_op(%{"amount_cents" => 19_500, "occurred_on" => "2027-02-02"})
      ])

      # 2027-05-11 is exactly 30 days before the 2027-06-10 arrival.
      [result] = post_batch!(fresh_conn(), [cancel_group_op(%{"occurred_on" => "2027-05-11"})])
      assert result["refunded_cents"] == 19_500
      assert result["retained_cents"] == 0
    end

    test "rescheduling recomputes refundable_until but keeps the fixed policy version", %{
      conn: conn
    } do
      apply_batch!(conn, [open_group_op()])

      # The reschedule happens after the 2027-01-01 cutover; the group keeps
      # the flex-14 policy it was opened with.
      [result] =
        post_batch!(fresh_conn(), [
          reschedule_group_op(%{"occurred_on" => "2027-02-01", "new_arrival_on" => "2027-03-01"})
        ])

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-02-15"
      assert result["new_departure_on"] == "2027-03-04"

      group = get_group!(fresh_conn(), "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-15"
      assert group["booked_on"] == "2026-10-03"
    end

    test "advance-purchase reschedule results report a null refundable_until", %{conn: conn} do
      apply_batch!(conn, [open_group_op(%{"rate_plan" => "advance_purchase"})])

      [result] = post_batch!(fresh_conn(), [reschedule_group_op()])

      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  describe "cancel_group with refund_method hotel_credit" do
    test "converts refundable cash to a credit lot with the 10% bonus", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      [result] =
        post_batch!(fresh_conn(), [cancel_group_op(%{"refund_method" => "hotel_credit"})])

      assert result == %{
               "operation_id" => "op-4001",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 21_450,
               "revision" => 3
             }

      credit = get_credit!(fresh_conn(), "guest-22")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 21_450,
               "lots" => [
                 %{
                   "source_operation_id" => "op-4001",
                   "remaining_cents" => 21_450,
                   # Available through 2027-11-01, expires the following day.
                   "expires_on" => "2027-11-02"
                 }
               ]
             }
    end

    test "the bonus rounds half a cent upward", %{conn: conn} do
      issue_credit!(conn, 5_555)

      # 10% of 5_555 is 555.5, which rounds up to 556.
      credit = get_credit!(fresh_conn(), "guest-22")
      assert credit["available_cents"] == 5_555 + 556
    end

    test "moves the cash from held to converted in the ledger", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), record_cash_payment_op(%{"amount_cents" => 19_500})])

      assert get_ledger!(fresh_conn())["cash_held_cents"] == 19_500

      apply_batch!(fresh_conn(), [cancel_group_op(%{"refund_method" => "hotel_credit"})])

      assert get_ledger!(fresh_conn()) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 19_500,
               "credit_liability_cents" => 21_450
             }
    end

    test "omitting refund_method preserves the cash refund behavior", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      [result] = post_batch!(fresh_conn(), [cancel_group_op()])

      assert result["refunded_cents"] == 19_500
      assert result["credit_issued_cents"] == 0
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 0
    end

    test "an explicit cash refund method behaves like an omitted one", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      [result] = post_batch!(fresh_conn(), [cancel_group_op(%{"refund_method" => "cash"})])

      assert result["refunded_cents"] == 19_500
      assert result["credit_issued_cents"] == 0
    end

    test "a refundable cancellation without cash issues no credit", %{conn: conn} do
      apply_batch!(conn, [open_group_op()])

      [result] =
        post_batch!(fresh_conn(), [cancel_group_op(%{"refund_method" => "hotel_credit"})])

      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 0

      assert get_credit!(fresh_conn(), "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert get_ledger!(fresh_conn())["cash_converted_to_credit_cents"] == 0
    end

    test "rejects hotel credit for a non-refundable cancellation and leaves the group active", %{
      conn: conn
    } do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      # 2026-11-27 is inside the 14-day window.
      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      group = get_group!(fresh_conn(), "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert get_ledger!(fresh_conn())["cash_held_cents"] == 19_500
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 0
    end

    test "rejects hotel credit for advance-purchase groups", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(%{"rate_plan" => "advance_purchase"}),
        record_cash_payment_op(%{"amount_cents" => 97_500})
      ])

      # Even a cancellation long before arrival is non-refundable.
      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{"occurred_on" => "2025-01-01", "refund_method" => "hotel_credit"})
        ])

      assert result["code"] == "refund_method_not_available"
      assert Groups.get_group("group-81").status == "active"
    end

    test "rejects unusable refund methods as invalid operations", %{conn: conn} do
      open_group!(conn)

      for refund_method <- ["voucher", 42, %{"method" => "credit"}] do
        [result] =
          post_batch!(fresh_conn(), [cancel_group_op(%{"refund_method" => refund_method})])

        assert result["code"] == "invalid_operation", "refund_method=#{inspect(refund_method)}"
      end

      assert Groups.get_group("group-81").status == "active"
    end

    test "a stale revision is rejected before the refund method is evaluated", %{conn: conn} do
      apply_batch!(conn, [open_group_op(), record_cash_payment_op(%{"amount_cents" => 1_000})])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "occurred_on" => "2026-12-09",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          })
        ])

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2
    end
  end

  describe "apply_hotel_credit" do
    test "applies available credit to the outstanding deposit", %{conn: conn} do
      issue_credit!(conn, 19_500)
      open_group!(conn, %{"operation_id" => "op-82", "group_id" => "group-82"})

      [result] =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"amount_cents" => 19_500})
        ])

      assert result == %{
               "operation_id" => "op-5001",
               "status" => "applied",
               "group_id" => "group-82",
               "amount_cents" => 19_500,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }

      group = get_group!(fresh_conn(), "group-82")
      assert group["deposit_paid_cents"] == 19_500
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 19_500

      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 1_950
    end

    test "credit and cash together fund a deposit", %{conn: conn} do
      issue_credit!(conn, 19_500)
      open_group!(conn, %{"operation_id" => "op-82", "group_id" => "group-82"})

      results =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"amount_cents" => 5_000}),
          record_cash_payment_op(%{
            "operation_id" => "op-cash",
            "group_id" => "group-82",
            "amount_cents" => 14_500
          })
        ])

      assert [
               %{"status" => "applied", "outstanding_deposit_cents" => 14_500},
               %{"status" => "applied", "outstanding_deposit_cents" => 0}
             ] = results

      group = get_group!(fresh_conn(), "group-82")
      assert group["cash_paid_cents"] == 14_500
      assert group["credit_paid_cents"] == 5_000
      assert group["deposit_paid_cents"] == 19_500
    end

    test "credit issued earlier in the same batch can be applied", %{conn: conn} do
      results =
        post_batch!(conn, [
          open_group_op(),
          record_cash_payment_op(%{"amount_cents" => 19_500}),
          cancel_group_op(%{"refund_method" => "hotel_credit"}),
          open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
          apply_hotel_credit_op(%{"amount_cents" => 19_500})
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied applied)
      assert get_group!(fresh_conn(), "group-82")["credit_paid_cents"] == 19_500
    end

    test "consumes lots by earliest expiry, then by source operation", %{conn: conn} do
      # Lot expiring later, issued first.
      issue_credit!(conn, 10_000, %{
        "operation_id" => "op-lot-later",
        "occurred_on" => "2026-11-05"
      })

      # Lot expiring sooner, issued second.
      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-91", "group_id" => "group-91"}),
        record_cash_payment_op(%{
          "operation_id" => "op-92",
          "group_id" => "group-91",
          "amount_cents" => 10_000
        }),
        cancel_group_op(%{
          "operation_id" => "op-lot-sooner",
          "group_id" => "group-91",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      ])

      # Third lot with the same expiry as the second, for the tie-break.
      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-93", "group_id" => "group-93"}),
        record_cash_payment_op(%{
          "operation_id" => "op-94",
          "group_id" => "group-93",
          "amount_cents" => 10_000
        }),
        cancel_group_op(%{
          "operation_id" => "op-lot-sooner-b",
          "group_id" => "group-93",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      ])

      # Lodging of 123_000 makes 24_600 due, enough to draw down all three
      # lots.
      open_group!(fresh_conn(), %{
        "operation_id" => "op-82",
        "group_id" => "group-82",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 41_000}]
      })

      # 24_200 exhausts op-lot-sooner (11_000) and op-lot-sooner-b (11_000)
      # and takes 2_200 from op-lot-later.
      [result] =
        post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => 24_200})])

      assert result["status"] == "applied"

      credit = get_credit!(fresh_conn(), "guest-22")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-lot-later",
                 "remaining_cents" => 8_800,
                 "expires_on" => "2027-11-06"
               }
             ]
    end

    test "evaluates expiry using the operation date", %{conn: conn} do
      # The lot expires on 2027-11-02.
      issue_credit!(conn, 19_500)
      open_group!(conn, %{"operation_id" => "op-82", "group_id" => "group-82"})

      [expired] =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"occurred_on" => "2027-11-02", "amount_cents" => 1_000})
        ])

      assert expired["code"] == "insufficient_credit"

      [valid] =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"occurred_on" => "2027-11-01", "amount_cents" => 1_000})
        ])

      assert valid["status"] == "applied"
    end

    test "rejects amounts the guest cannot cover", %{conn: conn} do
      issue_credit!(conn, 10_000)
      open_group!(conn, %{"operation_id" => "op-82", "group_id" => "group-82"})

      # The guest holds 11_000 in credit.
      [result] =
        post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => 11_001})])

      assert result["code"] == "insufficient_credit"
      assert get_group!(fresh_conn(), "group-82")["deposit_paid_cents"] == 0
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 11_000
    end

    test "rejects with the payment validation errors where they apply", %{conn: conn} do
      issue_credit!(conn, 19_500)
      open_group!(conn, %{"operation_id" => "op-82", "group_id" => "group-82"})

      for amount <- [0, -1, "5000", 100.5] do
        [result] =
          post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => amount})])

        assert result["code"] == "invalid_amount", "amount=#{inspect(amount)}"
      end

      # The guest holds 21_450 but the group only owes 19_500.
      [exceeds] =
        post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => 19_501})])

      assert exceeds["code"] == "payment_exceeds_outstanding"

      assert get_group!(fresh_conn(), "group-82")["deposit_paid_cents"] == 0
    end

    test "rejects missing or inactive groups before evaluating credit", %{conn: conn} do
      issue_credit!(conn, 19_500)

      [missing] = post_batch!(fresh_conn(), [apply_hotel_credit_op()])
      assert missing["code"] == "group_not_found"

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        cancel_group_op(%{"operation_id" => "op-83", "group_id" => "group-82"})
      ])

      [inactive] = post_batch!(fresh_conn(), [apply_hotel_credit_op()])
      assert inactive["code"] == "group_not_active"

      # Group status is evaluated before the amount.
      [inactive_first] =
        post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => -5})])

      assert inactive_first["code"] == "group_not_active"
    end

    test "rejects operations missing data needed to apply them", %{conn: conn} do
      [result] =
        post_batch!(conn, [apply_hotel_credit_op() |> Map.delete("amount_cents")])

      assert result["code"] == "invalid_operation"

      [unknown] =
        post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"type" => "redeem_credit"})])

      assert unknown["code"] == "invalid_operation"
    end

    test "follows the revision contract", %{conn: conn} do
      # The guest holds 5_500 in credit against an outstanding 19_500.
      issue_credit!(conn, 5_000)
      open_group!(conn, %{"operation_id" => "op-82", "group_id" => "group-82"})

      # A stale revision wins over the domain rules and leaves everything
      # unchanged.
      [stale] =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"amount_cents" => 99_999, "expected_revision" => 7})
        ])

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 1

      # Rejected attempts do not advance the revision.
      [rejected] =
        post_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => 10_000})])

      assert rejected["code"] == "insufficient_credit"
      assert Groups.get_group("group-82").revision == 1

      [applied] =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"amount_cents" => 5_000, "expected_revision" => 1})
        ])

      assert applied["status"] == "applied"
      assert applied["revision"] == 2
    end
  end

  describe "settling a credit-funded group" do
    test "a refundable cash cancellation restores applied credit without a second bonus", %{
      conn: conn
    } do
      issue_credit!(conn, 19_500)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 19_500})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2026-11-20"
          })
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # The full 21_450 is back on the original lot with its original expiry.
      credit = get_credit!(fresh_conn(), "guest-22")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-4001",
                 "remaining_cents" => 21_450,
                 "expires_on" => "2027-11-02"
               }
             ]
    end

    test "a refundable cancellation restores credit to already-expired lots as nothing", %{
      conn: conn
    } do
      # The lot expires on 2027-11-02.
      issue_credit!(conn, 19_500)

      # A group owing exactly the lot's value, refundable through 2028-05-02.
      apply_batch!(fresh_conn(), [
        open_group_op(%{
          "operation_id" => "op-82",
          "group_id" => "group-82",
          "occurred_on" => "2027-06-01",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-04",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 35_750}]
        }),
        apply_hotel_credit_op(%{"occurred_on" => "2027-10-15", "amount_cents" => 21_450})
      ])

      assert get_ledger!(fresh_conn(), "2027-10-20")["credit_liability_cents"] == 21_450

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2028-05-01"
          })
        ])

      assert result["status"] == "applied"

      # The restored amount expired immediately: even as of a date on which
      # the original lot was still valid, nothing came back.
      assert get_credit!(fresh_conn(), "guest-22", "2027-10-20")["available_cents"] == 0
      assert get_ledger!(fresh_conn(), "2027-10-20")["credit_liability_cents"] == 0
    end

    test "a refundable hotel-credit cancellation refunds cash as credit and restores credit", %{
      conn: conn
    } do
      issue_credit!(conn, 19_500)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        record_cash_payment_op(%{
          "operation_id" => "op-cash-82",
          "group_id" => "group-82",
          "amount_cents" => 10_000
        }),
        apply_hotel_credit_op(%{"amount_cents" => 9_500})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert result == %{
               "operation_id" => "op-cancel-82",
               "status" => "applied",
               "group_id" => "group-82",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 4
             }

      # The applied 9_500 returned to its original lot; the 10_000 cash became
      # a new lot with its own operation as the source.
      credit = get_credit!(fresh_conn(), "guest-22")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-4001",
                 "remaining_cents" => 21_450,
                 "expires_on" => "2027-11-02"
               },
               %{
                 "source_operation_id" => "op-cancel-82",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-21"
               }
             ]

      assert get_ledger!(fresh_conn()) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 29_500,
               "credit_liability_cents" => 32_450
             }
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      issue_credit!(conn, 19_500)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        record_cash_payment_op(%{
          "operation_id" => "op-cash-82",
          "group_id" => "group-82",
          "amount_cents" => 10_000
        }),
        apply_hotel_credit_op(%{"amount_cents" => 5_000})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{
            "operation_id" => "op-cancel-82",
            "group_id" => "group-82",
            "occurred_on" => "2026-12-09"
          })
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_000
      assert result["credit_issued_cents"] == 0

      # The consumed 5_000 reduces the liability; the untouched lot balance
      # remains available.
      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 16_450
      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 16_450

      # The consumed credit cannot be applied again.
      open_group!(fresh_conn(), %{"operation_id" => "op-95", "group_id" => "group-95"})

      [rejected] =
        post_batch!(fresh_conn(), [
          apply_hotel_credit_op(%{"group_id" => "group-95", "amount_cents" => 19_500})
        ])

      assert rejected["code"] == "insufficient_credit"
    end

    test "cancelled groups keep their paid history in the read model", %{conn: conn} do
      issue_credit!(conn, 19_500)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_500}),
        cancel_group_op(%{
          "operation_id" => "op-cancel-82",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-20"
        })
      ])

      group = get_group!(fresh_conn(), "group-82")
      assert group["status"] == "cancelled"
      assert group["credit_paid_cents"] == 9_500
      assert group["deposit_paid_cents"] == 9_500
      assert group["outstanding_deposit_cents"] == 0
    end
  end
end
