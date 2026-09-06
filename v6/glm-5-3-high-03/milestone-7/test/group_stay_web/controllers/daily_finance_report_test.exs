defmodule GroupStayWeb.DailyFinanceReportTest do
  @moduledoc """
  End-to-end coverage of the daily finance report: starting finance
  reporting, the opening position it fixes, the posting dates and classified
  movements of later operations, credit expiry without operations, and the
  report's reconciliation with the current views.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  defp report(date), do: json_response(get_daily_report(date), 200)["data"]

  defp ledger(on), do: json_response(get_ledger(on), 200)["data"]

  defp cash_entry(date, property_id) do
    Enum.find(report(date)["cash"], &(&1["property_id"] == property_id))
  end

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp zero_late_adjustments do
    %{
      "cash" => [],
      "credit" => zero_credit_movements()
    }
  end

  describe "starting finance reporting" do
    test "applies and returns exactly operation_id, status, and starts_on" do
      conn = post_batch([start_reporting_operation("start-1", "2026-11-01")])

      assert results(conn) == [
               %{
                 "operation_id" => "start-1",
                 "status" => "applied",
                 "starts_on" => "2026-11-01"
               }
             ]
    end

    test "rejects an invalid or missing starts_on as invalid_reporting_date" do
      conn = post_batch([start_reporting_operation("start-1", "not-a-date")])

      assert result_for(conn, "start-1") == %{
               "operation_id" => "start-1",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      conn = post_batch([start_reporting_operation("start-2", nil)])

      assert result_for(conn, "start-2") == %{
               "operation_id" => "start-2",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }
    end

    test "rejects a different start operation once reporting has started" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])

      conn = post_batch([start_reporting_operation("start-2", "2026-11-05")])

      assert result_for(conn, "start-2") == %{
               "operation_id" => "start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      # a retry of the rejected second start returns its stored rejection
      conn = post_batch([start_reporting_operation("start-2", "2026-11-05")])

      assert result_for(conn, "start-2")["code"] == "reporting_already_started"

      # a retry of the original start follows the durable replay rules
      conn = post_batch([start_reporting_operation("start-1", "2026-11-01")])

      assert result_for(conn, "start-1") == %{
               "operation_id" => "start-1",
               "status" => "applied",
               "starts_on" => "2026-11-01"
             }
    end

    test "reports the stored result of a start operation through the operations endpoint" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])

      assert json_response(get_operation("start-1"), 200)["data"] == %{
               "operation_id" => "start-1",
               "status" => "applied",
               "starts_on" => "2026-11-01"
             }
    end
  end

  describe "reading one day" do
    test "returns 422 for a missing or invalid date" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])

      assert json_response(get_daily_report(), 422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert json_response(get_daily_report("11/01/2026"), 422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "returns 404 before reporting has started" do
      assert json_response(get_daily_report("2026-11-01"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "returns 404 for a date before starts_on" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])

      assert json_response(get_daily_report("2026-10-31"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "has the documented shape with properties ordered by property_id" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
        pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-10-04"}),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-4", "group-82", 2_000, %{"occurred_on" => "2026-11-02"}),
        # a property whose opening, movements, and closing are all zero is omitted
        open_group_operation("op-5", %{"group_id" => "group-83", "property_id" => "lon-kings"})
      ])

      assert report("2026-11-02") == %{
               "date" => "2026-11-02",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 5_000,
                   "movements" => zero_cash_movements(),
                   "closing_held_cents" => 5_000
                 },
                 %{
                   "property_id" => "par-eiffel",
                   "opening_held_cents" => 0,
                   "movements" => Map.merge(zero_cash_movements(), %{"received_cents" => 2_000}),
                   "closing_held_cents" => 2_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => zero_late_adjustments()
             }
    end
  end

  describe "the opening position" do
    test "includes every operation committed before the start, even one on or after starts_on" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-15"}),
        start_reporting_operation("start-1", "2026-11-01")
      ])

      # the payment committed before the start belongs to the opening
      # position, not to a movement on its occurred_on date
      entry = cash_entry("2026-11-20", "ams-canal")

      assert entry["opening_held_cents"] == 5_000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 5_000
    end

    test "in the same batch, operations before the start open and operations after it move" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-15"}),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-3", "group-81", 3_000, %{"occurred_on" => "2026-10-20"})
      ])

      entry = cash_entry("2026-11-01", "ams-canal")

      assert entry["opening_held_cents"] == 5_000
      assert entry["movements"]["received_cents"] == 3_000
      assert entry["closing_held_cents"] == 8_000
    end
  end

  describe "posting dates" do
    test "use the later of occurred_on and starts_on" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        # occurred_on before starts_on: posts on starts_on
        pay_operation("op-2", "group-81", 3_000, %{"occurred_on" => "2026-10-20"}),
        # occurred_on after starts_on: posts on occurred_on
        pay_operation("op-3", "group-81", 2_000, %{"occurred_on" => "2026-11-10"})
      ])

      assert cash_entry("2026-11-01", "ams-canal")["movements"]["received_cents"] == 3_000

      assert cash_entry("2026-11-09", "ams-canal")["movements"]["received_cents"] == 3_000

      entry = cash_entry("2026-11-10", "ams-canal")

      assert entry["movements"]["received_cents"] == 5_000
      assert entry["closing_held_cents"] == 5_000
    end

    test "a later submission changes an earlier open report" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01")
      ])

      before = report("2026-11-03")
      assert before["cash"] == []

      post_batch([pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"})])

      after_submission = report("2026-11-03")

      assert after_submission["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => Map.merge(zero_cash_movements(), %{"received_cents" => 5_000}),
                 "closing_held_cents" => 5_000
               }
             ]
    end
  end

  describe "cash movements" do
    test "a refundable cancellation reports refunded cash" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-05"})
      ])

      entry = cash_entry("2026-11-05", "ams-canal")

      assert entry["opening_held_cents"] == 5_000
      assert entry["movements"]["refunded_cents"] == 5_000
      assert entry["closing_held_cents"] == 0
    end

    test "a non-refundable cancellation reports retained cash" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        # one day past the 14-day window of the flex-14 policy
        cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-28"})
      ])

      entry = cash_entry("2026-11-28", "ams-canal")

      assert entry["movements"]["retained_cents"] == 5_000
      assert entry["closing_held_cents"] == 0
    end

    test "a hotel-credit settlement reports converted cash and issued credit" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        })
      ])

      entry = cash_entry("2026-11-05", "ams-canal")

      assert entry["movements"]["converted_to_credit_cents"] == 5_000
      assert entry["closing_held_cents"] == 0

      credit = report("2026-11-05")["credit"]

      assert credit["movements"]["issued_cents"] == 5_500
      assert credit["closing_liability_cents"] == 5_500
    end

    test "a transfer reports equal transferred-in and transferred-out amounts" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
        pay_operation("op-3", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        transfer_operation("op-4", "group-81", "group-82", 2_000, %{"occurred_on" => "2026-11-02"})
      ])

      source = cash_entry("2026-11-02", "ams-canal")
      destination = cash_entry("2026-11-02", "par-eiffel")

      assert source["movements"]["transferred_out_cents"] == 2_000
      assert source["closing_held_cents"] == 3_000

      assert destination["movements"]["transferred_in_cents"] == 2_000
      assert destination["closing_held_cents"] == 2_000

      total_transferred_out =
        report("2026-11-02")["cash"]
        |> Enum.map(& &1["movements"]["transferred_out_cents"])
        |> Enum.sum()

      total_transferred_in =
        report("2026-11-02")["cash"]
        |> Enum.map(& &1["movements"]["transferred_in_cents"])
        |> Enum.sum()

      assert total_transferred_in == total_transferred_out
    end

    test "a reduction follows the affected cash to the property where it is held" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
        pay_operation("op-3", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        transfer_operation("op-4", "group-81", "group-82", 3_000, %{"occurred_on" => "2026-11-02"}),
        reduce_cash_operation("op-5", "op-3", 1_000, %{"occurred_on" => "2026-11-03"})
      ])

      # the reduction removes the payment's held cash in reverse allocation
      # order: the most recently transferred allocation first, at par-eiffel
      source = cash_entry("2026-11-03", "ams-canal")

      assert source["movements"]["reduced_cents"] == 0
      assert source["closing_held_cents"] == 2_000

      destination = cash_entry("2026-11-03", "par-eiffel")

      assert destination["movements"]["reduced_cents"] == 1_000
      assert destination["closing_held_cents"] == 2_000
    end

    test "a chargeback of held cash reports charged-back cash" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        charge_back_operation("op-3", "op-2", %{"occurred_on" => "2026-11-05"})
      ])

      entry = cash_entry("2026-11-05", "ams-canal")

      assert entry["movements"]["charged_back_cents"] == 5_000
      assert entry["closing_held_cents"] == 0
    end

    test "a chargeback follows transferred cash to the property where it is held" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
        pay_operation("op-3", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        transfer_operation("op-4", "group-81", "group-82", 3_000, %{"occurred_on" => "2026-11-02"}),
        charge_back_operation("op-5", "op-3", %{"occurred_on" => "2026-11-05"})
      ])

      source = cash_entry("2026-11-05", "ams-canal")

      assert source["movements"]["transferred_out_cents"] == 3_000
      assert source["movements"]["charged_back_cents"] == 2_000
      assert source["closing_held_cents"] == 0

      destination = cash_entry("2026-11-05", "par-eiffel")

      assert destination["movements"]["transferred_in_cents"] == 3_000
      assert destination["movements"]["charged_back_cents"] == 3_000
      assert destination["closing_held_cents"] == 0

      assert ledger("2026-11-05")["cash_held_cents"] == 0
      assert ledger("2026-11-05")["cash_charged_back_cents"] == 5_000
    end

    test "a chargeback after a refund reports negative refunded with charged back" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        # the refund settled before reporting started, so it is opening
        # history rather than a reported movement
        cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-10-20"}),
        start_reporting_operation("start-1", "2026-11-01"),
        charge_back_operation("op-4", "op-2", %{"occurred_on" => "2026-11-10"})
      ])

      entry = cash_entry("2026-11-10", "ams-canal")

      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["refunded_cents"] == -5_000
      assert entry["movements"]["charged_back_cents"] == 5_000
      assert entry["closing_held_cents"] == 0

      # and reconciles with the ledger
      assert ledger("2026-11-10")["cash_refunded_cents"] == 0
      assert ledger("2026-11-10")["cash_charged_back_cents"] == 5_000
    end

    test "a chargeback of converted cash reports the reversal and revoked credit" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        # the conversion issued its lot before reporting started
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-10-20",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation("start-1", "2026-11-01"),
        charge_back_operation("op-4", "op-2", %{"occurred_on" => "2026-11-10"})
      ])

      entry = cash_entry("2026-11-10", "ams-canal")

      assert entry["movements"]["converted_to_credit_cents"] == -5_000
      assert entry["movements"]["charged_back_cents"] == 5_000
      assert entry["closing_held_cents"] == 0

      credit = report("2026-11-10")["credit"]

      assert credit["opening_liability_cents"] == 5_500
      assert credit["movements"]["revoked_cents"] == 5_500
      assert credit["closing_liability_cents"] == 0
    end

    test "a shortfall absorption reports absorbed credit when the credit returns" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        apply_credit_operation("op-5", "group-82", 5_500, %{"occurred_on" => "2026-11-10"}),
        # the lot is spent, so the clawback becomes unrecovered shortfall
        charge_back_operation("op-6", "op-2", %{"occurred_on" => "2026-11-20"}),
        # the refundable cancellation restores the credit into the shortfalled
        # lot, where the unrecovered clawback absorbs it
        cancel_operation("op-7", "group-82", %{"occurred_on" => "2026-11-25"})
      ])

      assert report("2026-11-20")["credit"]["movements"]["revoked_cents"] == 0

      credit = report("2026-11-25")["credit"]

      assert credit["movements"]["absorbed_cents"] == 5_500
      assert credit["closing_liability_cents"] == 0
    end
  end

  describe "credit movements" do
    test "unused credit expires on its expires_on date, with no operation that day" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        })
      ])

      # the lot is available through 2027-11-05 and expires on 2027-11-06
      before = report("2027-11-05")["credit"]

      assert before["movements"]["expired_cents"] == 0
      assert before["closing_liability_cents"] == 5_500

      on_expiry = report("2027-11-06")["credit"]

      assert on_expiry["movements"]["issued_cents"] == 5_500
      assert on_expiry["movements"]["expired_cents"] == 5_500
      assert on_expiry["closing_liability_cents"] == 0

      # and reconciles with the ledger view of that date
      assert ledger("2027-11-05")["credit_liability_cents"] == 5_500
      assert ledger("2027-11-06")["credit_liability_cents"] == 0
    end

    test "a non-refundable settlement of applied credit reports consumed credit" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        }),
        apply_credit_operation("op-5", "group-82", 2_000, %{"occurred_on" => "2026-11-10"}),
        # advance purchase is always non-refundable
        cancel_operation("op-6", "group-82", %{"occurred_on" => "2026-11-15"})
      ])

      # applying credit does not itself change the liability
      assert report("2026-11-10")["credit"]["closing_liability_cents"] == 5_500

      credit = report("2026-11-15")["credit"]

      assert credit["movements"]["consumed_cents"] == 2_000
      assert credit["closing_liability_cents"] == 3_500

      assert ledger("2026-11-15")["credit_liability_cents"] == 3_500
    end

    test "restored credit whose lot has expired expires immediately on the restore date" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        # lot worth 5_500, available through 2027-11-05
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-04"
        }),
        apply_credit_operation("op-5", "group-82", 2_000, %{"occurred_on" => "2026-11-10"}),
        # refundable cancellation after the lot expired: the restored amount
        # expires immediately instead of becoming available again
        cancel_operation("op-6", "group-82", %{"occurred_on" => "2027-11-10"})
      ])

      credit = report("2027-11-10")["credit"]

      # 3_500 unused cents expired on the lot's expires_on date; the restored
      # 2_000 expired on the restore date
      assert credit["movements"]["issued_cents"] == 5_500
      assert credit["movements"]["expired_cents"] == 5_500
      assert credit["closing_liability_cents"] == 0

      assert ledger("2027-11-10")["credit_liability_cents"] == 0
    end

    test "a lot expiring exactly on starts_on is in the opening and expires that day" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        # lot worth 5_500, expires on 2027-11-06
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation("start-1", "2027-11-06")
      ])

      credit = report("2027-11-06")["credit"]

      assert credit["opening_liability_cents"] == 5_500
      assert credit["movements"]["expired_cents"] == 5_500
      assert credit["closing_liability_cents"] == 0
    end

    test "a clawback of an already-expired lot counts with the lot's expiry, not as a revocation" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        # lot worth 5_500, expires on 2027-11-06
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        # charged back after the lot expired: the liability had already left
        # through the lot's expiry
        charge_back_operation("op-4", "op-2", %{"occurred_on" => "2027-11-10"})
      ])

      # the report read before the chargeback still shows the expiry
      before = report("2027-11-06")["credit"]
      assert before["movements"]["expired_cents"] == 5_500

      # and after the chargeback the amounts are unchanged: the clawback of
      # expired credit does not revoke liability a second time
      after_chargeback = report("2027-11-10")["credit"]

      assert after_chargeback["movements"]["issued_cents"] == 5_500
      assert after_chargeback["movements"]["expired_cents"] == 5_500
      assert after_chargeback["movements"]["revoked_cents"] == 0
      assert after_chargeback["closing_liability_cents"] == 0

      # the cash side still reports the charged-back conversion: the
      # conversion posted on 2026-11-05 and its reversal on 2027-11-10, so
      # the report nets them to zero charged-back cash
      entry = cash_entry("2027-11-10", "ams-canal")

      assert entry["movements"]["converted_to_credit_cents"] == 0
      assert entry["movements"]["charged_back_cents"] == 5_000
      assert entry["closing_held_cents"] == 0
    end

    test "credit issued before reporting starts belongs to the opening liability" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-10-20",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation("start-1", "2026-11-01")
      ])

      credit = report("2026-11-01")["credit"]

      assert credit["opening_liability_cents"] == 5_500
      assert credit["movements"] == zero_credit_movements()
      assert credit["closing_liability_cents"] == 5_500

      # the pre-start conversion is opening history, not a movement
      assert report("2026-11-01")["cash"] == []
    end
  end

  describe "reconciliation" do
    test "closing positions reconcile with the ledger and group views" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{
          "group_id" => "group-82",
          "property_id" => "par-eiffel",
          "rate_plan" => "advance_purchase"
        }),
        pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-10-04"}),
        cancel_operation("op-4", "group-81", %{
          "occurred_on" => "2026-10-20",
          "refund_method" => "hotel_credit"
        }),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-5", "group-82", 4_000, %{"occurred_on" => "2026-11-02"}),
        apply_credit_operation("op-6", "group-82", 2_000, %{"occurred_on" => "2026-11-03"}),
        cancel_operation("op-7", "group-82", %{"occurred_on" => "2026-11-05"})
      ])

      data = report("2026-11-05")

      # ams-canal holds no active funding and had no movements: omitted
      assert Enum.map(data["cash"], & &1["property_id"]) == ["par-eiffel"]

      entry = hd(data["cash"])

      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 4_000
      assert entry["movements"]["retained_cents"] == 4_000
      assert entry["closing_held_cents"] == 0

      assert data["credit"]["opening_liability_cents"] == 5_500
      assert data["credit"]["movements"]["consumed_cents"] == 2_000
      assert data["credit"]["closing_liability_cents"] == 3_500

      ledger_data = ledger("2026-11-05")

      closing_total =
        data["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

      assert closing_total == ledger_data["cash_held_cents"]

      assert data["credit"]["closing_liability_cents"] ==
               ledger_data["credit_liability_cents"]
    end

    test "read reports in any order, or repeatedly, never changes a report or state" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
        pay_operation("op-3", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        transfer_operation("op-4", "group-81", "group-82", 2_000, %{"occurred_on" => "2026-11-02"})
      ])

      first_read = report("2026-11-02")
      ledger_before = ledger("2026-11-02")

      # read in a different order, and read one day repeatedly
      _ = report("2027-01-01")
      _ = report("2026-11-01")
      assert report("2026-11-02") == first_read
      assert report("2026-11-02") == first_read

      assert ledger("2026-11-02") == ledger_before
    end
  end

  describe "durability" do
    test "rejected operations leave no movement and retries never report twice" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"}),
        # rejected after the applied payment, without undoing its movement
        pay_operation("op-3", "group-81", 999_999, %{"occurred_on" => "2026-11-02"}),
        cancel_operation("op-4", "group-81", %{
          "occurred_on" => "2026-11-02",
          "expected_revision" => 99
        })
      ])

      assert result_for(post_batch([pay_operation("op-3", "group-81", 999_999)]), "op-3")[
               "status"
             ] == "rejected"

      entry = cash_entry("2026-11-02", "ams-canal")

      assert entry["movements"] ==
               Map.merge(zero_cash_movements(), %{"received_cents" => 5_000})

      # a durable retry returns its stored result and reports no movement twice
      post_batch([pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"})])

      assert cash_entry("2026-11-02", "ams-canal")["movements"]["received_cents"] == 5_000
    end

    test "a batched submission produces the documented two-phase reports" do
      two_phase_operations()
      |> post_batch()

      assert two_phase_reports() == two_phase_expected_reports()
    end

    test "sequential submissions produce the same reports as one batch" do
      two_phase_operations()
      |> Enum.each(fn operation -> post_batch([operation]) end)

      assert two_phase_reports() == two_phase_expected_reports()
    end
  end

  defp two_phase_operations do
    [
      open_group_operation("op-1"),
      open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
      pay_operation("op-3", "group-81", 5_000),
      start_reporting_operation("start-1", "2026-11-01"),
      pay_operation("op-4", "group-82", 2_000, %{"occurred_on" => "2026-11-02"}),
      transfer_operation("op-5", "group-81", "group-82", 1_000, %{"occurred_on" => "2026-11-03"})
    ]
  end

  defp two_phase_reports do
    %{
      "2026-11-01" => report("2026-11-01"),
      "2026-11-02" => report("2026-11-02"),
      "2026-11-03" => report("2026-11-03")
    }
  end

  defp two_phase_expected_reports do
    %{
      "2026-11-01" => %{
        "date" => "2026-11-01",
        "status" => "open",
        "cash" => [
          %{
            "property_id" => "ams-canal",
            "opening_held_cents" => 5_000,
            "movements" => zero_cash_movements(),
            "closing_held_cents" => 5_000
          }
        ],
        "credit" => %{
          "opening_liability_cents" => 0,
          "movements" => zero_credit_movements(),
          "closing_liability_cents" => 0
        },
        "late_adjustments" => zero_late_adjustments()
      },
      "2026-11-02" => %{
        "date" => "2026-11-02",
        "status" => "open",
        "cash" => [
          %{
            "property_id" => "ams-canal",
            "opening_held_cents" => 5_000,
            "movements" => zero_cash_movements(),
            "closing_held_cents" => 5_000
          },
          %{
            "property_id" => "par-eiffel",
            "opening_held_cents" => 0,
            "movements" => Map.merge(zero_cash_movements(), %{"received_cents" => 2_000}),
            "closing_held_cents" => 2_000
          }
        ],
        "credit" => %{
          "opening_liability_cents" => 0,
          "movements" => zero_credit_movements(),
          "closing_liability_cents" => 0
        },
        "late_adjustments" => zero_late_adjustments()
      },
      "2026-11-03" => %{
        "date" => "2026-11-03",
        "status" => "open",
        "cash" => [
          %{
            "property_id" => "ams-canal",
            "opening_held_cents" => 5_000,
            "movements" => Map.merge(zero_cash_movements(), %{"transferred_out_cents" => 1_000}),
            "closing_held_cents" => 4_000
          },
          %{
            "property_id" => "par-eiffel",
            "opening_held_cents" => 0,
            "movements" =>
              Map.merge(zero_cash_movements(), %{
                "received_cents" => 2_000,
                "transferred_in_cents" => 1_000
              }),
            "closing_held_cents" => 3_000
          }
        ],
        "credit" => %{
          "opening_liability_cents" => 0,
          "movements" => zero_credit_movements(),
          "closing_liability_cents" => 0
        },
        "late_adjustments" => zero_late_adjustments()
      }
    }
  end
end
