defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  describe "close_finance_period" do
    test "applies with exactly operation_id, status, and period_end_on" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      [result] = post_batch!(build_conn(), [close_finance_period_op()])

      assert result == %{
               "operation_id" => "op-9601",
               "status" => "applied",
               "period_end_on" => "2026-11-06"
             }
    end

    test "rejects when reporting has not started" do
      [result] = post_batch!(build_conn(), [close_finance_period_op()])

      assert result == %{
               "operation_id" => "op-9601",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "rejects a period_end_on before starts_on" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      [result] =
        post_batch!(build_conn(), [close_finance_period_op(%{"period_end_on" => "2026-11-04"})])

      assert result["code"] == "invalid_period"
    end

    test "rejects a missing or invalid period_end_on as invalid_period" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      [missing] = post_batch!(build_conn(), [close_finance_period_op(%{"period_end_on" => nil})])

      [invalid] =
        post_batch!(build_conn(), [
          close_finance_period_op(%{"operation_id" => "op-9602", "period_end_on" => "not-a-date"})
        ])

      assert missing["code"] == "invalid_period"
      assert invalid["code"] == "invalid_period"
    end

    test "rejects a structurally unusable operation as invalid_operation" do
      [result] =
        post_batch!(build_conn(), [close_finance_period_op() |> Map.delete("occurred_on")])

      assert result["code"] == "invalid_operation"
    end

    test "closes through starts_on itself" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      [result] =
        post_batch!(build_conn(), [close_finance_period_op(%{"period_end_on" => "2026-11-05"})])

      assert result["status"] == "applied"
      assert get_daily_report!(build_conn(), "2026-11-05")["status"] == "closed"
    end

    test "a later close must be strictly later than the latest close" do
      apply_batch!(build_conn(), [start_finance_reporting_op(), close_finance_period_op()])

      [same] =
        post_batch!(build_conn(), [close_finance_period_op(%{"operation_id" => "op-9602"})])

      [earlier] =
        post_batch!(build_conn(), [
          close_finance_period_op(%{"operation_id" => "op-9603", "period_end_on" => "2026-11-05"})
        ])

      assert same["code"] == "invalid_period"
      assert earlier["code"] == "invalid_period"
    end

    test "a rejected close does not block a later close of the same period" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      [rejected] =
        post_batch!(build_conn(), [close_finance_period_op(%{"period_end_on" => "2026-11-04"})])

      assert rejected["code"] == "invalid_period"

      [applied] =
        post_batch!(build_conn(), [close_finance_period_op(%{"operation_id" => "op-9602"})])

      assert applied["status"] == "applied"
    end

    test "is durably idempotent" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      op = close_finance_period_op()
      [original] = post_batch!(build_conn(), [op])

      assert post_batch!(build_conn(), [op]) == [original]
      assert get_operation!(build_conn(), "op-9601") == original

      conflicted = close_finance_period_op(%{"period_end_on" => "2026-11-07"})
      [result] = post_batch!(build_conn(), [conflicted])
      assert result["code"] == "operation_id_conflict"
    end
  end

  describe "closing through a date" do
    test "reports through the cutoff close and stay stable across later operations" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000})
      ])

      open_report = get_daily_report!(build_conn(), "2026-11-06")
      assert open_report["status"] == "open"

      apply_batch!(build_conn(), [close_finance_period_op()])

      closed_report = get_daily_report!(build_conn(), "2026-11-06")
      assert closed_report["status"] == "closed"
      assert Map.delete(closed_report, "status") == Map.delete(open_report, "status")

      closed_body = get_daily_report(build_conn(), "date=2026-11-06").resp_body

      # Later operations do not move the closed day: this payment posts on
      # the first open day instead.
      apply_batch!(build_conn(), [
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        })
      ])

      assert get_daily_report!(build_conn(), "2026-11-06") == closed_report

      # A later close does not rewrite it either.
      apply_batch!(build_conn(), [
        close_finance_period_op(%{"operation_id" => "op-9602", "period_end_on" => "2026-11-08"})
      ])

      assert get_daily_report!(build_conn(), "2026-11-06") == closed_report
      assert get_daily_report(build_conn(), "date=2026-11-06").resp_body == closed_body
    end

    test "reports after the cutoff stay open" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op()
      ])

      report = get_daily_report!(build_conn(), "2026-11-07")
      assert report["status"] == "open"
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 10_000
      assert entry["closing_held_cents"] == 10_000
    end

    test "a later close publishes the next period, keeping its late adjustments" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op(),
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        })
      ])

      open_report = get_daily_report!(build_conn(), "2026-11-07")
      assert open_report["status"] == "open"

      apply_batch!(build_conn(), [
        close_finance_period_op(%{"operation_id" => "op-9602", "period_end_on" => "2026-11-08"})
      ])

      closed_report = get_daily_report!(build_conn(), "2026-11-07")
      assert closed_report["status"] == "closed"
      assert Map.delete(closed_report, "status") == Map.delete(open_report, "status")

      [late] = closed_report["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert late["movements"]["received_cents"] == 5_000
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts on the first open day as late adjustments" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op(),
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 5_000
        })
      ])

      # The closed day keeps only the on-time payment.
      closed_report = get_daily_report!(build_conn(), "2026-11-06")
      [closed_entry] = closed_report["cash"]
      assert closed_entry["movements"]["received_cents"] == 10_000
      assert closed_entry["closing_held_cents"] == 10_000
      assert closed_report["late_adjustments"]["cash"] == []

      # The backdated payment lands entirely on the first open day, and its
      # ordinary movement columns stay zero.
      report = get_daily_report!(build_conn(), "2026-11-07")
      [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 15_000

      [late] = report["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert late["movements"]["received_cents"] == 5_000
      assert report["late_adjustments"]["credit"]["issued_cents"] == 0
    end

    test "an operation whose occurred_on is in the open period keeps its date" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op(),
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-11-08",
          "amount_cents" => 5_000
        })
      ])

      report7 = get_daily_report!(build_conn(), "2026-11-07")
      assert report7["cash"] |> hd() |> get_in(["movements", "received_cents"]) == 0
      assert report7["late_adjustments"]["cash"] == []

      report8 = get_daily_report!(build_conn(), "2026-11-08")
      [entry] = report8["cash"]
      assert entry["movements"]["received_cents"] == 5_000
      assert entry["closing_held_cents"] == 15_000
      assert report8["late_adjustments"]["cash"] == []
    end

    test "operations before a close post into its period; after it, on the first open day" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op(),
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 5_000
        })
      ])

      closed_report = get_daily_report!(build_conn(), "2026-11-06")
      assert closed_report["status"] == "closed"
      [entry] = closed_report["cash"]
      assert entry["movements"]["received_cents"] == 10_000
      assert entry["closing_held_cents"] == 10_000

      open_report = get_daily_report!(build_conn(), "2026-11-07")
      [late] = open_report["late_adjustments"]["cash"]
      assert late["movements"]["received_cents"] == 5_000
      assert hd(open_report["cash"])["closing_held_cents"] == 15_000
    end

    test "an operation keeps the posting date chosen at commit across later closes" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op(),
        close_finance_period_op(%{"operation_id" => "op-9602", "period_end_on" => "2026-11-07"})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      assert report["status"] == "closed"
      [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 10_000
      assert report["late_adjustments"]["cash"] == []
    end

    test "posting after a close leaves group, ledger, and stored results unchanged" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      [cancelled] =
        apply_batch!(build_conn(), [cancel_group_op(%{"occurred_on" => "2026-10-10"})])

      assert cancelled["refunded_cents"] == 10_000

      group = get_group!(build_conn(), "group-81")
      assert group["status"] == "cancelled"
      assert get_ledger!(build_conn())["cash_refunded_cents"] == 10_000

      # Only the reporting posting date moved; the refund shows as a late
      # adjustment on the first open day.
      report = get_daily_report!(build_conn(), "2026-11-07")
      [late] = report["late_adjustments"]["cash"]
      assert late["movements"]["refunded_cents"] == 10_000
    end
  end

  describe "late adjustments" do
    test "keeps signed classifications even when the net balance effect is zero" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op(),
        cancel_group_op(%{"occurred_on" => "2026-11-05"}),
        close_finance_period_op()
      ])

      # The refundable cancellation settled on 11-05 inside the closed
      # period; the chargeback posts its whole effect late on 11-07.
      apply_batch!(build_conn(), [charge_back_payment_op(%{"occurred_on" => "2026-11-03"})])

      report = get_daily_report!(build_conn(), "2026-11-07")
      [entry] = report["cash"]
      assert entry["movements"]["refunded_cents"] == 0
      assert entry["movements"]["charged_back_cents"] == 0
      assert entry["closing_held_cents"] == 0

      [late] = report["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert late["movements"]["refunded_cents"] == -10_000
      assert late["movements"]["charged_back_cents"] == 10_000

      # The closed day still shows the original refund.
      closed_report = get_daily_report!(build_conn(), "2026-11-05")
      assert closed_report["status"] == "closed"
      assert hd(closed_report["cash"])["movements"]["refunded_cents"] == 10_000
      assert closed_report["late_adjustments"]["cash"] == []
    end

    test "the day's totals and balances combine ordinary and late movements" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op()
      ])

      apply_batch!(build_conn(), [
        # On-time: posts on 11-07 as an ordinary movement.
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-11-07",
          "amount_cents" => 4_000
        }),
        # Backdated: posts on 11-07 as a late adjustment.
        reduce_cash_payment_op(%{"occurred_on" => "2026-11-01", "amount_cents" => 3_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-07")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 10_000
      assert entry["movements"]["received_cents"] == 4_000
      assert entry["movements"]["reduced_cents"] == 0
      assert entry["closing_held_cents"] == 11_000

      [late] = report["late_adjustments"]["cash"]
      assert late["movements"]["reduced_cents"] == 3_000
    end

    test "credit movements moved forward by a close appear as late adjustments" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      apply_batch!(build_conn(), [
        cancel_group_op(%{"occurred_on" => "2026-10-10", "refund_method" => "hotel_credit"})
      ])

      report = get_daily_report!(build_conn(), "2026-11-07")

      [late_cash] = report["late_adjustments"]["cash"]
      assert late_cash["movements"]["converted_to_credit_cents"] == 19_500

      assert report["credit"]["movements"]["issued_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 21_450
      assert report["credit"]["closing_liability_cents"] == 21_450
    end

    test "the late-adjustments credit object is always present and cash omits all-zero properties" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
        close_finance_period_op()
      ])

      report = get_daily_report!(build_conn(), "2026-11-07")

      assert report["late_adjustments"] == %{
               "cash" => [],
               "credit" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               }
             }
    end
  end
end
