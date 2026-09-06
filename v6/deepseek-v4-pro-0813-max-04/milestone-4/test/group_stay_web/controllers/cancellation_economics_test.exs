defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_group(conn, group_id),
    do: json_response(get(conn, ~p"/api/v1/groups/#{group_id}"), 200)["data"]

  defp ledger(conn, params \\ %{}),
    do: json_response(get(conn, "/api/v1/ledger", params), 200)["data"]

  defp guest_credit(conn, guest_id, params \\ %{}),
    do: json_response(get(conn, "/api/v1/guests/#{guest_id}/credit", params), 200)["data"]

  # A flexible source group fully paid with 10_000 cash, cancelled while
  # refundable with hotel credit. Produces one guest-22 lot of 11_000 cents
  # expiring on 2028-02-02.
  defp issue_credit_lot(conn) do
    source =
      open(%{
        "operation_id" => "op-source",
        "group_id" => "group-source",
        "guest_id" => "guest-22",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

    pay =
      payment(%{
        "operation_id" => "op-pay-source",
        "group_id" => "group-source",
        "amount_cents" => 10_000
      })

    credit_cancel =
      cancel(%{
        "operation_id" => "op-cancel-source",
        "group_id" => "group-source",
        "occurred_on" => "2027-02-01",
        "refund_method" => "hotel_credit"
      })

    batch_results(conn, [source, pay, credit_cancel])
  end

  describe "policy versions" do
    test "flexible groups booked before 2027 use the 14-day window" do
      conn = build_conn()

      op =
        open(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      batch_results(conn, [op])

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-24"
    end

    test "flexible groups booked on 2027-01-01 use the 30-day window" do
      conn = build_conn()

      op =
        open(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      batch_results(conn, [op])

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-02-08"
    end

    test "advance purchase groups are non-refundable and have no refundable_until" do
      conn = build_conn()

      batch_results(conn, [open(%{"rate_plan" => "advance_purchase"})])

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling reports the fixed policy and the recomputed refundable_until" do
      conn = build_conn()

      move = reschedule(%{"new_arrival_on" => "2027-03-10"})

      results = batch_results(conn, [open(), move])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-03-10",
               "new_departure_on" => "2027-03-13",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-24",
               "revision" => 2
             }

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-24"
    end

    test "a group keeps its booking policy even after moving into 2027" do
      conn = build_conn()

      move = reschedule(%{"new_arrival_on" => "2027-03-10"})

      batch_results(conn, [open(), move])

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-24"
    end

    test "flex-30 groups are refundable up to 30 days before arrival" do
      conn = build_conn()

      modern =
        open(%{
          "operation_id" => "op-modern",
          "group_id" => "group-modern",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      modern_pay =
        payment(%{
          "operation_id" => "op-modern-pay",
          "group_id" => "group-modern",
          "amount_cents" => 5_000
        })

      exact =
        cancel(%{
          "operation_id" => "op-exact",
          "group_id" => "group-modern",
          "occurred_on" => "2027-02-08"
        })

      results = batch_results(conn, [modern, modern_pay, exact])

      assert Enum.at(results, 2)["refunded_cents"] == 5_000
      assert Enum.at(results, 2)["retained_cents"] == 0

      late_group =
        open(%{
          "operation_id" => "op-modern-2",
          "group_id" => "group-modern-2",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      late_pay =
        payment(%{
          "operation_id" => "op-modern-2-pay",
          "group_id" => "group-modern-2",
          "amount_cents" => 5_000
        })

      late_cancel =
        cancel(%{
          "operation_id" => "op-late-2",
          "group_id" => "group-modern-2",
          "occurred_on" => "2027-02-09"
        })

      results = batch_results(conn, [late_group, late_pay, late_cancel])

      assert Enum.at(results, 2)["refunded_cents"] == 0
      assert Enum.at(results, 2)["retained_cents"] == 5_000
    end

    test "cancellation on refundable_until itself is refundable" do
      conn = build_conn()

      modern =
        open(%{
          "operation_id" => "op-modern",
          "group_id" => "group-modern",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      pay =
        payment(%{
          "operation_id" => "op-pay",
          "group_id" => "group-modern",
          "amount_cents" => 5_000
        })

      on_the_line =
        cancel(%{
          "operation_id" => "op-on-the-line",
          "group_id" => "group-modern",
          "occurred_on" => "2027-02-08",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [modern, pay, on_the_line])

      assert Enum.at(results, 2)["status"] == "applied"
      assert Enum.at(results, 2)["credit_issued_cents"] == 5_500

      late =
        open(%{
          "operation_id" => "op-late",
          "group_id" => "group-late",
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        })

      late_pay =
        payment(%{
          "operation_id" => "op-late-pay",
          "group_id" => "group-late",
          "amount_cents" => 5_000
        })

      late_cancel =
        cancel(%{
          "operation_id" => "op-late-cancel",
          "group_id" => "group-late",
          "occurred_on" => "2027-02-09",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [late, late_pay, late_cancel])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-late-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert get_group(conn, "group-late")["status"] == "active"
    end
  end

  describe "issuing credit on cancellation" do
    test "converts refundable cash to a 110% credit lot instead of refunding it" do
      conn = build_conn()

      results =
        batch_results(conn, [open(), payment(), cancel(%{"refund_method" => "hotel_credit"})])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 11_000
             }

      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-10-11"
                 }
               ]
             }
    end

    test "rounds the 10% bonus to the nearest cent, half up" do
      conn = build_conn()

      pay = payment(%{"amount_cents" => 10_005})

      results = batch_results(conn, [open(), pay, cancel(%{"refund_method" => "hotel_credit"})])

      # 10% of 10_005 is 1000.5 cents, which rounds up to 1001.
      assert Enum.at(results, 2)["credit_issued_cents"] == 11_006
      assert guest_credit(conn, "guest-22")["available_cents"] == 11_006
    end

    test "rejects hotel credit on a non-refundable cancellation and keeps the group active" do
      conn = build_conn()

      late_cancel = cancel(%{"occurred_on" => "2026-12-05", "refund_method" => "hotel_credit"})

      results = batch_results(conn, [open(), payment(), late_cancel])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert group["outstanding_deposit_cents"] == 9_500

      assert ledger(conn)["cash_held_cents"] == 10_000
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "rejects hotel credit for advance purchase groups" do
      conn = build_conn()

      advance = open(%{"rate_plan" => "advance_purchase"})

      credit_cancel = cancel(%{"refund_method" => "hotel_credit"})

      results = batch_results(conn, [advance, payment(), credit_cancel])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert get_group(conn, "group-81")["status"] == "active"
    end

    test "hotel credit on a group without cash issues no lot" do
      conn = build_conn()

      results = batch_results(conn, [open(), cancel(%{"refund_method" => "hotel_credit"})])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 2
             }

      assert guest_credit(conn, "guest-22")["lots"] == []
    end

    test "checks the revision before the refund method rules" do
      conn = build_conn()

      late_cancel =
        cancel(%{
          "occurred_on" => "2026-12-05",
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        })

      results = batch_results(conn, [open(), payment(), late_cancel])

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "rejects unusable refund_method values with invalid_operation" do
      conn = build_conn()

      results = batch_results(conn, [open(), cancel(%{"refund_method" => "bitcoin"})])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert get_group(conn, "group-81")["status"] == "active"
    end
  end

  describe "applying hotel credit" do
    test "funds the outstanding deposit and drains the lot" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      results = batch_results(conn, [target, apply])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-apply",
               "status" => "applied",
               "group_id" => "group-target",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }

      group = get_group(conn, "group-target")
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 10_000
      assert group["deposit_paid_cents"] == 10_000

      assert guest_credit(conn, "guest-22")["available_cents"] == 1_000
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "rejects with insufficient_credit and leaves everything unchanged" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      too_much =
        apply_credit(%{
          "operation_id" => "op-insufficient",
          "group_id" => "group-target",
          "amount_cents" => 15_000
        })

      assert batch_results(conn, [target, too_much]) |> Enum.at(1) == %{
               "operation_id" => "op-insufficient",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      group = get_group(conn, "group-target")
      assert group["revision"] == 1
      assert group["outstanding_deposit_cents"] == 19_500
      assert group["credit_paid_cents"] == 0

      assert guest_credit(conn, "guest-22")["available_cents"] == 11_000
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "rejects amounts above the outstanding deposit" do
      conn = build_conn()

      # The lot is worth 21_450 cents so credit is plentiful while the
      # outstanding deposit of the target is only 19_500 cents.
      source =
        open(%{
          "operation_id" => "op-source",
          "group_id" => "group-source",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      pay =
        payment(%{
          "operation_id" => "op-pay-source",
          "group_id" => "group-source",
          "amount_cents" => 19_500
        })

      credit_cancel =
        cancel(%{
          "operation_id" => "op-cancel-source",
          "group_id" => "group-source",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit"
        })

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      over =
        apply_credit(%{
          "operation_id" => "op-over",
          "group_id" => "group-target",
          "amount_cents" => 20_000
        })

      results = batch_results(conn, [source, pay, credit_cancel, target, over])

      assert Enum.at(results, 4) == %{
               "operation_id" => "op-over",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert get_group(conn, "group-target")["revision"] == 1
      assert guest_credit(conn, "guest-22")["available_cents"] == 21_450
    end

    test "rejects unusable amounts with invalid_amount" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      zero =
        apply_credit(%{
          "operation_id" => "op-zero",
          "group_id" => "group-target",
          "amount_cents" => 0
        })

      negative =
        apply_credit(%{
          "operation_id" => "op-negative",
          "group_id" => "group-target",
          "amount_cents" => -100
        })

      string =
        apply_credit(%{
          "operation_id" => "op-string",
          "group_id" => "group-target",
          "amount_cents" => "1000"
        })

      results = batch_results(conn, [target, zero, negative, string])

      assert results |> Enum.drop(1) == [
               %{"operation_id" => "op-zero", "status" => "rejected", "code" => "invalid_amount"},
               %{
                 "operation_id" => "op-negative",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               },
               %{
                 "operation_id" => "op-string",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               }
             ]
    end

    test "rejects for missing or cancelled groups" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      missing = apply_credit(%{"operation_id" => "op-missing", "group_id" => "no-such-group"})

      after_cancel =
        apply_credit(%{"operation_id" => "op-after-cancel", "group_id" => "group-target"})

      results =
        batch_results(conn, [
          missing,
          target,
          cancel(%{"operation_id" => "op-cancel-target", "group_id" => "group-target"}),
          after_cancel
        ])

      assert Enum.at(results, 0)["code"] == "group_not_found"

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-after-cancel",
               "status" => "rejected",
               "code" => "group_not_active"
             }
    end

    test "cannot be covered by another guest's credit" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-99"
        })

      apply = apply_credit(%{"group_id" => "group-target"})

      assert batch_results(conn, [target, apply]) |> Enum.at(1) == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }
    end

    test "evaluates lot expiry on the operation's occurred_on" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      expired =
        apply_credit(%{
          "operation_id" => "op-expired",
          "group_id" => "group-target",
          "occurred_on" => "2028-02-02",
          "amount_cents" => 1_000
        })

      on_last_day =
        apply_credit(%{
          "operation_id" => "op-last-day",
          "group_id" => "group-target",
          "occurred_on" => "2028-02-01",
          "amount_cents" => 1_000
        })

      results = batch_results(conn, [target, expired])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-expired",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      results = batch_results(conn, [on_last_day])

      assert Enum.at(results, 0)["status"] == "applied"
      assert get_group(conn, "group-target")["credit_paid_cents"] == 1_000
    end

    test "consumes lots by earliest expiry before source operation id" do
      conn = build_conn()

      # z-mobile cancels earlier (earlier expiry) than a-lot despite sorting
      # later alphabetically; a-lot cancels later and sorts first by id.
      early =
        open(%{
          "operation_id" => "op-open-z",
          "group_id" => "group-z",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      early_pay =
        payment(%{
          "operation_id" => "op-pay-z",
          "group_id" => "group-z",
          "amount_cents" => 10_000
        })

      early_cancel =
        cancel(%{
          "operation_id" => "op-cancel-z",
          "group_id" => "group-z",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit"
        })

      later =
        open(%{
          "operation_id" => "op-open-a",
          "group_id" => "group-a",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      later_pay =
        payment(%{
          "operation_id" => "op-pay-a",
          "group_id" => "group-a",
          "amount_cents" => 10_000
        })

      later_cancel =
        cancel(%{
          "operation_id" => "op-cancel-a",
          "group_id" => "group-a",
          "occurred_on" => "2027-03-01",
          "refund_method" => "hotel_credit"
        })

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply = apply_credit(%{"group_id" => "group-target", "amount_cents" => 12_000})

      batch_results(conn, [
        early,
        early_pay,
        early_cancel,
        later,
        later_pay,
        later_cancel,
        target,
        apply
      ])

      credit = guest_credit(conn, "guest-22")

      # The earlier expiring lot (op-cancel-z) is fully consumed; the later
      # lot keeps 10_000 of its 11_000 cents.
      assert credit["available_cents"] == 10_000

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-a",
                 "remaining_cents" => 10_000,
                 "expires_on" => "2028-03-01"
               }
             ]
    end

    test "breaks equal expiries by source operation id" do
      conn = build_conn()

      first =
        open(%{
          "operation_id" => "op-open-a",
          "group_id" => "group-a",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      first_pay =
        payment(%{
          "operation_id" => "op-pay-a",
          "group_id" => "group-a",
          "amount_cents" => 10_000
        })

      first_cancel =
        cancel(%{
          "operation_id" => "op-cancel-a",
          "group_id" => "group-a",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit"
        })

      second =
        open(%{
          "operation_id" => "op-open-b",
          "group_id" => "group-b",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      second_pay =
        payment(%{
          "operation_id" => "op-pay-b",
          "group_id" => "group-b",
          "amount_cents" => 10_000
        })

      second_cancel =
        cancel(%{
          "operation_id" => "op-cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit"
        })

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply = apply_credit(%{"group_id" => "group-target", "amount_cents" => 12_000})

      batch_results(conn, [
        first,
        first_pay,
        first_cancel,
        second,
        second_pay,
        second_cancel,
        target,
        apply
      ])

      credit = guest_credit(conn, "guest-22")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-b",
                 "remaining_cents" => 10_000,
                 "expires_on" => "2028-02-02"
               }
             ]
    end

    test "honours the revision contract and rejects stale revisions before credit rules" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      expected =
        apply_credit(%{
          "operation_id" => "op-first",
          "group_id" => "group-target",
          "amount_cents" => 10_000,
          "expected_revision" => 1
        })

      stale =
        apply_credit(%{
          "operation_id" => "op-stale",
          "group_id" => "group-target",
          "amount_cents" => 20_000,
          "expected_revision" => 1
        })

      results = batch_results(conn, [target, expected, stale])

      assert Enum.at(results, 1)["status"] == "applied"
      assert Enum.at(results, 1)["revision"] == 2

      assert Enum.at(results, 2) == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-target",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end
  end

  describe "settling credit-funded groups" do
    test "refundable cancellation restores applied credit to its original lot and expiry" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      batch_results(conn, [target, apply])

      results = batch_results(conn, [cancel(%{"group_id" => "group-target"})])

      assert hd(results) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert guest_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-source",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2028-02-02"
                 }
               ]
             }

      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "restoration into a lot that has already expired reduces the liability" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      batch_results(conn, [target, apply])

      assert ledger(conn)["credit_liability_cents"] == 11_000

      late_cancel =
        cancel(%{
          "operation_id" => "op-cancel",
          "group_id" => "group-target",
          "occurred_on" => "2028-02-05"
        })

      batch_results(conn, [late_cancel])

      credit = guest_credit(conn, "guest-22")

      assert credit["available_cents"] == 1_000

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-source",
                 "remaining_cents" => 1_000,
                 "expires_on" => "2028-02-02"
               }
             ]

      assert ledger(conn)["credit_liability_cents"] == 1_000
    end

    test "non-refundable cancellation consumes applied credit" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 10_000
        })

      batch_results(conn, [target, apply])

      assert ledger(conn)["credit_liability_cents"] == 11_000

      late_cancel =
        cancel(%{
          "operation_id" => "op-cancel",
          "group_id" => "group-target",
          "occurred_on" => "2026-12-05"
        })

      results = batch_results(conn, [late_cancel])

      assert hd(results) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert guest_credit(conn, "guest-22")["available_cents"] == 1_000
      assert ledger(conn)["credit_liability_cents"] == 1_000
    end

    test "hotel-credit cancellation bonuses only the cash and never the restored credit" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      target_pay =
        payment(%{
          "operation_id" => "op-pay-target",
          "group_id" => "group-target",
          "amount_cents" => 5_000
        })

      apply =
        apply_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-target",
          "amount_cents" => 5_000
        })

      credit_cancel =
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })

      results = batch_results(conn, [target, target_pay, apply, credit_cancel])

      assert Enum.at(results, 3) == %{
               "operation_id" => "op-cancel-target",
               "status" => "applied",
               "group_id" => "group-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5_500,
               "revision" => 4
             }

      credit = guest_credit(conn, "guest-22")

      assert credit["available_cents"] == 16_500

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-target",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-11-02"
               },
               %{
                 "source_operation_id" => "op-cancel-source",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2028-02-02"
               }
             ]

      assert ledger(conn)["cash_converted_to_credit_cents"] == 15_000
      assert ledger(conn)["credit_liability_cents"] == 16_500
    end
  end

  describe "credit and ledger reads" do
    test "reports expiry as of the current date by default" do
      conn = build_conn()

      issue_credit_lot(conn)

      assert guest_credit(conn, "guest-22")["available_cents"] == 11_000
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end

    test "accepts an on= date that expires lots on their expiry day" do
      conn = build_conn()

      issue_credit_lot(conn)

      assert guest_credit(conn, "guest-22", %{on: "2028-02-01"})["available_cents"] == 11_000

      assert guest_credit(conn, "guest-22", %{on: "2028-02-02"}) == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger(conn, %{on: "2028-02-02"})["credit_liability_cents"] == 0
      # Cash figures are cumulative and do not depend on the date.
      assert ledger(conn, %{on: "2028-02-02"})["cash_converted_to_credit_cents"] == 10_000
      assert ledger(conn, %{on: "2028-02-02"})["cash_refunded_cents"] == 0
    end

    test "reports credit applied to active groups as liability" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      notify = apply_credit(%{"group_id" => "group-target", "amount_cents" => 10_000})

      batch_results(conn, [target, notify])

      assert ledger(conn)["credit_liability_cents"] == 11_000
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "unknown guests have no credit" do
      conn = build_conn()

      assert guest_credit(conn, "guest-404") == %{
               "guest_id" => "guest-404",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "rejects unusable on= dates with 422" do
      conn = build_conn()

      conn = get(conn, "/api/v1/guests/guest-22/credit", %{on: "2028-13-01"})

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}

      conn = build_conn()
      conn = get(conn, "/api/v1/ledger", %{on: "yesterday"})

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end

    test "exhausted lots disappear from reads but unused credit survives" do
      conn = build_conn()

      issue_credit_lot(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      drain = apply_credit(%{"group_id" => "group-target", "amount_cents" => 11_000})

      batch_results(conn, [target, drain])

      group = get_group(conn, "group-target")
      assert group["credit_paid_cents"] == 11_000
      assert group["outstanding_deposit_cents"] == 8_500

      assert guest_credit(conn, "guest-22")["lots"] == []
      assert ledger(conn)["credit_liability_cents"] == 11_000
    end
  end
end
