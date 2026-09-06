defmodule GroupStayWeb.DailyFinanceReportTest do
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

  describe "start_finance_reporting operation" do
    test "applies with exactly the documented result fields" do
      results = run_and_get_results([start_reporting_operation("2030-01-01")])

      assert hd(results) == %{
               "operation_id" => "op-start-reporting",
               "status" => "applied",
               "starts_on" => "2030-01-01"
             }
    end

    test "rejects a missing or invalid starts_on as invalid_reporting_date" do
      invalid_values = [nil, "", "2030-13-01", "not-a-date", 20_300_010_1]

      for {starts_on, index} <- Enum.with_index(invalid_values) do
        operation =
          start_reporting_operation("2030-01-01", %{"operation_id" => "op-start-bad-#{index}"})
          |> Map.merge(%{"starts_on" => starts_on})
          |> then(fn op -> if is_nil(starts_on), do: Map.delete(op, "starts_on"), else: op end)

        results = run_and_get_results([operation])

        assert hd(results) == %{
                 "operation_id" => "op-start-bad-#{index}",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
      end
    end

    test "rejects a different start operation once reporting has started" do
      run_and_get_results([start_reporting_operation("2030-01-01")])

      results =
        run_and_get_results([
          start_reporting_operation("2030-02-01", %{"operation_id" => "op-start-again"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-start-again",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
    end

    test "a retry of the original start operation replays the stored result" do
      first = run_and_get_results([start_reporting_operation("2030-01-01")])

      replay =
        run_and_get_results([
          start_reporting_operation("2030-01-01", %{"occurred_on" => "ignored"})
          |> Map.delete("occurred_on")
        ])

      assert replay == first
      assert hd(replay)["status"] == "applied"
    end

    test "the start operation does not address a group and creates no revision change" do
      open_default_group("group-rev")

      results =
        run_and_get_results([start_reporting_operation("2030-01-01")])

      assert hd(results)["group_id"] |> is_nil()

      group = fetch_group("group-rev")
      assert group["revision"] == 1
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "returns 422 invalid_reporting_date for a missing or invalid date" do
      assert fetch_daily_report_error(nil) == "invalid_reporting_date"
      assert fetch_daily_report_error("2030-13-01") == "invalid_reporting_date"
      assert fetch_daily_report_error("garbage") == "invalid_reporting_date"
    end

    test "returns 404 report_not_available before reporting has started" do
      assert report_not_available?("2030-01-01")
    end

    test "returns 404 report_not_available for dates before starts_on" do
      run_and_get_results([start_reporting_operation("2030-01-10")])

      assert report_not_available?("2030-01-09")
      refute report_not_available?("2030-01-10")
    end

    defp report_not_available?(date) do
      conn =
        build_conn()
        |> get("/api/v1/finance/daily-report?date=#{date}")

      case conn.status do
        404 ->
          with %{"error" => %{"code" => "report_not_available"}} <- json_response(conn, 404) do
            true
          end

        _other ->
          false
      end
    end
  end

  describe "daily report contents" do
    test "captures committed state as the opening position and reports later movements" do
      open_default_group("group-open-a")

      run_and_get_results([
        pay_operation("group-open-a", 10_000, %{"operation_id" => "op-pay-before"})
      ])

      open_operation(%{
        "operation_id" => "op-open-b",
        "group_id" => "group-open-b",
        "property_id" => "rtx-plaza",
        "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-open-b", 3_000, %{"operation_id" => "op-pay-b"})
      ])

      run_and_get_results([start_reporting_operation("2030-06-01")])

      run_and_get_results([
        pay_operation("group-open-a", 5_000, %{
          "operation_id" => "op-pay-after",
          "occurred_on" => "2030-06-03"
        })
      ])

      report = fetch_daily_report("2030-06-03")

      assert %{
               "date" => "2030-06-03",
               "status" => "open",
               "cash" => cash,
               "credit" => credit
             } = report

      # Ordered by property_id; the untouched property still appears because
      # its opening balance is non-zero.
      assert Enum.map(cash, & &1["property_id"]) == ["ams-canal", "rtx-plaza"]

      assert hd(cash) == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => %{@empty_cash_movements | "received_cents" => 5_000},
               "closing_held_cents" => 15_000
             }

      assert Enum.at(cash, 1) == %{
               "property_id" => "rtx-plaza",
               "opening_held_cents" => 3_000,
               "movements" => @empty_cash_movements,
               "closing_held_cents" => 3_000
             }

      assert credit == %{
               "opening_liability_cents" => 0,
               "movements" => @empty_credit_movements,
               "closing_liability_cents" => 0
             }
    end

    test "operations before the start in one batch feed the opening, later ones movements" do
      open_default_group("group-batch")

      results =
        run_and_get_results([
          pay_operation("group-batch", 8_000, %{
            "operation_id" => "op-pay-pre",
            "occurred_on" => "2030-06-30"
          }),
          start_reporting_operation("2030-07-05", %{"operation_id" => "op-start-mid"}),
          pay_operation("group-batch", 4_000, %{
            "operation_id" => "op-pay-post",
            "occurred_on" => "2030-07-03"
          })
        ])

      assert hd(results)["status"] == "applied"

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-start-mid",
               "status" => "applied",
               "starts_on" => "2030-07-05"
             }

      # The payment submitted before the start contributes to the opening
      # position even though its occurred_on precedes starts_on.
      report = fetch_daily_report("2030-07-05")
      assert [entry] = report["cash"]
      assert entry["opening_held_cents"] == 8_000

      # The later payment posts on max(its occurred_on, starts_on).
      assert entry["movements"]["received_cents"] == 4_000
      assert entry["closing_held_cents"] == 12_000

      # No movements on any other day.
      assert %{"cash" => [only]} = fetch_daily_report("2030-07-06")
      assert only["opening_held_cents"] == 12_000
      assert only["movements"] == @empty_cash_movements
    end

    test "an operation committed before the start never appears as a movement" do
      open_default_group("group-committed")

      run_and_get_results([
        pay_operation("group-committed", 6_000, %{
          "operation_id" => "op-pay-early",
          "occurred_on" => "2030-08-20"
        })
      ])

      run_and_get_results([start_reporting_operation("2030-08-01")])

      report = fetch_daily_report("2030-08-20")
      assert [entry] = report["cash"]
      assert entry["opening_held_cents"] == 6_000
      assert entry["movements"] == @empty_cash_movements
      assert entry["closing_held_cents"] == 6_000
    end

    test "refunds and retentions settle at the group's property with the balance identity" do
      # Flexible group booked on/after 2027-01-01 uses the 30-day window.
      open_operation(%{
        "operation_id" => "op-open-refundable",
        "group_id" => "group-refundable",
        "guest_id" => "guest-refund",
        "property_id" => "ams-canal",
        "occurred_on" => "2030-01-02",
        "arrival_on" => "2030-03-10",
        "departure_on" => "2030-03-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-refundable", 9_000, %{
          "operation_id" => "op-pay-refundable",
          "occurred_on" => "2030-01-03"
        })
      ])

      run_and_get_results([start_reporting_operation("2030-01-04")])

      run_and_get_results([
        cancel_operation("group-refundable", %{
          "operation_id" => "op-cancel-refundable",
          "occurred_on" => "2030-01-05"
        })
      ])

      report = fetch_daily_report("2030-01-05")
      assert [entry] = report["cash"]
      assert entry["opening_held_cents"] == 9_000
      assert entry["movements"]["refunded_cents"] == 9_000
      assert entry["closing_held_cents"] == 0

      # A non-refundable cancellation retains instead.
      open_operation(%{
        "operation_id" => "op-open-late",
        "group_id" => "group-late",
        "guest_id" => "guest-refund",
        "property_id" => "rtx-plaza",
        "occurred_on" => "2030-01-02",
        "arrival_on" => "2030-01-10",
        "departure_on" => "2030-01-12",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 10_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-late", 5_000, %{
          "operation_id" => "op-pay-late",
          "occurred_on" => "2030-01-04"
        })
      ])

      run_and_get_results([
        cancel_operation("group-late", %{
          "operation_id" => "op-cancel-late",
          "occurred_on" => "2030-01-06"
        })
      ])

      report = fetch_daily_report("2030-01-06")
      by_property = Map.new(report["cash"], &{&1["property_id"], &1})

      rtx = by_property["rtx-plaza"]
      assert rtx["opening_held_cents"] == 5_000
      assert rtx["movements"]["retained_cents"] == 5_000
      assert rtx["closing_held_cents"] == 0
    end

    test "transfers report equal out/in amounts on the two groups' properties" do
      open_default_group("group-tr-src")

      open_operation(%{
        "operation_id" => "op-open-dst",
        "group_id" => "group-tr-dst",
        "guest_id" => "guest-22",
        "property_id" => "rtx-plaza",
        "occurred_on" => "2026-10-03",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 20_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-tr-src", 12_000, %{
          "operation_id" => "op-pay-tr",
          "occurred_on" => "2030-09-01"
        })
      ])

      run_and_get_results([start_reporting_operation("2030-09-02")])

      run_and_get_results([
        transfer_operation("group-tr-src", "group-tr-dst", 7_000, %{"occurred_on" => "2030-09-03"})
      ])

      report = fetch_daily_report("2030-09-03")
      by_property = Map.new(report["cash"], &{&1["property_id"], &1})

      ams = by_property["ams-canal"]
      rtx = by_property["rtx-plaza"]

      assert ams["movements"]["transferred_out_cents"] == 7_000
      assert ams["closing_held_cents"] == 5_000
      assert rtx["movements"]["transferred_in_cents"] == 7_000
      assert rtx["closing_held_cents"] == 7_000

      total_out =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_out_cents"]) |> Enum.sum()

      total_in =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_in_cents"]) |> Enum.sum()

      assert total_in == total_out
    end

    test "a reduction reports reduced_cents where the cash was held" do
      open_default_group("group-reduce")
      run_and_get_results([start_reporting_operation("2030-10-01")])

      run_and_get_results([
        pay_operation("group-reduce", 19_500, %{
          "operation_id" => "op-pay-red",
          "occurred_on" => "2030-10-02"
        })
      ])

      run_and_get_results([
        reduce_cash_payment_operation("op-pay-red", 4_500, %{"occurred_on" => "2030-10-03"}),
        reduce_cash_payment_operation("op-pay-red", 2_500, %{
          "operation_id" => "op-reduce-two",
          "occurred_on" => "2030-10-04"
        })
      ])

      day_three = fetch_daily_report("2030-10-03")
      assert [entry] = day_three["cash"]
      assert entry["movements"]["reduced_cents"] == 4_500
      assert entry["closing_held_cents"] == 15_000

      day_four = fetch_daily_report("2030-10-04")
      assert [entry] = day_four["cash"]
      assert entry["opening_held_cents"] == 15_000
      assert entry["movements"]["reduced_cents"] == 2_500
      assert entry["closing_held_cents"] == 12_500
    end

    test "charging back held cash reports charged_back at the holding property" do
      open_default_group("group-chb")
      run_and_get_results([start_reporting_operation("2030-11-01")])

      run_and_get_results([
        pay_operation("group-chb", 9_000, %{
          "operation_id" => "op-pay-chb",
          "occurred_on" => "2030-11-02"
        })
      ])

      run_and_get_results([
        charge_back_operation("op-pay-chb", %{"occurred_on" => "2030-11-03"})
      ])

      report = fetch_daily_report("2030-11-03")
      assert [entry] = report["cash"]
      assert entry["movements"]["charged_back_cents"] == 9_000
      assert entry["closing_held_cents"] == 0
    end

    test "charging back settled cash reverses the refund classification" do
      open_operation(%{
        "operation_id" => "op-open-chbr",
        "group_id" => "group-chbr",
        "guest_id" => "guest-chb",
        "property_id" => "ams-canal",
        "occurred_on" => "2030-01-02",
        "arrival_on" => "2030-03-10",
        "departure_on" => "2030-03-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-chbr", 9_000, %{
          "operation_id" => "op-pay-chbr",
          "occurred_on" => "2030-01-03"
        })
      ])

      run_and_get_results([start_reporting_operation("2030-01-04")])

      run_and_get_results([
        cancel_operation("group-chbr", %{"occurred_on" => "2030-01-05"}),
        charge_back_operation("op-pay-chbr", %{
          "operation_id" => "op-chb-settled",
          "occurred_on" => "2030-01-07"
        })
      ])

      report = fetch_daily_report("2030-01-07")
      assert [entry] = report["cash"]

      expected_movements =
        Map.merge(@empty_cash_movements, %{
          "refunded_cents" => -9_000,
          "charged_back_cents" => 9_000
        })

      assert %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => ^expected_movements,
               "closing_held_cents" => 0
             } = entry

      ledger = fetch_ledger()
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 9_000
      assert ledger["cash_held_cents"] == 0
    end

    test "converting cash to credit issues liability and expiry shows without an operation" do
      open_operation(%{
        "operation_id" => "op-open-conv",
        "group_id" => "group-conv",
        "guest_id" => "guest-conv",
        "property_id" => "ams-canal",
        "occurred_on" => "2030-01-02",
        "arrival_on" => "2030-03-10",
        "departure_on" => "2030-03-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([
        pay_operation("group-conv", 9_000, %{
          "operation_id" => "op-pay-conv",
          "occurred_on" => "2030-01-03"
        })
      ])

      run_and_get_results([start_reporting_operation("2030-01-04")])

      run_and_get_results([
        cancel_operation("group-conv", %{
          "operation_id" => "op-cancel-conv",
          "occurred_on" => "2030-01-05",
          "refund_method" => "hotel_credit"
        })
      ])

      issued_report = fetch_daily_report("2030-01-05")

      assert [entry] = issued_report["cash"]
      assert entry["movements"]["converted_to_credit_cents"] == 9_000
      assert entry["closing_held_cents"] == 0

      assert issued_report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{@empty_credit_movements | "issued_cents" => 9_900},
               "closing_liability_cents" => 9_900
             }

      # The lot stays available through its expiry minus one...
      quiet_report = fetch_daily_report("2031-01-05")

      assert quiet_report["credit"] == %{
               "opening_liability_cents" => 9_900,
               "movements" => @empty_credit_movements,
               "closing_liability_cents" => 9_900
             }

      # ...and expires on the following date with no partner operation that day.
      expired_report = fetch_daily_report("2031-01-06")

      assert expired_report["credit"] == %{
               "opening_liability_cents" => 9_900,
               "movements" => %{@empty_credit_movements | "expired_cents" => 9_900},
               "closing_liability_cents" => 0
             }

      assert expired_report["cash"] == []
    end

    test "non-refundable settlement consumes applied credit" do
      # Issue credit through a refundable hotel-credit cancellation.
      issue_credit_for_guest("guest-consume")

      open_operation(%{
        "operation_id" => "op-open-consume",
        "group_id" => "group-consume",
        "guest_id" => "guest-consume",
        "property_id" => "ams-canal",
        "occurred_on" => "2030-01-02",
        "arrival_on" => "2030-01-08",
        "departure_on" => "2030-01-10",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([start_reporting_operation("2030-01-04")])

      run_and_get_results([
        credit_operation("group-consume", 3_000, %{
          "operation_id" => "op-apply-consume",
          "occurred_on" => "2030-01-05"
        }),
        cancel_operation("group-consume", %{
          "operation_id" => "op-cancel-consume",
          "occurred_on" => "2030-01-06"
        })
      ])

      report = fetch_daily_report("2030-01-06")
      assert report["cash"] == []
      # The seed lot (9_900) sits in the opening liability; the non-refundable
      # settlement consumes the applied 3_000.
      assert report["credit"]["opening_liability_cents"] == 9_900
      assert report["credit"]["movements"]["consumed_cents"] == 3_000
      assert report["credit"]["closing_liability_cents"] == 6_900
    end

    test "rejected operations leave no movement and earlier movements remain" do
      open_default_group("group-reject")
      run_and_get_results([start_reporting_operation("2030-12-01")])

      results =
        run_and_get_results([
          pay_operation("group-reject", 5_000, %{"occurred_on" => "2030-12-02"}),
          pay_operation("group-reject", 999_999, %{
            "operation_id" => "op-pay-too-much",
            "occurred_on" => "2030-12-02"
          })
        ])

      assert Enum.at(results, 1)["code"] == "payment_exceeds_outstanding"

      report = fetch_daily_report("2030-12-02")
      assert [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 5_000
      assert entry["closing_held_cents"] == 5_000
    end

    test "a durable retry does not report a movement twice" do
      open_default_group("group-retry")
      run_and_get_results([start_reporting_operation("2030-12-01")])

      operation = pay_operation("group-retry", 4_000, %{"occurred_on" => "2030-12-02"})

      run_and_get_results([operation])
      retried = run_and_get_results([operation])

      assert hd(retried)["status"] == "applied"

      report = fetch_daily_report("2030-12-02")
      assert [entry] = report["cash"]
      assert entry["movements"]["received_cents"] == 4_000
    end

    test "a chargeback revokes credit entitlement and later restoration absorbs the clawback" do
      issue_credit_for_guest("guest-claw")

      open_operation(%{
        "operation_id" => "op-open-claw",
        "group_id" => "group-claw",
        "guest_id" => "guest-claw",
        "property_id" => "ams-canal",
        "occurred_on" => "2030-01-02",
        "arrival_on" => "2030-03-10",
        "departure_on" => "2030-03-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      })
      |> List.wrap()
      |> post_operations()

      run_and_get_results([start_reporting_operation("2030-01-04")])

      run_and_get_results([
        credit_operation("group-claw", 4_950, %{
          "operation_id" => "op-apply-claw",
          "occurred_on" => "2030-01-04"
        })
      ])

      run_and_get_results([
        charge_back_payment_operation("op-pay-seed-guest-claw", %{
          "occurred_on" => "2030-01-05"
        })
      ])

      # The chargeback follows the converted principal back to the property
      # where it was settled and revokes the payment's credit entitlement.
      claw_report = fetch_daily_report("2030-01-05")
      assert [entry] = claw_report["cash"]

      assert entry["movements"]["converted_to_credit_cents"] == -9_000
      assert entry["movements"]["charged_back_cents"] == 9_000
      assert entry["closing_held_cents"] == 0

      assert claw_report["credit"] == %{
               "opening_liability_cents" => 9_900,
               "movements" => %{@empty_credit_movements | "revoked_cents" => 4_950},
               "closing_liability_cents" => 4_950
             }

      # Refundable settlement returns the applied credit, which is absorbed by
      # the unrecovered clawback instead of becoming available again.
      run_and_get_results([
        cancel_operation("group-claw", %{
          "operation_id" => "op-cancel-claw",
          "occurred_on" => "2030-01-06",
          "refund_method" => "cash"
        })
      ])

      absorb_report = fetch_daily_report("2030-01-06")

      assert absorb_report["credit"] == %{
               "opening_liability_cents" => 4_950,
               "movements" => %{@empty_credit_movements | "absorbed_cents" => 4_950},
               "closing_liability_cents" => 0
             }
    end

    test "reports reconcile to the current views and reading never changes anything" do
      open_default_group("group-rec")
      run_and_get_results([start_reporting_operation("2030-01-01")])

      run_and_get_results([
        pay_operation("group-rec", 12_000, %{"occurred_on" => "2030-01-02"}),
        reschedule_operation("group-rec", "2031-01-10", %{"occurred_on" => "2030-01-03"}),
        reduce_cash_payment_operation("op-pay", 3_000, %{"occurred_on" => "2030-01-04"})
      ])

      first_read = fetch_daily_report("2030-01-04")
      second_read = fetch_daily_report("2030-01-01")
      third_read = fetch_daily_report("2030-01-04")

      assert first_read == third_read
      assert second_read["date"] == "2030-01-01"

      ledger_before = fetch_ledger()

      # The latest day's closing balances reconcile with the current ledger
      # totals, and cumulative movements reconcile per classification.
      final_closing =
        fetch_daily_report("2030-01-04")["cash"]
        |> Enum.map(& &1["closing_held_cents"])
        |> Enum.sum()

      ledger_after = fetch_ledger()
      assert ledger_after == ledger_before
      assert final_closing == ledger_after["cash_held_cents"]

      reduced =
        Enum.sum(
          for date <- ["2030-01-01", "2030-01-02", "2030-01-03", "2030-01-04"],
              entry <- fetch_daily_report(date)["cash"],
              do: entry["movements"]["reduced_cents"]
        )

      assert reduced == ledger_after["cash_reduced_cents"]

      group = fetch_group("group-rec")
      assert group["outstanding_deposit_cents"] == 19_500 - 12_000 + 3_000
    end
  end

  defp charge_back_payment_operation(payment_operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-charge-back-report",
        "type" => "charge_back_payment",
        "occurred_on" => "2030-01-06",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp reduce_cash_payment_operation(payment_operation_id, amount_cents, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce-report",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2030-01-05",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  # Cancels a refundable flexible group funded with 9_000 cents (the room's
  # deposit) using hotel credit, issuing a 9_900 cent lot expiring 2031-01-05.
  defp issue_credit_for_guest(guest_id) do
    open_operation(%{
      "operation_id" => "op-open-seed-#{guest_id}",
      "group_id" => "group-seed-#{guest_id}",
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "occurred_on" => "2030-01-02",
      "arrival_on" => "2030-03-10",
      "departure_on" => "2030-03-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    })
    |> List.wrap()
    |> post_operations()

    run_and_get_results([
      pay_operation("group-seed-#{guest_id}", 9_000, %{
        "operation_id" => "op-pay-seed-#{guest_id}",
        "occurred_on" => "2030-01-03"
      }),
      cancel_operation("group-seed-#{guest_id}", %{
        "operation_id" => "op-cancel-seed-#{guest_id}",
        "occurred_on" => "2030-01-04",
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
