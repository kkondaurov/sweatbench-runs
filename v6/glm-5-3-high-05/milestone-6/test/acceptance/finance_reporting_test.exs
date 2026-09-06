defmodule GroupStayWeb.Acceptance.FinanceReportingTest do
  @moduledoc """
  Acceptance tests for the daily finance report: the reporting inception
  point (`start_finance_reporting`), the per-day cash and credit report
  shape and arithmetic, posting dates, corrections following transferred
  cash, natural credit expiry, and the report's reconciliation with the
  current views.
  """

  use GroupStayWeb.ConnCase, async: true

  @zero_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @zero_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  describe "starting finance reporting" do
    test "the first applied start operation returns exactly operation_id, status, and starts_on" do
      result =
        apply_one!(
          build_conn(),
          start_reporting_operation(%{
            "operation_id" => "op-start-1",
            "starts_on" => "2026-11-01"
          })
        )

      assert result == %{
               "operation_id" => "op-start-1",
               "status" => "applied",
               "starts_on" => "2026-11-01"
             }
    end

    test "a retry of the original start operation replays its stored result" do
      operation =
        start_reporting_operation(%{"operation_id" => "op-start-1", "starts_on" => "2026-11-01"})

      original = apply_one!(build_conn(), operation)
      assert %{"status" => "applied"} = original

      assert apply_one!(build_conn(), operation) == original
    end

    test "a different start operation is rejected once reporting has started" do
      apply_one!(build_conn(), start_reporting_operation(%{"starts_on" => "2026-11-01"}))

      result =
        apply_one!(
          build_conn(),
          start_reporting_operation(%{"starts_on" => "2026-12-01"})
        )

      assert %{"status" => "rejected", "code" => "reporting_already_started"} = result
    end

    test "a rejected start operation is durably rejected on retry" do
      operation =
        start_reporting_operation(%{"operation_id" => "op-start-bad", "starts_on" => "nope"})

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               apply_one!(build_conn(), operation)

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
               apply_one!(build_conn(), operation)

      # A valid start still applies afterwards: the first applied start
      # operation enables reporting.
      assert %{"status" => "applied"} =
               apply_one!(build_conn(), start_reporting_operation())
    end

    test "an invalid or missing starts_on is rejected with invalid_reporting_date" do
      for attrs <- [
            %{"starts_on" => "2026-13-01"},
            %{"starts_on" => "not-a-date"},
            %{"starts_on" => 42},
            %{"starts_on" => nil}
          ] do
        result = apply_one!(build_conn(), start_reporting_operation(attrs))

        assert %{"status" => "rejected", "code" => "invalid_reporting_date"} = result
      end

      result =
        apply_one!(
          build_conn(),
          Map.delete(start_reporting_operation(), "starts_on")
        )

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} = result
    end
  end

  describe "reading one day" do
    test "before reporting has started the report is not available" do
      conn = get_daily_report(build_conn(), "2026-11-01")

      assert %{status: 404} = conn
      assert %{"error" => %{"code" => "report_not_available"}} == json_response(conn, 404)
    end

    test "a missing or invalid date is rejected with invalid_reporting_date" do
      start_reporting!()

      conn = get_daily_report(build_conn(), nil)

      assert %{status: 422} = conn
      assert %{"error" => %{"code" => "invalid_reporting_date"}} == json_response(conn, 422)

      for date <- ["", "not-a-date", "2026-13-01", "20261101"] do
        conn = get_daily_report(build_conn(), date)

        assert %{status: 422} = conn
        assert %{"error" => %{"code" => "invalid_reporting_date"}} == json_response(conn, 422)
      end
    end

    test "a date before starts_on is not available" do
      start_reporting!(%{"starts_on" => "2026-11-02"})

      conn = get_daily_report(build_conn(), "2026-11-01")

      assert %{status: 404} = conn
      assert %{"error" => %{"code" => "report_not_available"}} == json_response(conn, 404)
    end

    test "the report shape is exactly date, status, cash, and credit" do
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"group_id" => "group-81"}),
          record_cash_operation(%{"group_id" => "group-81", "amount_cents" => 5000}),
          start_reporting_operation(%{"starts_on" => "2026-11-05"})
        ])

      assert %{status: 200} = conn

      conn = get_daily_report(build_conn(), "2026-11-05")

      assert %{status: 200} = conn

      assert json_response(conn, 200)["data"] == %{
               "date" => "2026-11-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 5000,
                   "movements" => @zero_cash_movements,
                   "closing_held_cents" => 5000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => @zero_credit_movements,
                 "closing_liability_cents" => 0
               }
             }
    end

    test "operations before the start contribute to the opening position and after it movements" do
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{"group_id" => "group-81"}),
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 2000,
            "occurred_on" => "2026-11-01"
          }),
          start_reporting_operation(%{
            "occurred_on" => "2026-11-02",
            "starts_on" => "2026-11-02"
          }),
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 3000,
            "occurred_on" => "2026-11-02"
          })
        ])

      assert %{status: 200} = conn

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 2000,
                   "movements" => %{"received_cents" => 3000},
                   "closing_held_cents" => 5000
                 }
               ]
             } = daily_report("2026-11-02")
    end

    test "committed operations with occurred_on on or after starts_on are in the opening position" do
      open_group!(build_conn(), %{"group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-10"
        })
      )

      start_reporting!(%{"starts_on" => "2026-11-01"})

      assert %{
               "cash" => [
                 %{"opening_held_cents" => 5000, "closing_held_cents" => 5000}
               ]
             } = daily_report("2026-11-01")

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 5000,
                   "movements" => @zero_cash_movements,
                   "closing_held_cents" => 5000
                 }
               ]
             } = daily_report("2026-11-10")
    end
  end

  describe "cash movements by day" do
    setup do
      start_reporting!(%{"starts_on" => "2026-11-01"})
      open_group!(build_conn(), %{"group_id" => "group-81"})

      :ok
    end

    test "cash entries are ordered by property_id and all-zero properties are omitted" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-92",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      report = daily_report("2026-11-02")

      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "zbur-market"]

      # A day before any movement: no property has anything to report.
      assert daily_report("2026-11-01")["cash"] == []
    end

    test "a payment posts received on its occurred_on" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 0,
                   "movements" => %{"received_cents" => 5000},
                   "closing_held_cents" => 5000
                 }
               ]
             } = daily_report("2026-11-02")

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 5000,
                   "movements" => @zero_cash_movements,
                   "closing_held_cents" => 5000
                 }
               ]
             } = daily_report("2026-11-03")
    end

    test "a payment occurred before starts_on posts on starts_on" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-10-15"
        })
      )

      assert %{
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 5000},
                   "closing_held_cents" => 5000
                 }
               ]
             } = daily_report("2026-11-01")
    end

    test "a refundable cancellation posts refunded cash at the property" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-81", "occurred_on" => "2026-11-03"})
      )

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 5000,
                   "movements" => %{"refunded_cents" => 5000},
                   "closing_held_cents" => 0
                 }
               ]
             } = daily_report("2026-11-03")
    end

    test "a non-refundable cancellation posts retained cash" do
      open_group!(
        build_conn(),
        %{
          "group_id" => "group-adv",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
        }
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-adv",
          "amount_cents" => 10_000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-adv", "occurred_on" => "2026-11-03"})
      )

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 10_000,
                   "movements" => %{"retained_cents" => 10_000},
                   "closing_held_cents" => 0
                 }
               ]
             } = daily_report("2026-11-03")
    end

    test "a reduction posts reduced cash at the property" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        reduce_cash_operation(%{
          "payment_operation_id" => "op-pay-1",
          "amount_cents" => 1500,
          "occurred_on" => "2026-11-03"
        })
      )

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 5000,
                   "movements" => %{"reduced_cents" => 1500},
                   "closing_held_cents" => 3500
                 }
               ]
             } = daily_report("2026-11-03")
    end

    test "a transfer posts equal transferred-out and transferred-in on both properties" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-81",
          "destination_group_id" => "group-92",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        })
      )

      report = daily_report("2026-11-03")

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 5000,
                   "movements" => %{"transferred_out_cents" => 2000},
                   "closing_held_cents" => 3000
                 },
                 %{
                   "property_id" => "zbur-market",
                   "opening_held_cents" => 0,
                   "movements" => %{"transferred_in_cents" => 2000},
                   "closing_held_cents" => 2000
                 }
               ]
             } = report

      transferred_in =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_in_cents"]) |> Enum.sum()

      transferred_out =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_out_cents"]) |> Enum.sum()

      assert transferred_in == transferred_out
    end

    test "a correction follows transferred cash to the property where it is held" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-81",
          "destination_group_id" => "group-92",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        })
      )

      # The reduction removes the payment's most recent allocation, which the
      # transfer moved to zbur-market: the movement posts there, not at the
      # payment's original property.
      apply_one!(
        build_conn(),
        reduce_cash_operation(%{
          "payment_operation_id" => "op-pay-1",
          "amount_cents" => 1500,
          "occurred_on" => "2026-11-04"
        })
      )

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => @zero_cash_movements,
                   "closing_held_cents" => 3000
                 },
                 %{
                   "property_id" => "zbur-market",
                   "movements" => %{"reduced_cents" => 1500},
                   "closing_held_cents" => 500
                 }
               ]
             } = daily_report("2026-11-04")
    end

    test "a chargeback of held cash posts charged_back at the property" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-03"
        })
      )

      assert %{
               "cash" => [
                 %{
                   "opening_held_cents" => 5000,
                   "movements" => %{"charged_back_cents" => 5000},
                   "closing_held_cents" => 0
                 }
               ]
             } = daily_report("2026-11-03")
    end

    test "reversing an earlier refund reports negative refunded with positive charged_back" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-81", "occurred_on" => "2026-11-03"})
      )

      assert %{"refunded_cents" => 5000} = cash_movements("2026-11-03")

      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-04"
        })
      )

      assert %{
               "refunded_cents" => -5000,
               "charged_back_cents" => 5000
             } = cash_movements("2026-11-04")

      assert %{"closing_held_cents" => 0} = cash_entry("2026-11-04")
    end

    test "reversing a settlement follows the settled cash to the property where it settled" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        transfer_deposit_operation(%{
          "source_group_id" => "group-81",
          "destination_group_id" => "group-92",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-04"})
      )

      # The refund settled at zbur-market, so reversing it posts there rather
      # than at the payment's original property.
      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-05"
        })
      )

      assert %{
               "refunded_cents" => -2000,
               "charged_back_cents" => 2000
             } = cash_movements("2026-11-05", "zbur-market")

      assert %{"charged_back_cents" => 3000} = cash_movements("2026-11-05", "ams-canal")

      assert %{"closing_held_cents" => 0} = cash_entry("2026-11-05", "ams-canal")
    end

    test "a rejected operation leaves no movement and keeps earlier movements" do
      conn =
        post_batch(build_conn(), [
          record_cash_operation(%{
            "group_id" => "group-81",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-02"
          }),
          transfer_deposit_operation(%{
            "source_group_id" => "group-81",
            "destination_group_id" => "group-none",
            "amount_cents" => 1000,
            "occurred_on" => "2026-11-02"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "rejected"}
               ]
             } = json_response(conn, 200)

      assert %{"received_cents" => 5000} = cash_movements("2026-11-02")
    end

    test "a durable retry does not report a movement twice" do
      operation =
        record_cash_operation(%{
          "operation_id" => "op-pay-1",
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })

      apply_one!(build_conn(), operation)
      apply_one!(build_conn(), operation)

      assert %{"received_cents" => 5000} = cash_movements("2026-11-02")
      assert %{"closing_held_cents" => 5000} = cash_entry("2026-11-02")
    end

    test "a later submission changes an earlier open report" do
      assert daily_report("2026-11-03")["cash"] == []

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 2500,
          "occurred_on" => "2026-11-03"
        })
      )

      assert %{"received_cents" => 2500} = cash_movements("2026-11-03")
    end

    test "each day reconciles: closing equals opening plus signed movements" do
      open_group!(
        build_conn(),
        %{"group_id" => "group-92", "property_id" => "zbur-market"}
      )

      operations = [
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        }),
        record_cash_operation(%{
          "group_id" => "group-92",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-02"
        }),
        transfer_deposit_operation(%{
          "source_group_id" => "group-81",
          "destination_group_id" => "group-92",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        }),
        reduce_cash_operation(%{
          "payment_operation_id" => "op-pay-1",
          "amount_cents" => 1000,
          "occurred_on" => "2026-11-04"
        }),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-05"})
      ]

      Enum.each(operations, &apply_one!(build_conn(), &1))

      for date <- ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"] do
        report = daily_report(date)

        for entry <- report["cash"] do
          movements = entry["movements"]

          expected =
            entry["opening_held_cents"] + movements["received_cents"] +
              movements["transferred_in_cents"] - movements["transferred_out_cents"] -
              movements["refunded_cents"] - movements["retained_cents"] -
              movements["converted_to_credit_cents"] - movements["reduced_cents"] -
              movements["charged_back_cents"]

          assert expected == entry["closing_held_cents"],
                 "cash identity failed for #{date} #{entry["property_id"]}"
        end
      end

      # The latest report's closing reconciles to the current ledger view.
      final = daily_report("2026-11-05")

      held =
        final["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

      assert held == ledger()["cash_held_cents"]
    end

    test "equivalent batches and sequential submissions produce equivalent reports" do
      sequential_operations = [
        open_group_operation(%{
          "group_id" => "group-seq",
          "property_id" => "zbur-market"
        }),
        record_cash_operation(%{
          "group_id" => "group-seq",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        }),
        record_cash_operation(%{
          "group_id" => "group-seq",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-03"
        })
      ]

      Enum.each(sequential_operations, &apply_one!(build_conn(), &1))

      # The same history, submitted as one batch to a different group and
      # property: only the identifiers differ.
      conn =
        post_batch(build_conn(), [
          open_group_operation(%{
            "group_id" => "group-batch",
            "property_id" => "york-harbour"
          }),
          record_cash_operation(%{
            "group_id" => "group-batch",
            "amount_cents" => 5000,
            "occurred_on" => "2026-11-02"
          }),
          record_cash_operation(%{
            "group_id" => "group-batch",
            "amount_cents" => 3000,
            "occurred_on" => "2026-11-03"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      for date <- ["2026-11-02", "2026-11-03"] do
        report = daily_report(date)

        sequential =
          report["cash"] |> Enum.find(&(&1["property_id"] == "zbur-market"))

        batched =
          report["cash"] |> Enum.find(&(&1["property_id"] == "york-harbour"))

        assert {sequential["opening_held_cents"], sequential["movements"],
                sequential["closing_held_cents"]} ==
                 {batched["opening_held_cents"], batched["movements"],
                  batched["closing_held_cents"]}
      end
    end

    test "reading reports repeatedly or in any order changes nothing" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      first = daily_report("2026-11-02")
      _third_day_first = daily_report("2026-11-04")

      assert daily_report("2026-11-02") == first
      assert daily_report("2026-11-02") == first

      assert %{"cash_held_cents" => 5000} = ledger()
      assert %{"cash_paid_cents" => 5000} = group_data("group-81")
    end
  end

  describe "credit movements by day" do
    setup do
      start_reporting!(%{"starts_on" => "2026-11-01"})
      open_group!(build_conn(), %{"group_id" => "group-81"})

      :ok
    end

    test "a conversion posts converted cash and issued credit" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      assert %{
               "converted_to_credit_cents" => 5000
             } = cash_movements("2026-11-03")

      assert %{
               "opening_liability_cents" => 0,
               "movements" => %{"issued_cents" => 5500},
               "closing_liability_cents" => 5500
             } = daily_report("2026-11-03")["credit"]
    end

    test "a non-refundable settlement of applied credit posts consumed" do
      fund_credit_lot("group-lot", 5000, "2026-11-02")

      open_group!(
        build_conn(),
        %{
          "group_id" => "group-adv",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
        }
      )

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-adv",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-03"
        })
      )

      # Applying credit is not a liability movement.
      assert %{"movements" => @zero_credit_movements, "closing_liability_cents" => 5500} =
               daily_report("2026-11-03")["credit"]

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-adv", "occurred_on" => "2026-11-04"})
      )

      assert %{
               "movements" => %{"consumed_cents" => 5000},
               "closing_liability_cents" => 500
             } = daily_report("2026-11-04")["credit"]

      assert ledger("2026-11-04")["credit_liability_cents"] == 500
    end

    test "unused credit expires the day after its lot's expires_on, with no operation that day" do
      fund_credit_lot("group-lot", 5000, "2026-11-02")

      # The lot is worth 5500 and expires on 2027-11-02, so it expires on
      # 2027-11-03.
      assert %{"closing_liability_cents" => 5500} = daily_report("2027-11-02")["credit"]

      assert %{
               "movements" => %{"expired_cents" => 5500},
               "closing_liability_cents" => 0
             } = daily_report("2027-11-03")["credit"]

      assert ledger("2027-11-03")["credit_liability_cents"] == 0
    end

    test "credit applied before expiry pauses it and only the unused part expires" do
      fund_credit_lot("group-lot", 5000, "2026-11-02")

      open_group!(
        build_conn(),
        %{
          "group_id" => "group-hold",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-11",
          "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
        }
      )

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-hold",
          "amount_cents" => 2000,
          "occurred_on" => "2026-11-03"
        })
      )

      # Only the unused 3500 expires on 2027-11-03; the applied 2000 keeps
      # funding the active group.
      assert %{
               "movements" => %{"expired_cents" => 3500},
               "closing_liability_cents" => 2000
             } = daily_report("2027-11-03")["credit"]

      assert ledger("2027-11-03")["credit_liability_cents"] == 2000
    end

    test "a chargeback of converted cash posts revoked credit" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-04"
        })
      )

      assert %{"closing_liability_cents" => 5500} = daily_report("2026-11-03")["credit"]

      assert %{
               "movements" => %{"revoked_cents" => 5500},
               "closing_liability_cents" => 0
             } = daily_report("2026-11-04")["credit"]

      assert ledger()["credit_liability_cents"] == 0
    end

    test "restoring credit into a shortfalled lot posts absorbed" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      # The lot (5500) funds a second flexible group; the chargeback claws
      # back the payment's entitlement while 2500 of it is still available,
      # leaving a 3000 shortfall against the applied credit.
      open_group!(build_conn(), %{"group_id" => "group-92"})

      apply_one!(
        build_conn(),
        apply_hotel_credit_operation(%{
          "group_id" => "group-92",
          "amount_cents" => 3000,
          "occurred_on" => "2026-11-04"
        })
      )

      apply_one!(
        build_conn(),
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-05"
        })
      )

      assert %{
               "movements" => %{"revoked_cents" => 2500},
               "closing_liability_cents" => 3000
             } = daily_report("2026-11-05")["credit"]

      # The refundable settlement restores the applied credit straight into
      # the lot's unrecovered clawback.
      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-92", "occurred_on" => "2026-11-06"})
      )

      assert %{
               "movements" => %{"absorbed_cents" => 3000},
               "closing_liability_cents" => 0
             } = daily_report("2026-11-06")["credit"]

      assert ledger()["credit_liability_cents"] == 0
    end

    test "credit days telescope: closing equals opening plus signed movements" do
      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      for date <- ["2026-11-01", "2026-11-02", "2026-11-03", "2026-12-31"] do
        credit = daily_report(date)["credit"]
        movements = credit["movements"]

        expected =
          credit["opening_liability_cents"] + movements["issued_cents"] -
            movements["expired_cents"] - movements["consumed_cents"] -
            movements["revoked_cents"] - movements["absorbed_cents"]

        assert expected == credit["closing_liability_cents"],
               "credit identity failed for #{date}"
      end

      assert %{"closing_liability_cents" => 5500} = daily_report("2026-12-31")["credit"]
      assert ledger()["credit_liability_cents"] == 5500
    end
  end

  describe "reporting state and the opening liability" do
    test "the opening liability snapshots the pre-start credit state as of starts_on" do
      open_group!(build_conn(), %{"group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "operation_id" => "op-pay-1",
          "amount_cents" => 5000,
          "occurred_on" => "2026-11-02"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      start_reporting!(%{"starts_on" => "2026-11-01"})

      # The lot was issued before the start operation processed, so it is in
      # the opening position even though it was issued after starts_on.
      report = daily_report("2026-11-01")

      assert report["credit"]["opening_liability_cents"] == 5500
      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["closing_liability_cents"] == 5500
    end

    test "credit already expired before starts_on is neither in the opening nor a movement" do
      open_group!(build_conn(), %{"group_id" => "group-81"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{
          "group_id" => "group-81",
          "amount_cents" => 5000,
          "occurred_on" => "2025-01-01"
        })
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{
          "group_id" => "group-81",
          "occurred_on" => "2025-01-02",
          "refund_method" => "hotel_credit"
        })
      )

      # The lot expired on 2026-01-02, before starts_on.
      start_reporting!(%{"starts_on" => "2026-11-01"})

      report = daily_report("2026-11-01")

      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 0
    end
  end

  ## Helpers

  defp start_reporting!(attrs \\ %{}) do
    result = apply_one!(build_conn(), start_reporting_operation(attrs))
    assert %{"status" => "applied"} = result
    result
  end

  defp fund_credit_lot(group_id, amount_cents, cancelled_on) do
    open_group!(build_conn(), %{"group_id" => group_id})

    apply_one!(
      build_conn(),
      record_cash_operation(%{
        "group_id" => group_id,
        "amount_cents" => amount_cents,
        "occurred_on" => Date.add(Date.from_iso8601!(cancelled_on), -1) |> Date.to_iso8601()
      })
    )

    apply_one!(
      build_conn(),
      cancel_operation(%{
        "group_id" => group_id,
        "occurred_on" => cancelled_on,
        "refund_method" => "hotel_credit",
        "operation_id" => "cancel-lot-" <> group_id
      })
    )

    :ok
  end

  defp daily_report(date) do
    conn = get_daily_report(build_conn(), date)
    assert %{status: 200} = conn
    json_response(conn, 200)["data"]
  end

  defp cash_entry(date, property_id \\ "ams-canal") do
    date
    |> daily_report()
    |> Map.fetch!("cash")
    |> Enum.find(&(&1["property_id"] == property_id))
  end

  defp cash_movements(date, property_id \\ "ams-canal") do
    cash_entry(date, property_id)["movements"]
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end

  defp ledger(on \\ nil) do
    assert %{status: 200} = conn = get_ledger(build_conn(), on)
    json_response(conn, 200)["data"]
  end
end
