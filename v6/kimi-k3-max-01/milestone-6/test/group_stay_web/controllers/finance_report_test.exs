defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  describe "start_finance_reporting" do
    test "applies with exactly operation_id, status, and starts_on" do
      [result] =
        post_batch!(build_conn(), [start_finance_reporting_op()])

      assert result == %{
               "operation_id" => "op-9501",
               "status" => "applied",
               "starts_on" => "2026-11-05"
             }
    end

    test "rejects a missing or invalid starts_on" do
      [missing] = post_batch!(build_conn(), [start_finance_reporting_op(%{"starts_on" => nil})])

      [invalid] =
        post_batch!(build_conn(), [
          start_finance_reporting_op(%{"operation_id" => "op-9502", "starts_on" => "not-a-date"})
        ])

      assert missing == %{
               "operation_id" => "op-9501",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      assert invalid["code"] == "invalid_reporting_date"
    end

    test "a rejected first start does not prevent a later valid start" do
      [_rejected] =
        post_batch!(build_conn(), [start_finance_reporting_op(%{"starts_on" => nil})])

      [result] =
        post_batch!(build_conn(), [
          start_finance_reporting_op(%{
            "operation_id" => "op-9502",
            "starts_on" => "2026-11-05"
          })
        ])

      assert result["status"] == "applied"
    end

    test "rejects a different start once reporting has started" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])

      [result] =
        post_batch!(build_conn(), [
          start_finance_reporting_op(%{"operation_id" => "op-9502", "starts_on" => "2026-11-06"})
        ])

      assert result == %{
               "operation_id" => "op-9502",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
    end

    test "is durably idempotent" do
      op = start_finance_reporting_op()
      [original] = post_batch!(build_conn(), [op])

      assert post_batch!(build_conn(), [op]) == [original]

      conflicted =
        start_finance_reporting_op(%{"starts_on" => "2026-11-06"})
        |> Map.put("operation_id", "op-9501")

      [result] = post_batch!(build_conn(), [conflicted])
      assert result["code"] == "operation_id_conflict"
    end
  end

  describe "reading one day" do
    test "returns 422 invalid_reporting_date for a missing or invalid date" do
      conn = build_conn()

      assert get_daily_report(conn, "") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert get_daily_report(conn, "date=nope") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "returns 404 report_not_available before reporting starts" do
      conn = build_conn()

      assert get_daily_report(conn, "date=2026-11-05") |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "returns 404 report_not_available for a date before starts_on" do
      apply_batch!(build_conn(), [start_finance_reporting_op()])
      conn = build_conn()

      assert get_daily_report(conn, "date=2026-11-04") |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "reports movements on the correct posting date" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")

      assert report == %{
               "date" => "2026-11-06",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 10_000,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 10_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
    end

    test "clamps posting to starts_on for an earlier occurred_on" do
      apply_batch!(build_conn(), [open_group_op(), start_finance_reporting_op()])

      apply_batch!(build_conn(), [
        record_cash_payment_op(%{"occurred_on" => "2026-11-01", "amount_cents" => 10_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-05")
      [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 10_000
      assert entry["closing_held_cents"] == 10_000
    end

    test "snapshots the opening position from earlier operations" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op()
      ])

      report = get_daily_report!(build_conn(), "2026-11-05")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 10_000
      assert Enum.all?(Map.values(entry["movements"]), &(&1 == 0))
      assert entry["closing_held_cents"] == 10_000
    end

    test "in one batch, operations before the start open and after it move" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op(),
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "amount_cents" => 5_000,
          "occurred_on" => "2026-11-06"
        })
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 10_000
      assert entry["movements"]["received_cents"] == 5_000
      assert entry["closing_held_cents"] == 15_000
    end

    test "omits a property only when every balance and movement is zero" do
      apply_batch!(build_conn(), [
        # lon-eye opens but never receives cash.
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "property_id" => "lon-eye"
        }),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op()
      ])

      report = get_daily_report!(build_conn(), "2026-11-05")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]
    end

    test "closing totals reconcile to the current ledger view" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "property_id" => "lon-eye"
        }),
        start_finance_reporting_op(),
        transfer_deposit_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 9_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      closing = Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"]))

      assert closing == get_ledger!(build_conn())["cash_held_cents"]
    end

    test "orders cash entries by property id" do
      apply_batch!(build_conn(), [
        open_group_op(%{"property_id" => "lon-eye"}),
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "property_id" => "ams-canal"
        }),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "group_id" => "group-82",
          "amount_cents" => 5_000
        }),
        start_finance_reporting_op()
      ])

      report = get_daily_report!(build_conn(), "2026-11-05")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "lon-eye"]
    end
  end

  describe "settlements" do
    test "refundable cash settlement reports a refund" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        start_finance_reporting_op(),
        cancel_group_op(%{"occurred_on" => "2026-11-06"})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 19_500
      assert entry["movements"]["refunded_cents"] == 19_500
      assert entry["closing_held_cents"] == 0
    end

    test "non-refundable settlement reports retained cash and consumed credit" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-1002", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        # The applied credit is consumed by the non-refundable cancellation
        # of group-82, which is advance purchase settled late.
        start_finance_reporting_op()
      ])

      apply_batch!(build_conn(), [
        record_cash_payment_op(%{
          "operation_id" => "op-2002",
          "group_id" => "group-82",
          "amount_cents" => 10_500,
          "occurred_on" => "2026-12-01"
        }),
        cancel_group_op(%{
          "operation_id" => "op-4002",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-01"
        })
      ])

      report = get_daily_report!(build_conn(), "2026-12-01")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 10_500
      assert entry["movements"]["retained_cents"] == 10_500
      assert entry["closing_held_cents"] == 0

      credit = report["credit"]
      assert credit["opening_liability_cents"] == 21_450
      assert credit["movements"]["consumed_cents"] == 9_000
      assert credit["closing_liability_cents"] == 12_450
    end

    test "hotel-credit settlement reports converted cash and issued credit" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        start_finance_reporting_op(),
        cancel_group_op(%{"refund_method" => "hotel_credit", "occurred_on" => "2026-11-06"})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["movements"]["converted_to_credit_cents"] == 19_500
      assert entry["closing_held_cents"] == 0

      # 110% of 19_500 = 21_450.
      assert report["credit"]["movements"]["issued_cents"] == 21_450
      assert report["credit"]["closing_liability_cents"] == 21_450
    end
  end

  describe "credit lifecycle" do
    test "unused credit expires on its expires_on day without an operation" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        start_finance_reporting_op(),
        cancel_group_op(%{"refund_method" => "hotel_credit"})
      ])

      # Issued on 2026-11-01 with a 366-day expiry on 2027-11-02.
      report = get_daily_report!(build_conn(), "2027-11-02")
      assert report["credit"]["movements"]["expired_cents"] == 21_450
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "applying credit records no movement" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-1002", "group_id" => "group-82"}),
        start_finance_reporting_op(),
        apply_hotel_credit_op(%{"amount_cents" => 9_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-10")
      assert Enum.all?(Map.values(report["credit"]["movements"]), &(&1 == 0))
      assert report["credit"]["closing_liability_cents"] == 21_450
    end

    test "restoring credit records no movement" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-1002", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        start_finance_reporting_op(),
        cancel_group_op(%{
          "operation_id" => "op-4002",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-20"
        })
      ])

      report = get_daily_report!(build_conn(), "2026-11-20")
      assert Enum.all?(Map.values(report["credit"]["movements"]), &(&1 == 0))
      assert report["credit"]["closing_liability_cents"] == 21_450
    end

    test "restored credit past its expiry expires immediately" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        # A group arriving far in the future stays refundable past the lot's
        # expiry on 2027-11-02.
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "arrival_on" => "2028-12-10",
          "departure_on" => "2028-12-13"
        }),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        start_finance_reporting_op()
      ])

      apply_batch!(build_conn(), [
        cancel_group_op(%{
          "operation_id" => "op-4002",
          "group_id" => "group-82",
          "occurred_on" => "2027-12-01"
        })
      ])

      report = get_daily_report!(build_conn(), "2027-12-01")

      # The 12_450 unused remainder expired on 2027-11-02 without an
      # operation, so the 12-01 report already opens with it gone.
      assert report["credit"]["opening_liability_cents"] == 9_000
      assert report["credit"]["movements"]["expired_cents"] == 9_000
      assert report["credit"]["closing_liability_cents"] == 0
    end
  end

  describe "transfers" do
    test "reports transferred in and out, equal across properties" do
      apply_batch!(build_conn(), [
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "property_id" => "lon-eye"
        }),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        start_finance_reporting_op(),
        transfer_deposit_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      [ams, lon] = report["cash"]
      assert ams["property_id"] == "ams-canal"
      assert lon["property_id"] == "lon-eye"
      assert ams["movements"]["transferred_out_cents"] == 10_000
      assert lon["movements"]["transferred_in_cents"] == 10_000
      assert ams["closing_held_cents"] == 9_500
      assert lon["closing_held_cents"] == 10_000
    end

    test "transferred hotel credit does not move cash" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-1002", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        open_group_op(%{
          "operation_id" => "op-1003",
          "group_id" => "group-83",
          "property_id" => "lon-eye"
        }),
        start_finance_reporting_op()
      ])

      apply_batch!(build_conn(), [
        transfer_deposit_op(%{
          "occurred_on" => "2026-11-06",
          "source_group_id" => "group-82",
          "destination_group_id" => "group-83",
          "amount_cents" => 9_000
        })
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      assert report["cash"] == []
    end
  end

  describe "corrections" do
    test "a reduction reports on the property holding the cash" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op(),
        reduce_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 4_000})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["movements"]["reduced_cents"] == 4_000
      assert entry["closing_held_cents"] == 6_000
    end

    test "a chargeback of held cash reports on the holding properties" do
      apply_batch!(build_conn(), [
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "property_id" => "lon-eye"
        }),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        transfer_deposit_op(%{"amount_cents" => 7_000}),
        start_finance_reporting_op()
      ])

      apply_batch!(build_conn(), [charge_back_payment_op(%{"occurred_on" => "2026-11-06"})])

      report = get_daily_report!(build_conn(), "2026-11-06")
      [ams, lon] = report["cash"]
      assert ams["movements"]["charged_back_cents"] == 3_000
      assert lon["movements"]["charged_back_cents"] == 7_000
      assert report["cash"] |> Enum.map(& &1["closing_held_cents"]) == [0, 0]
    end

    test "a chargeback of settled cash follows the property where it settled" do
      apply_batch!(build_conn(), [
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-82",
          "property_id" => "lon-eye"
        }),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        transfer_deposit_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{
          "operation_id" => "op-4002",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-10"
        }),
        start_finance_reporting_op(),
        charge_back_payment_op(%{"occurred_on" => "2026-11-06"})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      # ams-canal has zero balances and movements, so it is omitted.
      [lon] = report["cash"]
      assert lon["property_id"] == "lon-eye"
      assert lon["movements"]["refunded_cents"] == -10_000
      assert lon["movements"]["charged_back_cents"] == 10_000
      assert lon["closing_held_cents"] == 0
    end

    test "revoking an entitlement reports revoked credit liability" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        start_finance_reporting_op(),
        charge_back_payment_op(%{"occurred_on" => "2026-11-06"})
      ])

      report = get_daily_report!(build_conn(), "2026-11-06")
      assert report["credit"]["opening_liability_cents"] == 21_450
      assert report["credit"]["movements"]["revoked_cents"] == 21_450
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "shortfall absorption absorbs returning credit" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-1002", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 9_000}),
        # The chargeback revokes 21_450 of entitlement from a lot with 12_450
        # remaining, leaving a 9_000 unrecovered clawback.
        charge_back_payment_op(),
        start_finance_reporting_op()
      ])

      apply_batch!(build_conn(), [
        cancel_group_op(%{
          "operation_id" => "op-4002",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-20"
        })
      ])

      report = get_daily_report!(build_conn(), "2026-11-20")
      assert report["credit"]["opening_liability_cents"] == 9_000
      assert report["credit"]["movements"]["absorbed_cents"] == 9_000
      assert report["credit"]["closing_liability_cents"] == 0
    end
  end

  describe "durability" do
    test "rejected operations leave no movement" do
      apply_batch!(build_conn(), [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op()
      ])

      [rejected] =
        post_batch!(build_conn(), [
          record_cash_payment_op(%{
            "operation_id" => "op-2009",
            "amount_cents" => 99_999,
            "occurred_on" => "2026-11-06"
          })
        ])

      assert rejected["status"] == "rejected"

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 10_000
      assert Enum.all?(Map.values(entry["movements"]), &(&1 == 0))
      assert entry["closing_held_cents"] == 10_000
    end

    test "a durable retry does not report a movement twice" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op()
      ])

      op = record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000})
      [original] = post_batch!(build_conn(), [op])
      assert post_batch!(build_conn(), [op]) == [original]

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 10_000
      assert entry["closing_held_cents"] == 10_000
    end

    test "a rejected later operation keeps earlier applied movements" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op()
      ])

      results =
        post_batch!(build_conn(), [
          record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000}),
          record_cash_payment_op(%{
            "operation_id" => "op-2009",
            "occurred_on" => "2026-11-06",
            "amount_cents" => 99_999
          })
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "rejected"]

      report = get_daily_report!(build_conn(), "2026-11-06")
      [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 10_000
    end

    test "reading a report never changes state" do
      apply_batch!(build_conn(), [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-11-06", "amount_cents" => 10_000})
      ])

      first = get_daily_report!(build_conn(), "2026-11-06")
      assert get_daily_report!(build_conn(), "2026-11-06") == first
    end
  end
end
