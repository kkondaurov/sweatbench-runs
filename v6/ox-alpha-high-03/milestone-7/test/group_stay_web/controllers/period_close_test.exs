defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  @empty_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @empty_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  describe "close_finance_period operation" do
    test "applies with exactly the documented result fields" do
      run_and_get_results([start_reporting_operation("2030-02-01")])

      results = run_and_get_results([close_period_operation("2030-02-05")])

      assert hd(results) == %{
               "operation_id" => "op-close-period",
               "status" => "applied",
               "period_end_on" => "2030-02-05"
             }
    end

    test "rejects invalid_period while reporting has not started" do
      results = run_and_get_results([close_period_operation("2030-02-05")])

      assert hd(results) == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "rejects a missing or malformed period_end_on as invalid_period" do
      run_and_get_results([start_reporting_operation("2030-02-01")])

      invalid_values = [nil, "", "2030-13-01", "not-a-date", 2_030_020_5]

      for {period_end_on, index} <- Enum.with_index(invalid_values) do
        operation =
          close_period_operation("2030-02-05", %{"operation_id" => "op-close-bad-#{index}"})
          |> Map.merge(%{"period_end_on" => period_end_on})
          |> then(fn op ->
            if is_nil(period_end_on), do: Map.delete(op, "period_end_on"), else: op
          end)

        results = run_and_get_results([operation])

        assert hd(results) == %{
                 "operation_id" => "op-close-bad-#{index}",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
      end
    end

    test "rejects a cutoff before starts_on and accepts the start date itself" do
      run_and_get_results([start_reporting_operation("2030-02-01")])

      results =
        run_and_get_results([
          close_period_operation("2030-01-31", %{"operation_id" => "op-close-before-start"})
        ])

      assert hd(results)["code"] == "invalid_period"

      results = run_and_get_results([close_period_operation("2030-02-01")])

      assert hd(results) == %{
               "operation_id" => "op-close-period",
               "status" => "applied",
               "period_end_on" => "2030-02-01"
             }
    end

    test "a later close must be strictly after the latest successful close" do
      run_and_get_results([start_reporting_operation("2030-02-01")])
      run_and_get_results([close_period_operation("2030-02-10")])

      equal_results =
        run_and_get_results([
          close_period_operation("2030-02-10", %{"operation_id" => "op-close-equal"})
        ])

      assert hd(equal_results)["code"] == "invalid_period"

      earlier_results =
        run_and_get_results([
          close_period_operation("2030-02-04", %{"operation_id" => "op-close-earlier"})
        ])

      assert hd(earlier_results)["code"] == "invalid_period"

      later_results =
        run_and_get_results([
          close_period_operation("2030-02-11", %{"operation_id" => "op-close-later"})
        ])

      assert hd(later_results)["status"] == "applied"
    end

    test "replaying an applied close returns its exact stored result" do
      run_and_get_results([start_reporting_operation("2030-02-01")])

      first = run_and_get_results([close_period_operation("2030-02-05")])
      replay = run_and_get_results([close_period_operation("2030-02-05")])

      assert replay == first
      assert hd(replay)["status"] == "applied"
    end

    test "the same identifier with a different cutoff conflicts and keeps the original" do
      run_and_get_results([start_reporting_operation("2030-02-01")])
      first = run_and_get_results([close_period_operation("2030-02-05")])

      results = run_and_get_results([close_period_operation("2030-02-09")])

      assert hd(results) == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      replay = run_and_get_results([close_period_operation("2030-02-05")])
      assert replay == first
    end

    test "a rejected close is durable and replays its rejection" do
      run_and_get_results([start_reporting_operation("2030-02-01")])
      run_and_get_results([close_period_operation("2030-02-05")])

      operation = close_period_operation("2030-02-05", %{"operation_id" => "op-close-other"})

      first = run_and_get_results([operation])
      assert hd(first)["code"] == "invalid_period"

      replay = run_and_get_results([operation])
      assert replay == first
    end
  end

  describe "publishing reports through the cutoff" do
    test "reports through period_end_on become closed and stay stable" do
      open_default_group("group-pub")
      run_and_get_results([start_reporting_operation("2030-03-01")])

      run_and_get_results([
        pay_operation("group-pub", 5_000, %{"occurred_on" => "2030-03-02"})
      ])

      run_and_get_results([close_period_operation("2030-03-05")])

      for date <- ["2030-03-01", "2030-03-02", "2030-03-05"] do
        assert %{"status" => "closed"} = fetch_daily_report(date)
      end

      assert %{"status" => "open"} = fetch_daily_report("2030-03-06")

      # Later operations and a further close never rewrite published data.
      published_bodies =
        ["2030-03-01", "2030-03-02", "2030-03-05"] |> Map.new(&{&1, fetch_report_body(&1)})

      run_and_get_results([
        pay_operation("group-pub", 2_000, %{
          "operation_id" => "op-pay-late",
          "occurred_on" => "2030-03-03"
        }),
        close_period_operation("2030-03-08", %{"operation_id" => "op-close-two"}),
        pay_operation("group-pub", 1_000, %{
          "operation_id" => "op-pay-open",
          "occurred_on" => "2030-03-10"
        })
      ])

      for date <- ["2030-03-01", "2030-03-02", "2030-03-05"] do
        assert fetch_report_body(date) == Map.fetch!(published_bodies, date)
      end
    end

    test "an old-dated payment after a close posts on the first open day as a late adjustment" do
      open_default_group("group-late")
      run_and_get_results([start_reporting_operation("2030-04-01")])

      run_and_get_results([
        pay_operation("group-late", 3_000, %{"occurred_on" => "2030-04-02"})
      ])

      # An operation immediately before a close still posts into the period
      # being closed; the cutoff applies only once the close commits.
      results =
        run_and_get_results([
          pay_operation("group-late", 2_000, %{
            "operation_id" => "op-pay-pre-close",
            "occurred_on" => "2030-04-04"
          }),
          close_period_operation("2030-04-05")
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]

      # The old-dated payment after that close lands on the first open day.
      results =
        run_and_get_results([
          pay_operation("group-late", 1_500, %{
            "operation_id" => "op-pay-moved",
            "occurred_on" => "2030-04-03"
          })
        ])

      assert hd(results)["status"] == "applied"

      # The pre-close payment is visible in the closed day's published report.
      pre_close = fetch_daily_report("2030-04-04")
      assert %{"status" => "closed"} = pre_close
      assert [entry] = pre_close["cash"]
      assert entry["movements"]["received_cents"] == 2_000

      # The old-dated payment posts complete on the first open day.
      first_open = fetch_daily_report("2030-04-06")
      assert %{"status" => "open"} = first_open
      assert [entry] = first_open["cash"]
      assert entry["opening_held_cents"] == 5_000
      assert entry["movements"] == @empty_cash_movements
      assert entry["closing_held_cents"] == 6_500

      assert first_open["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{@empty_cash_movements | "received_cents" => 1_500}
                 }
               ],
               "credit" => @empty_credit_movements
             }

      # An operation whose occurred_on is already in the open period keeps it.
      run_and_get_results([
        pay_operation("group-late", 4_000, %{
          "operation_id" => "op-pay-open-day",
          "occurred_on" => "2030-04-07"
        })
      ])

      open_day = fetch_daily_report("2030-04-07")
      assert [entry] = open_day["cash"]
      assert entry["movements"]["received_cents"] == 4_000
      assert entry["closing_held_cents"] == 10_500
      assert open_day["late_adjustments"]["cash"] == []
    end

    test "a later close never moves an already-committed posting date" do
      open_default_group("group-fixed")
      run_and_get_results([start_reporting_operation("2030-06-01")])
      run_and_get_results([close_period_operation("2030-06-02")])

      run_and_get_results([
        pay_operation("group-fixed", 4_000, %{"occurred_on" => "2030-06-01"})
      ])

      before = fetch_daily_report("2030-06-03")
      assert %{"status" => "open"} = before
      assert hd(before["late_adjustments"]["cash"])["movements"]["received_cents"] == 4_000

      run_and_get_results([
        close_period_operation("2030-06-10", %{"operation_id" => "op-close-wide"})
      ])

      after_close = fetch_daily_report("2030-06-03")

      assert %{"status" => "closed"} = after_close
      assert %{after_close | "status" => "open"} == before
    end

    test "late adjustments keep signed classifications with a zero net effect" do
      open_operation(%{
        "operation_id" => "op-open-signed",
        "group_id" => "group-signed",
        "guest_id" => "guest-signed",
        "property_id" => "ams-canal",
        "occurred_on" => "2030-05-01",
        "arrival_on" => "2030-07-10",
        "departure_on" => "2030-07-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-signed", 9_000, %{"occurred_on" => "2030-05-02"})
      ])

      run_and_get_results([
        start_reporting_operation("2030-05-01"),
        cancel_operation("group-signed", %{"occurred_on" => "2030-05-03"}),
        close_period_operation("2030-05-04")
      ])

      # Charging back the previously refunded payment is old-dated, so its
      # finance effect moves onto the first open day with both signed
      # classifications intact despite the zero net balance effect.
      run_and_get_results([
        charge_back_operation("op-pay", %{"occurred_on" => "2030-05-03"})
      ])

      report = fetch_daily_report("2030-05-05")

      assert %{"status" => "open"} = report

      assert report["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" =>
                     Map.merge(@empty_cash_movements, %{
                       "refunded_cents" => -9_000,
                       "charged_back_cents" => 9_000
                     })
                 }
               ],
               "credit" => @empty_credit_movements
             }

      # Ordinary columns stay empty; balances use ordinary plus late values.
      assert [entry] = report["cash"]
      assert entry["opening_held_cents"] == 0
      assert entry["movements"] == @empty_cash_movements
      assert entry["closing_held_cents"] == 0
    end

    test "an open day chains its opening liability from the last closed day" do
      issue_credit_for_guest("guest-chain")

      run_and_get_results([start_reporting_operation("2031-11-20")])
      run_and_get_results([close_period_operation("2031-11-30")])

      # The lot's expiry falls inside the closed period and is frozen there.
      expired = fetch_daily_report("2031-11-23")
      assert %{"status" => "closed"} = expired
      assert expired["credit"]["movements"]["expired_cents"] == 9_900
      assert expired["credit"]["closing_liability_cents"] == 0

      # A later chargeback retroactively drains the already-expired lot. The
      # published days stay put and the next open day chains from the last
      # closed closing instead of resurrecting the drained liability.
      run_and_get_results([
        charge_back_operation("op-pay-seed-guest-chain", %{"occurred_on" => "2031-12-01"})
      ])

      open_day = fetch_daily_report("2031-12-01")
      assert open_day["credit"]["opening_liability_cents"] == 0
      assert open_day["credit"]["movements"]["revoked_cents"] == 9_900
    end

    test "current-state views keep their meanings after a close" do
      open_default_group("group-current")
      run_and_get_results([start_reporting_operation("2030-07-01")])
      run_and_get_results([close_period_operation("2030-07-05")])

      results =
        run_and_get_results([
          pay_operation("group-current", 12_000, %{"occurred_on" => "2030-06-20"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-current",
               "amount_cents" => 12_000,
               "outstanding_deposit_cents" => 7_500,
               "revision" => 2
             }

      group = fetch_group("group-current")
      assert group["deposit_paid_cents"] == 12_000

      ledger = fetch_ledger()
      assert ledger["cash_held_cents"] == 12_000
    end
  end

  defp fetch_report_body(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> Map.fetch!(:resp_body)
  end

  # Cancels a refundable flexible group funded with 9_000 cents using hotel
  # credit, issuing a 9_900 cent lot for `guest_id` expiring 2031-11-22.
  defp issue_credit_for_guest(guest_id) do
    open_operation(%{
      "operation_id" => "op-open-seed-#{guest_id}",
      "group_id" => "group-seed-#{guest_id}",
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "occurred_on" => "2030-11-20",
      "arrival_on" => "2031-02-10",
      "departure_on" => "2031-02-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    })
    |> List.wrap()
    |> post_operations()

    run_and_get_results([
      pay_operation("group-seed-#{guest_id}", 9_000, %{
        "operation_id" => "op-pay-seed-#{guest_id}",
        "occurred_on" => "2030-11-21"
      }),
      cancel_operation("group-seed-#{guest_id}", %{
        "operation_id" => "op-cancel-seed-#{guest_id}",
        "occurred_on" => "2030-11-22",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp run_and_get_results(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end
end
