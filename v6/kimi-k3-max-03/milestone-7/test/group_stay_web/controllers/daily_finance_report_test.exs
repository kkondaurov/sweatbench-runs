defmodule GroupStayWeb.DailyFinanceReportTest do
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

  describe "start_finance_reporting operation" do
    test "first applied start returns exactly operation_id, status, and starts_on" do
      conn = post_batch([start_finance_reporting_op()])

      [result] = json_response(conn, 200)["results"]

      assert %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => "2026-12-01"
             } = result

      assert result |> Map.keys() |> Enum.sort() == ["operation_id", "starts_on", "status"]
    end

    test "rejects invalid or missing starts_on" do
      conn =
        post_batch([
          start_finance_reporting_op(%{"starts_on" => "not-a-date"}),
          start_finance_reporting_op(%{"operation_id" => "op-start-2", "starts_on" => nil})
        ])

      [r1, r2] = json_response(conn, 200)["results"]

      assert r1["code"] == "invalid_reporting_date"
      assert r2["code"] == "invalid_reporting_date"
    end

    test "a different start operation is rejected once reporting has started" do
      post_batch([start_finance_reporting_op()])

      conn =
        post_batch([
          start_finance_reporting_op(%{
            "operation_id" => "op-start-2",
            "starts_on" => "2027-01-01"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "reporting_already_started"}]} =
               json_response(conn, 200)
    end

    test "a retry of the original start replays its stored result" do
      post_batch([start_finance_reporting_op()])
      conn = post_batch([start_finance_reporting_op()])

      assert %{"results" => [%{"status" => "applied", "starts_on" => "2026-12-01"}]} =
               json_response(conn, 200)
    end

    test "reusing the start's identifier with a different payload is a conflict" do
      post_batch([start_finance_reporting_op()])
      conn = post_batch([start_finance_reporting_op(%{"starts_on" => "2026-12-02"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               json_response(conn, 200)
    end
  end

  describe "GET /api/v1/finance/daily-report access" do
    test "missing or invalid date is invalid_reporting_date" do
      conn = get(build_conn(), ~p"/api/v1/finance/daily-report")
      assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)

      conn = get(build_conn(), ~p"/api/v1/finance/daily-report?date=12-01-2026")
      assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)
    end

    test "before reporting has started the report is not available" do
      conn = daily_report("2026-12-01")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)
    end

    test "a date before starts_on is not available" do
      post_batch([start_finance_reporting_op()])

      conn = daily_report("2026-11-30")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)
    end

    test "the starts_on date itself is available" do
      post_batch([start_finance_reporting_op()])

      conn = daily_report("2026-12-01")
      assert %{"data" => %{"date" => "2026-12-01", "status" => "open"}} = json_response(conn, 200)
    end
  end

  describe "opening position and posting dates" do
    test "operations before the start contribute to the opening position" do
      post_batch([
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        start_finance_reporting_op()
      ])

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 10_000,
                   "closing_held_cents" => 10_000,
                   "movements" => movements
                 }
               ]
             } = report("2026-12-01")

      assert Enum.all?(movements, fn {_k, v} -> v == 0 end)
    end

    test "a pre-start operation whose occurred_on is after starts_on still folds into opening" do
      post_batch([
        open_group_op(),
        record_cash_payment_op(%{"occurred_on" => "2027-01-02", "amount_cents" => 7_000}),
        start_finance_reporting_op()
      ])

      assert %{
               "cash" => [
                 %{"opening_held_cents" => 7_000, "closing_held_cents" => 7_000}
               ]
             } = report("2026-12-01")
    end

    test "operations after the start post at the later of occurred_on and starts_on" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 8_000, "occurred_on" => "2026-11-20"})
      ])

      # occurred_on predates starts_on, so the movement posts on starts_on
      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{"received_cents" => 8_000},
                   "closing_held_cents" => 8_000
                 }
               ]
             } = report("2026-12-01")

      # once past that posting date the movement folds into the opening balance
      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 8_000,
                   "movements" => %{"received_cents" => 0},
                   "closing_held_cents" => 8_000
                 }
               ]
             } = report("2026-12-05")
    end

    test "split and combined batches produce equivalent reports" do
      operations = [
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 8_000})
      ]

      post_batch(operations)

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"received_cents" => 8_000},
                   "closing_held_cents" => 8_000
                 }
               ]
             } = report("2026-12-01")
    end
  end

  describe "cash movements" do
    test "refund on a refundable cancellation" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20"})
      ])

      # both the received and the refund post on starts_on here
      assert %{
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 10_000, "refunded_cents" => 10_000},
                   "opening_held_cents" => 0,
                   "closing_held_cents" => 0
                 }
               ]
             } = report("2026-12-01")
    end

    test "retention on a non-refundable cancellation" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-12-10"})
      ])

      assert %{
               "cash" => [
                 %{
                   "movements" => %{"retained_cents" => 10_000},
                   "closing_held_cents" => 0
                 }
               ]
             } = report("2026-12-10")
    end

    test "conversion to hotel credit issues liability" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      assert %{
               "cash" => [
                 %{"movements" => %{"converted_to_credit_cents" => 10_000}}
               ],
               "credit" => %{
                 "movements" => %{"issued_cents" => 11_000},
                 "opening_liability_cents" => 0,
                 "closing_liability_cents" => 11_000
               }
             } = report("2026-12-01")
    end

    test "rejections leave no movement and durable retries report once" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 30_000})
      ])

      # the second payment was rejected for exceeding the outstanding deposit;
      # its durable retry still reports nothing new
      post_batch([
        record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 30_000})
      ])

      assert %{"cash" => [%{"movements" => %{"received_cents" => 10_000}}]} =
               report("2026-12-01")
    end

    test "a rejected later operation in a batch leaves earlier movements intact" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        transfer_deposit_op(%{"destination_group_id" => "missing-group"})
      ])

      assert %{"cash" => [%{"movements" => %{"received_cents" => 10_000}}]} =
               report("2026-12-01")
    end
  end

  describe "transfers across properties" do
    test "transferred in and out balance per date across properties" do
      post_batch([
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "property_id" => "nyc-midtown"
        }),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        transfer_deposit_op(%{"amount_cents" => 4_000})
      ])

      assert %{"cash" => cash} = report("2026-12-01")

      ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
      nyc = Enum.find(cash, &(&1["property_id"] == "nyc-midtown"))

      assert ams["movements"]["transferred_out_cents"] == 4_000
      assert nyc["movements"]["transferred_in_cents"] == 4_000
      assert ams["closing_held_cents"] == 6_000
      assert nyc["closing_held_cents"] == 4_000

      total_in = Enum.sum(Enum.map(cash, & &1["movements"]["transferred_in_cents"]))
      total_out = Enum.sum(Enum.map(cash, & &1["movements"]["transferred_out_cents"]))
      assert total_in == total_out
    end

    test "a reduction follows cash to the property where it is held" do
      post_batch([
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "property_id" => "nyc-midtown"
        }),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        transfer_deposit_op(%{"amount_cents" => 4_000}),
        reduce_cash_payment_op(%{"amount_cents" => 3_000})
      ])

      assert %{"cash" => cash} = report("2026-12-01")

      ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
      nyc = Enum.find(cash, &(&1["property_id"] == "nyc-midtown"))

      # reduction draws from the most recent allocation first, so the cash
      # held at nyc (the transferred slice) is reduced there
      assert nyc["movements"]["reduced_cents"] == 3_000
      assert ams["movements"]["reduced_cents"] <= 0
    end
  end

  describe "chargebacks reverse dispositions" do
    test "reversing a refund reports a negative refund and a positive chargeback" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-05"}),
        charge_back_payment_op(%{
          "payment_operation_id" => "op-pay",
          "occurred_on" => "2026-11-06"
        })
      ])

      assert %{
               "cash" => [
                 %{
                   "movements" => %{
                     "refunded_cents" => -10_000,
                     "charged_back_cents" => 10_000
                   },
                   "opening_held_cents" => 0,
                   "closing_held_cents" => 0
                 }
               ]
             } = report("2026-11-06")
    end

    test "revoking converted credit reduces the liability through revoked" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-05", "refund_method" => "hotel_credit"}),
        charge_back_payment_op(%{
          "payment_operation_id" => "op-pay",
          "occurred_on" => "2026-11-06"
        })
      ])

      assert %{
               "cash" => [
                 %{
                   "movements" => %{
                     "converted_to_credit_cents" => -10_000,
                     "charged_back_cents" => 10_000
                   }
                 }
               ],
               "credit" => %{
                 "movements" => %{"revoked_cents" => 11_000},
                 "closing_liability_cents" => 0
               }
             } = report("2026-11-06")
    end
  end

  describe "credit movements" do
    test "unused credit expires on the day after expires_on with no operation" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        # converted lot issued on 2026-11-20 expires on 2027-11-20
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      assert %{
               "credit" => %{
                 "opening_liability_cents" => 11_000,
                 "movements" => %{"expired_cents" => 11_000},
                 "closing_liability_cents" => 0
               }
             } = report("2027-11-21")
    end

    test "non-refundable settlement consumes applied hotel credit" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        # refundable issue of hotel credit on 2026-11-20
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{
          "operation_id" => "op-apply",
          "group_id" => "group-82",
          "amount_cents" => 5_000
        }),
        # non-refundable cancellation of group-82 consuming the applied credit
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-05"
        })
      ])

      assert %{
               "credit" => %{
                 "opening_liability_cents" => 11_000,
                 "movements" => %{"consumed_cents" => 5_000},
                 "closing_liability_cents" => 6_000
               }
             } = report("2026-12-05")
    end

    test "a revocation posting after the lot's expiry goes back into the expiry pool" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        # issued lot expires on 2027-11-05
        cancel_group_op(%{"occurred_on" => "2026-11-05", "refund_method" => "hotel_credit"}),
        charge_back_payment_op(%{
          "payment_operation_id" => "op-pay",
          "occurred_on" => "2028-01-01"
        })
      ])

      assert %{
               "credit" => %{
                 "movements" => %{"expired_cents" => 11_000},
                 "closing_liability_cents" => 0
               }
             } = report("2027-11-06")

      # the late revocation never double-counts as a revoked movement
      assert %{
               "credit" => %{
                 "movements" => %{"revoked_cents" => 0},
                 "closing_liability_cents" => 0
               }
             } = report("2028-01-01")
    end

    test "refundable restoration into a claw-backed lot is absorbed" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(%{"starts_on" => "2026-11-01"}),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-05", "refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{
          "operation_id" => "op-apply",
          "group_id" => "group-82",
          "amount_cents" => 3_000,
          "occurred_on" => "2026-11-06"
        }),
        charge_back_payment_op(%{
          "payment_operation_id" => "op-pay",
          "occurred_on" => "2026-11-07"
        }),
        cancel_group_op(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-08"
        })
      ])

      # restored 3 000 credit first absorbs the lot's unrecovered clawback
      assert %{
               "credit" => %{
                 "movements" => %{"absorbed_cents" => 3_000},
                 "closing_liability_cents" => 0
               }
             } = report("2026-11-08")
    end
  end

  describe "reconciliation and reads" do
    test "closing balances reconcile with the ledger as-of view" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        cancel_group_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      date = "2026-12-01"
      report = report(date)
      ledger = json_response(get(build_conn(), ~p"/api/v1/ledger?on=#{date}"), 200)["data"]

      cash_total = Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"]))
      assert cash_total == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end

    test "reading a report repeatedly changes neither the report nor group state" do
      post_batch([
        open_group_op(),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      first = report("2026-12-01")
      second = report("2026-12-01")
      assert first == second

      report("2026-12-01")

      group = json_response(get(build_conn(), ~p"/api/v1/groups/group-81"), 200)["data"]
      assert group["revision"] == 2
    end
  end

  describe "property visibility" do
    test "a property with zero opening, zero closing, and zero movements is omitted" do
      post_batch([
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "property_id" => "nyc-midtown"
        }),
        start_finance_reporting_op()
      ])

      # no funding moved anywhere: all candidate entries are all-zero
      assert %{"cash" => []} = report("2026-12-01")
    end

    test "properties are ordered by property_id" do
      post_batch([
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-aaa",
          "property_id" => "aaa-first"
        }),
        open_group_op(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-zzz",
          "property_id" => "zzz-last"
        }),
        start_finance_reporting_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-aaa",
          "amount_cents" => 1_000
        }),
        record_cash_payment_op(%{
          "operation_id" => "op-pay-3",
          "group_id" => "group-zzz",
          "amount_cents" => 1_000
        })
      ])

      assert %{"cash" => cash} = report("2026-12-01")
      assert Enum.map(cash, & &1["property_id"]) == ["aaa-first", "ams-canal", "zzz-last"]
    end
  end
end
