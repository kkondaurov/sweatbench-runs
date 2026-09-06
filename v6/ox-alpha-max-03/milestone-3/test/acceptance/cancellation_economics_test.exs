defmodule GroupStay.Acceptance.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"
  # Arrival 2026-12-10 minus the 14-day flex-14 window.
  @refundable_until_flex14 "2026-11-26"

  describe "policy versions" do
    test "a flexible group booked before 2027 uses the 14-day window", %{conn: conn} do
      open_group(conn, "group-flex14")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => @refundable_until_flex14
               }
             } = get_group!("group-flex14")
    end

    test "a flexible group booked on 2027-01-01 uses the 30-day window", %{conn: conn} do
      open_group(conn, "group-flex30", "flexible", "2027-01-01", "2027-03-10", "2027-03-13")

      assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-02-08"}} =
               get_group!("group-flex30")
    end

    test "an advance-purchase group is non-refundable with no refundable_until", %{conn: conn} do
      open_advance_purchase_group(conn, "group-ap")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get_group!("group-ap")
    end

    test "rescheduling recomputes refundable_until but never moves the policy version", %{
      conn: conn
    } do
      open_group(conn, "group-move")

      # Moving the arrival past the cutoff date must not upgrade the policy.
      conn =
        post_batch(conn, [
          reschedule_operation("op-move", "2026-11-01", "2027-03-10", "group-move")
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-02-24"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "booked_on" => @open_occurred_on,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-02-24"
               }
             } = get_group!("group-move")
    end

    test "cancelling exactly on refundable_until is refundable under the 30-day window", %{
      conn: conn
    } do
      open_group(conn, "group-on-date", "flexible", "2027-01-05", "2027-03-10", "2027-03-13")

      open_group(
        conn,
        "group-inside-window",
        "flexible",
        "2027-01-05",
        "2027-03-10",
        "2027-03-13"
      )

      conn =
        post_batch(conn, [
          cash_operation("op-pay-1", "group-on-date", 5_000)
          |> Map.put("occurred_on", "2027-01-06"),
          cancel_operation("op-cancel-1", "group-on-date", "2027-02-08"),
          cash_operation("op-pay-2", "group-inside-window", 5_000)
          |> Map.put("occurred_on", "2027-01-06"),
          # 29 days before arrival: one day past the 30-day window's end.
          cancel_operation("op-cancel-2", "group-inside-window", "2027-02-09")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 5_000, "retained_cents" => 0},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5_000}
             ] = json_response(conn, 200)["results"]
    end

    test "advance-purchase groups remain non-refundable however early they cancel", %{conn: conn} do
      open_advance_purchase_group(conn, "group-ap")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-ap", 30_000),
          cancel_operation("op-cancel", "group-ap", "2026-10-05")
        ])

      assert [%{"status" => "applied"}, %{"refunded_cents" => 0, "retained_cents" => 30_000}] =
               json_response(conn, 200)["results"]
    end
  end

  describe "issuing hotel credit on cancellation" do
    test "a refundable hotel-credit cancellation converts the cash into a 110% credit lot", %{
      conn: conn
    } do
      open_group(conn, "group-convert")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-convert", 19_000),
          cancel_with_refund_method("op-cancel", "group-convert", "hotel_credit")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 20_900,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 19_000,
                 "credit_liability_cents" => 20_900
               }
             } = get_ledger!()

      assert %{"data" => %{"available_cents" => 20_900, "lots" => [lot]}} =
               get_credit!("guest-22")

      assert %{
               "source_operation_id" => "op-cancel",
               "remaining_cents" => 20_900,
               "expires_on" => "2027-11-27"
             } = lot

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } = get_group!("group-convert")
    end

    test "the 10% bonus follows the standard rounding rule", %{conn: conn} do
      open_group(conn, "group-rounding")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-rounding", 105),
          # 10% of 105 is exactly 10.5, which rounds up to 11: 105 + 11 = 116.
          cancel_with_refund_method("op-cancel", "group-rounding", "hotel_credit")
        ])

      assert [%{"status" => "applied"}, %{"credit_issued_cents" => 116}] =
               json_response(conn, 200)["results"]

      assert %{"data" => %{"credit_liability_cents" => 116}} = get_ledger!()
    end

    test "omitting refund_method still settles in cash", %{conn: conn} do
      open_group(conn, "group-cash-default")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-cash-default", 8_000),
          cancel_operation("op-cancel", "group-cash-default")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "refunded_cents" => 8_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 8_000,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = get_ledger!()
    end

    test "an explicit cash refund_method settles in cash", %{conn: conn} do
      open_group(conn, "group-cash-explicit")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-cash-explicit", 5_000),
          cancel_with_refund_method("op-cancel", "group-cash-explicit", "cash")
        ])

      assert [%{"status" => "applied"}, %{"refunded_cents" => 5_000, "credit_issued_cents" => 0}] =
               json_response(conn, 200)["results"]

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit!("guest-22")
    end

    test "hotel credit cannot bypass a non-refundable flexible cancellation", %{conn: conn} do
      open_group(conn, "group-late")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-late", 7_000),
          cancel_with_refund_method("op-cancel", "group-late", "hotel_credit")
          |> Map.put("occurred_on", "2026-12-01")
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-cancel",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               }
             ] = json_response(conn, 200)["results"]

      # The group stays active and nothing moved.
      assert %{"data" => %{"status" => "active", "revision" => 2, "deposit_paid_cents" => 7_000}} =
               get_group!("group-late")

      assert %{
               "data" => %{
                 "cash_held_cents" => 7_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = get_ledger!()

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit!("guest-22")
    end

    test "hotel credit cannot bypass an advance-purchase policy either", %{conn: conn} do
      open_advance_purchase_group(conn, "group-ap")

      conn =
        post_batch(conn, [
          cash_operation("op-pay", "group-ap", 30_000),
          cancel_with_refund_method("op-cancel", "group-ap", "hotel_credit")
          |> Map.put("occurred_on", "2026-10-05")
        ])

      assert [%{"status" => "applied"}, %{"code" => "refund_method_not_available"}] =
               json_response(conn, 200)["results"]

      assert %{"data" => %{"status" => "active"}} = get_group!("group-ap")
    end

    test "a stale revision rejects before the refund-method rule", %{conn: conn} do
      open_advance_purchase_group(conn, "group-ap")

      conn =
        post_batch(conn, [
          cancel_with_refund_method("op-stale", "group-ap", "hotel_credit")
          |> Map.put("occurred_on", "2026-10-05")
          |> Map.put("expected_revision", 5)
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

      assert %{"data" => %{"status" => "active", "revision" => 1}} = get_group!("group-ap")
    end

    test "an unpaid refundable cancellation issues no credit", %{conn: conn} do
      open_group(conn, "group-unpaid")

      conn =
        post_batch(conn, [
          cancel_with_refund_method("op-cancel", "group-unpaid", "hotel_credit")
        ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit!("guest-22")
      assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger!()
    end
  end

  describe "applying hotel credit" do
    setup :credited_guest

    test "redeems credit into the active deposit and reports the resulting totals", %{
      conn: conn
    } do
      open_group(conn, "group-target")

      conn =
        post_batch(conn, [apply_credit_operation("op-apply", "group-target", 5_000)])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-target",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 5_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500
               }
             } = get_group!("group-target")

      # 8_800 lot minus the 5_000 applied; the applied part keeps counting
      # towards the liability because its expiry is paused.
      assert %{"data" => %{"available_cents" => 3_800}} = get_credit!("guest-22")
      assert %{"data" => %{"credit_liability_cents" => 8_800}} = get_ledger!()

      # Credit is not cash: the cash ledger is untouched.
      assert %{"data" => %{"cash_held_cents" => 0, "cash_converted_to_credit_cents" => 8_000}} =
               get_ledger!()
    end

    test "consumes lots by earliest expiry and omits exhausted lots", %{conn: conn} do
      issue_extra_credit(conn, "group-src-small", 1_000, "2026-11-20", "op-cancel-early")
      # The larger lot expires later than the small one.
      issue_extra_credit(conn, "group-src-large", 2_000, "2026-11-26", "op-cancel-late")

      assert %{
               "data" => %{
                 "available_cents" => 12_100,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-early", "remaining_cents" => 1_100},
                   %{"source_operation_id" => "op-cancel-late", "remaining_cents" => 2_200},
                   %{"source_operation_id" => "op-cancel-source", "remaining_cents" => 8_800}
                 ]
               }
             } = get_credit!("guest-22")

      open_group(conn, "group-target")
      post_batch(conn, [apply_credit_operation("op-apply", "group-target", 1_500)])

      # The earliest lot (expiring 2027-11-21) funds the whole application and
      # is exhausted; only the later lots remain visible.
      assert %{
               "data" => %{
                 "available_cents" => 10_600,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-late",
                     "remaining_cents" => 1_800,
                     "expires_on" => "2027-11-27"
                   },
                   %{
                     "source_operation_id" => "op-cancel-source",
                     "remaining_cents" => 8_800,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             } = get_credit!("guest-22")
    end

    test "equal expiries are consumed by source_operation_id order", %{conn: conn} do
      issue_extra_credit(conn, "group-src-b", 1_000, "2026-11-26", "op-cancel-b")
      issue_extra_credit(conn, "group-src-a", 2_000, "2026-11-26", "op-cancel-a")

      assert %{
               "data" => %{
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-a"},
                   %{"source_operation_id" => "op-cancel-b"},
                   %{"source_operation_id" => "op-cancel-source"}
                 ]
               }
             } = get_credit!("guest-22")

      open_group(conn, "group-target")
      post_batch(conn, [apply_credit_operation("op-apply", "group-target", 1_100)])

      # The whole draw comes from op-cancel-a even though op-cancel-b was
      # issued first.
      assert %{
               "data" => %{
                 "available_cents" => 11_000,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-a", "remaining_cents" => 1_100},
                   %{"source_operation_id" => "op-cancel-b", "remaining_cents" => 1_100},
                   %{"source_operation_id" => "op-cancel-source", "remaining_cents" => 8_800}
                 ]
               }
             } = get_credit!("guest-22")
    end

    test "rejects amounts above the guest's unexpired credit without changing anything", %{
      conn: conn
    } do
      open_group(conn, "group-target")

      # Above the guest's 8_800 credit but below the group's outstanding
      # deposit, so the credit shortage is what rejects it.
      conn = post_batch(conn, [apply_credit_operation("op-apply", "group-target", 12_000)])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "insufficient_credit"}]
             } = json_response(conn, 200)

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get_group!("group-target")

      assert %{"data" => %{"available_cents" => 8_800, "lots" => [lot]}} = get_credit!("guest-22")
      assert %{"remaining_cents" => 8_800} = lot
    end

    test "evaluates expiry using the operation's occurred_on date", %{conn: conn} do
      open_group(conn, "group-target")

      # The lot expires on 2027-11-27, so it is unavailable from that date.
      conn =
        post_batch(conn, [
          apply_credit_operation("op-expired", "group-target", 1_000)
          |> Map.put("occurred_on", "2027-11-27"),
          apply_credit_operation("op-valid", "group-target", 1_000)
          |> Map.put("occurred_on", "2026-11-30")
        ])

      assert [
               %{"status" => "rejected", "code" => "insufficient_credit"},
               %{"status" => "applied"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects credit above the outstanding deposit", %{conn: conn} do
      open_group(conn, "group-target")

      conn = post_batch(conn, [apply_credit_operation("op-apply", "group-target", 19_501)])

      assert %{"results" => [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}]} =
               json_response(conn, 200)
    end

    test "follows the existing payment validation errors", %{conn: conn} do
      open_group(conn, "group-target")
      post_batch(conn, [cancel_operation("op-cancel", "group-target")])

      conn =
        post_batch(conn, [
          apply_credit_operation("op-inactive", "group-target", 1_000),
          apply_credit_operation("op-missing", "group-nowhere", 1_000),
          apply_credit_operation("op-zero", "group-target", 0),
          apply_credit_operation("op-negative", "group-target", -5)
        ])

      assert [
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_found"},
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "rejected", "code" => "invalid_amount"}
             ] = json_response(conn, 200)["results"]
    end

    test "follows the revision contract", %{conn: conn} do
      open_group(conn, "group-target")

      matching =
        apply_credit_operation("op-apply-1", "group-target", 1_000)
        |> Map.put("expected_revision", 1)

      stale =
        apply_credit_operation("op-apply-2", "group-target", 1_000)
        |> Map.put("expected_revision", 1)

      conn = post_batch(conn, [matching, stale])

      assert [
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 2}} = get_group!("group-target")
    end
  end

  describe "settling a group funded by hotel credit" do
    setup :credited_guest

    defp fund_target(conn, cash_cents, credit_cents) do
      open_group(conn, "group-target")

      operations =
        [
          if(cash_cents > 0,
            do: cash_operation("op-pay-cash", "group-target", cash_cents),
            else: nil
          ),
          if(credit_cents > 0,
            do:
              apply_credit_operation("op-apply-credit", "group-target", credit_cents)
              |> Map.put("occurred_on", "2026-10-05"),
            else: nil
          )
        ]
        |> Enum.reject(&is_nil/1)

      post_batch(conn, operations)
    end

    test "a refundable cash cancellation refunds only the cash and restores the credit", %{
      conn: conn
    } do
      fund_target(conn, 6_000, 5_000)

      conn = post_batch(conn, [cancel_operation("op-cancel-target", "group-target")])

      # open -> cash -> credit -> cancel: the fourth applied operation.
      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 6_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      # The credit returns to its original lot with its original expiry.
      assert %{
               "data" => %{
                 "available_cents" => 8_800,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-source",
                     "remaining_cents" => 8_800,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             } = get_credit!("guest-22")

      assert %{"data" => %{"credit_liability_cents" => 8_800}} = get_ledger!()

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             } = get_group!("group-target")
    end

    test "a refundable hotel-credit cancellation issues a new lot and restores the old one", %{
      conn: conn
    } do
      fund_target(conn, 6_000, 5_000)

      conn =
        post_batch(conn, [
          cancel_with_refund_method("op-cancel-target", "group-target", "hotel_credit")
        ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 6_600
               }
             ] = json_response(conn, 200)["results"]

      # The restored original lot never receives a second bonus.
      assert %{
               "data" => %{
                 "available_cents" => 15_400,
                 "lots" => [
                   %{
                     "source_operation_id" => "op-cancel-source",
                     "remaining_cents" => 8_800,
                     "expires_on" => "2027-11-27"
                   },
                   %{
                     "source_operation_id" => "op-cancel-target",
                     "remaining_cents" => 6_600,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             } = get_credit!("guest-22")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 14_000,
                 "credit_liability_cents" => 15_400
               }
             } = get_ledger!()
    end

    test "credit restored to an expired lot expires immediately instead", %{conn: conn} do
      # Funded entirely by credit from the lot expiring 2027-11-27...
      fund_target(conn, 0, 5_000)

      # ...then move the stay beyond the lot's expiry and cancel while
      # refundable, after that expiry has passed.
      conn =
        post_batch(conn, [
          reschedule_operation("op-move", "2027-12-01", "2028-01-15", "group-target"),
          cancel_operation("op-cancel-target", "group-target", "2027-12-01")
        ])

      assert [
               %{"status" => "applied", "new_arrival_on" => "2028-01-15"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      # The restored 5_000 is lost; only the untouched remainder survives.
      assert %{
               "data" => %{
                 "available_cents" => 3_800,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-source", "remaining_cents" => 3_800}
                 ]
               }
             } = get_credit!("guest-22")

      assert %{"data" => %{"credit_liability_cents" => 3_800}} = get_ledger!()
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      fund_target(conn, 2_000, 5_000)

      conn =
        post_batch(conn, [
          cancel_operation("op-cancel-target", "group-target", "2026-12-01")
        ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 2_000,
                 "credit_issued_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      # The consumed credit is gone for good; the untouched remainder is left.
      assert %{
               "data" => %{
                 "available_cents" => 3_800,
                 "lots" => [
                   %{"source_operation_id" => "op-cancel-source", "remaining_cents" => 3_800}
                 ]
               }
             } = get_credit!("guest-22")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_retained_cents" => 2_000,
                 "credit_liability_cents" => 3_800
               }
             } = get_ledger!()
    end
  end

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "returns zeros for a guest without credit", %{conn: _conn} do
      assert %{
               "data" => %{
                 "guest_id" => "guest-nobody",
                 "available_cents" => 0,
                 "lots" => []
               }
             } = get_credit!("guest-nobody")
    end

    test "orders lots by expires_on then source_operation_id", %{conn: conn} do
      credited_guest(%{conn: conn})
      issue_extra_credit(conn, "group-src-small", 1_000, "2026-11-20", "op-z-lot")

      # The lot expiring 2027-11-21 comes first even though it was issued last
      # and its operation id sorts later.
      assert %{
               "data" => %{
                 "lots" => [
                   %{"source_operation_id" => "op-z-lot", "expires_on" => "2027-11-21"},
                   %{"source_operation_id" => "op-cancel-source", "expires_on" => "2027-11-27"}
                 ]
               }
             } = get_credit!("guest-22")
    end

    test "reports expiry relative to the on query parameter", %{conn: conn} do
      credited_guest(%{conn: conn})

      # On the last available day the lot is still usable.
      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-26")
      assert %{"data" => %{"available_cents" => 8_800}} = json_response(conn, 200)

      # From the expiry date onwards it is gone.
      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-27")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/ledger credit liability" do
    test "starts at zero", %{conn: _conn} do
      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = get_ledger!()
    end

    test "reports expiry as of the on query parameter", %{conn: conn} do
      credited_guest(%{conn: conn})

      conn = get(conn, "/api/v1/ledger?on=2027-11-26")
      assert %{"data" => %{"credit_liability_cents" => 8_800}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-11-27")
      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "applying credit to an active group does not change the liability", %{conn: conn} do
      credited_guest(%{conn: conn})
      open_group(conn, "group-target")

      before = build_conn() |> get("/api/v1/ledger") |> json_response(200)

      post_batch(conn, [apply_credit_operation("op-apply", "group-target", 2_000)])

      after_apply = build_conn() |> get("/api/v1/ledger") |> json_response(200)

      assert before["data"]["credit_liability_cents"] ==
               after_apply["data"]["credit_liability_cents"]
    end
  end

  ## Helpers

  # Opens a group, pays cash, and cancels refundably with hotel credit so the
  # guest holds one lot worth 110% of the cash: 8_000 -> 8_800 expiring
  # 2027-11-27 (available through 2027-11-26).
  defp credited_guest(context) do
    conn = context.conn
    issue_extra_credit(conn, "group-source", 8_000, "2026-11-26", "op-cancel-source")
    :ok
  end

  defp issue_extra_credit(conn, group_id, cash_cents, cancel_on, operation_id) do
    conn
    |> post_batch([
      open_operation(group_id, "2026-09-01", "2027-06-10", "2027-06-13"),
      cash_operation("op-pay-#{group_id}", group_id, cash_cents),
      cancel_with_refund_method(operation_id, group_id, "hotel_credit")
      |> Map.put("occurred_on", cancel_on)
    ])
    |> json_response(200)
    |> then(fn %{"results" => [open, _pay, cancel]} ->
      assert %{"status" => "applied"} = open
      assert %{"status" => "applied"} = cancel
      :ok
    end)
  end

  defp open_group(
         conn,
         group_id,
         rate_plan \\ "flexible",
         occurred_on \\ @open_occurred_on,
         arrival_on \\ @arrival_on,
         departure_on \\ @departure_on
       ) do
    conn
    |> post_batch([open_operation(group_id, occurred_on, arrival_on, departure_on, rate_plan)])
    |> json_response(200)
    |> then(fn %{"results" => [result]} ->
      assert %{"status" => "applied", "group_id" => ^group_id, "revision" => 1} = result
    end)
  end

  defp open_advance_purchase_group(conn, group_id) do
    operation =
      open_operation(group_id, @open_occurred_on, @arrival_on, @departure_on)
      |> Map.put("rate_plan", "advance_purchase")
      |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

    conn
    |> post_batch([operation])
    |> json_response(200)
    |> then(fn %{"results" => [result]} ->
      assert %{"status" => "applied", "deposit_due_cents" => 30_000} = result
    end)
  end

  defp open_operation(group_id, occurred_on, arrival_on, departure_on, rate_plan \\ "flexible") do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => departure_on,
      "rate_plan" => rate_plan,
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp cash_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reschedule_operation(operation_id, occurred_on, new_arrival_on, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on \\ @refundable_until_flex14) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp cancel_with_refund_method(operation_id, group_id, refund_method) do
    cancel_operation(operation_id, group_id)
    |> Map.put("refund_method", refund_method)
  end

  defp apply_credit_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp post_batch(_conn, operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp get_group!(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_credit!(guest_id) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
  end

  defp get_ledger! do
    build_conn()
    |> get("/api/v1/ledger")
    |> json_response(200)
  end
end
