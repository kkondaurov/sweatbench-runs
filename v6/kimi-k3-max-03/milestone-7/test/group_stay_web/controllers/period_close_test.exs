defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp daily_report(date) do
    get(build_conn(), ~p"/api/v1/finance/daily-report?date=#{date}")
  end

  defp report(date), do: json_response(daily_report(date), 200)["data"]

  defp zero_credit_adjustments? do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  describe "close_finance_period operation" do
    test "first applied close returns exactly operation_id, status, and period_end_on" do
      conn =
        post_batch([
          start_finance_reporting_op(),
          close_finance_period_op()
        ])

      [_, result] = json_response(conn, 200)["results"]

      assert %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-12-10"
             } = result

      assert result |> Map.keys() |> Enum.sort() == ["operation_id", "period_end_on", "status"]
    end

    test "closing before reporting has started is invalid_period" do
      conn = post_batch([close_finance_period_op()])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)
    end

    test "a cutoff before starts_on is invalid_period" do
      conn =
        post_batch([
          start_finance_reporting_op(),
          close_finance_period_op(%{"period_end_on" => "2026-11-30"})
        ])

      assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)
    end

    test "an invalid or missing period_end_on is invalid_period" do
      post_batch([start_finance_reporting_op()])

      conn =
        post_batch([
          close_finance_period_op(%{"period_end_on" => "not-a-date"}),
          close_finance_period_op(%{"operation_id" => "op-close-2", "period_end_on" => nil})
        ])

      [r1, r2] = json_response(conn, 200)["results"]

      assert r1["code"] == "invalid_period"
      assert r2["code"] == "invalid_period"
    end

    test "a cutoff must move strictly past the latest successful close" do
      post_batch([
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      # the same cutoff again and an earlier one are both rejected
      conn =
        post_batch([
          close_finance_period_op(%{
            "operation_id" => "op-close-2",
            "period_end_on" => "2026-12-10"
          }),
          close_finance_period_op(%{
            "operation_id" => "op-close-3",
            "period_end_on" => "2026-12-05"
          })
        ])

      [r1, r2] = json_response(conn, 200)["results"]

      assert r1["code"] == "invalid_period"
      assert r2["code"] == "invalid_period"

      # a strictly later cutoff still applies
      conn =
        post_batch([
          close_finance_period_op(%{
            "operation_id" => "op-close-4",
            "period_end_on" => "2026-12-15"
          })
        ])

      assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-12-15"}]} =
               json_response(conn, 200)
    end

    test "a retry of an applied close replays its exact stored result" do
      post_batch([
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      conn = post_batch([close_finance_period_op()])

      assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-12-10"}]} =
               json_response(conn, 200)
    end

    test "a retry of a rejected close replays the original rejection" do
      post_batch([
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      rejected =
        close_finance_period_op(%{
          "operation_id" => "op-close-2",
          "period_end_on" => "2026-12-05"
        })

      post_batch([rejected])
      conn = post_batch([rejected])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)
    end

    test "reusing the close identifier with a different payload is a conflict" do
      post_batch([
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      conn = post_batch([close_finance_period_op(%{"period_end_on" => "2026-12-11"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)
    end

    test "the close ignores any revision guard" do
      conn =
        post_batch([
          start_finance_reporting_op(),
          close_finance_period_op(%{
            "expected_revision" => 7,
            "destination_expected_revision" => 3
          })
        ])

      assert %{"results" => [_, %{"status" => "applied", "period_end_on" => "2026-12-10"}]} =
               json_response(conn, 200)
    end
  end

  describe "report status by period" do
    test "reports on and before the cutoff are closed; later reports are open" do
      post_batch([
        start_finance_reporting_op(),
        close_finance_period_op()
      ])

      assert report("2026-12-10")["status"] == "closed"
      assert report("2026-12-11")["status"] == "open"
    end

    test "an empty successful report still carries late_adjustments" do
      post_batch([start_finance_reporting_op()])

      report = report("2026-12-01")

      assert %{
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => adjustments
               }
             } = report

      assert zero_credit_adjustments?() == adjustments
    end
  end

  describe "posting after a close" do
    test "an operation in the open period posts its ordinary date" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        close_finance_period_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-12-11", "amount_cents" => 10_000})
      ])

      report = report("2026-12-11")

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"received_cents" => 10_000},
                   "closing_held_cents" => 10_000
                 }
               ],
               "late_adjustments" => %{"cash" => []}
             } = report
    end

    test "an old-dated operation posts on the first open day as a late adjustment" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        close_finance_period_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-12-05", "amount_cents" => 7_000})
      ])

      report = report("2026-12-11")

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"received_cents" => 0},
                   "closing_held_cents" => 7_000
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"received_cents" => 7_000}
                   }
                 ]
               }
             } = report
    end

    test "same-batch operations before the close post into the closing period" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-12-05", "amount_cents" => 10_000}),
        close_finance_period_op(),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-12-08",
          "amount_cents" => 3_000
        })
      ])

      # the payment before the close posted into the period being closed
      earlier = report("2026-12-05")

      assert %{
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 10_000},
                   "closing_held_cents" => 10_000
                 }
               ],
               "late_adjustments" => %{"cash" => []}
             } = earlier

      # the old-dated payment after the close posts on the first open day
      later = report("2026-12-11")

      assert %{
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 0},
                   "opening_held_cents" => 10_000,
                   "closing_held_cents" => 13_000
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"received_cents" => 3_000}
                   }
                 ]
               }
             } = later
    end
  end

  describe "late adjustment classifications" do
    test "each classification keeps its sign even when the net balance effect is zero" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"occurred_on" => "2026-11-05", "amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-05"}),
        close_finance_period_op(%{"period_end_on" => "2026-11-05"}),
        charge_back_payment_op(%{"occurred_on" => "2026-11-05"})
      ])

      report = report("2026-11-06")

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"refunded_cents" => 0, "charged_back_cents" => 0},
                   "closing_held_cents" => 0
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{
                       "refunded_cents" => -10_000,
                       "charged_back_cents" => 10_000
                     }
                   }
                 ]
               }
             } = report
    end

    test "credit movements moved by a close appear in the credit late block" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"occurred_on" => "2026-11-05", "amount_cents" => 10_000}),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        }),
        cancel_group_op(%{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        apply_hotel_credit_op(%{
          "operation_id" => "op-apply",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        }),
        close_finance_period_op(%{"period_end_on" => "2026-11-06"}),
        # non-refundable settlement consumes the applied credit on a moved posting date
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06"
        })
      ])

      report = report("2026-11-07")

      assert %{
               "credit" => %{
                 "movements" => %{"consumed_cents" => 0},
                 "closing_liability_cents" => 6_000
               },
               "late_adjustments" => %{
                 "credit" => %{"consumed_cents" => 5_000}
               }
             } = report
    end

    test "late cash rows are ordered by property and omit all-zero properties" do
      post_batch([
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-z1",
          "property_id" => "zzz-first"
        }),
        start_finance_reporting_op(),
        close_finance_period_op(),
        # only the second property receives a late movement
        record_cash_payment_op(%{
          "operation_id" => "op-pay-late",
          "group_id" => "group-z1",
          "occurred_on" => "2026-12-05",
          "amount_cents" => 4_000
        })
      ])

      report = report("2026-12-11")

      assert %{
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "zzz-first",
                     "movements" => %{"received_cents" => 4_000}
                   }
                 ]
               }
             } = report
    end
  end

  describe "closed reports stay stable" do
    test "a closed cash report is byte-for-byte stable across later operations and closes" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-12-05", "amount_cents" => 10_000}),
        close_finance_period_op()
      ])

      closed = report("2026-12-05")
      assert closed["status"] == "closed"

      # later operations, including a late adjustment and another close
      post_batch([
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-12-05",
          "amount_cents" => 3_000
        }),
        close_finance_period_op(%{
          "operation_id" => "op-close-2",
          "period_end_on" => "2026-12-20"
        })
      ])

      assert report("2026-12-05") == closed
    end

    test "derived credit expiry is frozen by the close: later credit operations cannot move it" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"occurred_on" => "2026-11-05", "amount_cents" => 10_000}),
        # lot of 11_000 issued, expiring on 2027-11-05
        cancel_group_op(%{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        close_finance_period_op(%{"period_end_on" => "2027-12-01"})
      ])

      closed = report("2027-11-06")

      # spend some of the lot on a posting moved forward by the close; the
      # published expiry day still shows the frozen amount
      post_batch([
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06"
        }),
        apply_hotel_credit_op(%{
          "operation_id" => "op-apply",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        })
      ])

      assert report("2027-11-06") == closed

      # and a chargeback reversal posting past the lot's expiry also leaves it
      post_batch([
        charge_back_payment_op(%{"occurred_on" => "2027-12-02"})
      ])

      assert report("2027-11-06") == closed
    end

    test "a refundable restoration after the close cannot move the frozen expiry either" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"occurred_on" => "2026-11-05", "amount_cents" => 10_000}),
        cancel_group_op(%{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06"
        }),
        apply_hotel_credit_op(%{
          "operation_id" => "op-apply",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        }),
        # cover the lot's derived expiry day (2027-11-06) at a remaining of 6_000
        close_finance_period_op(%{"period_end_on" => "2027-12-01"})
      ])

      closed = report("2027-11-06")

      post_batch([
        # refund the applied credit back into the lot with a moved posting date
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-06"
        })
      ])

      assert report("2027-11-06") == closed
    end

    test "operations after the close see earlier late adjustments when a later close covers them" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        close_finance_period_op(),
        record_cash_payment_op(%{"occurred_on" => "2026-12-05", "amount_cents" => 4_000}),
        close_finance_period_op(%{
          "operation_id" => "op-close-2",
          "period_end_on" => "2026-12-15"
        })
      ])

      # the first open day was 2026-12-11; the second close now covers it
      report = report("2026-12-11")

      assert %{
               "status" => "closed",
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 0},
                   "closing_held_cents" => 4_000
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"received_cents" => 4_000}
                   }
                 ]
               }
             } = report
    end
  end
end
