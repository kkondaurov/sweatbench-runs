defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  alias GroupStay.FinanceReporting.Snapshot
  alias GroupStay.Repo

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp get_report(date) do
    api_get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
  end

  defp get_ledger do
    api_get(build_conn(), "/api/v1/ledger")
  end

  defp get_operation(operation_id) do
    api_get(build_conn(), "/api/v1/operations/#{operation_id}")
  end

  defp report_data(date) do
    {body, 200} = get_report(date)
    body["data"]
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp late_cash_entry(report, property_id) do
    Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
  end

  defp late_credit(report) do
    report["late_adjustments"]["credit"]
  end

  defp empty_late_credit do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp payment(overrides) do
    cash_payment_op(%{"operation_id" => "op-2001", "occurred_on" => "2026-10-05"})
    |> Map.merge(overrides)
  end

  describe "closing a finance period" do
    test "the applied close returns exactly its three fields" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {body, 200} = post_ops([close_finance_period_op()])

      assert result(body) == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2026-10-10"
             }

      assert Map.keys(result(body)) |> Enum.sort() == ["operation_id", "period_end_on", "status"]
    end

    test "closing before reporting has started is rejected with invalid_period" do
      {body, 200} = post_ops([close_finance_period_op()])

      assert result(body) == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      {body, 404} = get_report("2026-10-10")
      assert body == %{"error" => %{"code" => "report_not_available"}}
    end

    test "a cutoff before starts_on is rejected and reports stay open" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {body, 200} =
        post_ops([
          close_finance_period_op(%{"operation_id" => "close-1", "period_end_on" => "2026-10-02"})
        ])

      assert result(body)["code"] == "invalid_period"

      assert report_data("2026-10-03")["status"] == "open"
    end

    test "an invalid or missing period_end_on is rejected with invalid_period" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      for {period_end_on, index} <-
            Enum.with_index([nil, "not-a-date", "2026-13-01", "2026-10-10T10:00:00", 42]) do
        op =
          close_finance_period_op(%{
            "operation_id" => "close-bad-#{index}",
            "period_end_on" => period_end_on
          })

        {body, 200} = post_ops([op])

        assert result(body) == %{
                 "operation_id" => "close-bad-#{index}",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
      end

      assert report_data("2026-10-03")["status"] == "open"
    end

    test "a later close must be strictly later than the latest successful close" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])
      {_, 200} = post_ops([close_finance_period_op()])

      for {operation_id, period_end_on} <- [{"close-2", "2026-10-10"}, {"close-3", "2026-10-09"}] do
        {body, 200} =
          post_ops([
            close_finance_period_op(%{
              "operation_id" => operation_id,
              "period_end_on" => period_end_on
            })
          ])

        assert result(body) == %{
                 "operation_id" => operation_id,
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
      end

      {body, 200} =
        post_ops([
          close_finance_period_op(%{"operation_id" => "close-4", "period_end_on" => "2026-10-12"})
        ])

      assert result(body)["status"] == "applied"

      assert report_data("2026-10-11")["status"] == "closed"
      assert report_data("2026-10-12")["status"] == "closed"
      assert report_data("2026-10-13")["status"] == "open"
    end

    test "a retry of the original close returns the stored result" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])
      {body, 200} = post_ops([close_finance_period_op()])
      applied = result(body)

      {retry_body, 200} = post_ops([close_finance_period_op()])
      assert result(retry_body) == applied

      {body, 200} =
        post_ops([
          close_finance_period_op(%{"period_end_on" => "2026-11-01", "operation_id" => "close-1"})
        ])

      assert result(body) == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      {stored, 200} = get_operation("close-1")
      assert stored == %{"data" => applied}
    end

    test "a close in the same batch as the start sees reporting enabled" do
      {body, 200} =
        post_ops([open_group_op(), start_finance_reporting_op(), close_finance_period_op()])

      assert result(body, 1)["status"] == "applied"
      assert result(body, 2)["status"] == "applied"
      assert report_data("2026-10-03")["status"] == "closed"
    end

    test "a close before the start in the same batch is rejected" do
      {body, 200} = post_ops([close_finance_period_op(), start_finance_reporting_op()])

      assert result(body, 0)["code"] == "invalid_period"
      assert result(body, 1)["status"] == "applied"
      assert report_data("2026-10-03")["status"] == "open"
    end
  end

  describe "publishing reports" do
    setup do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      :ok
    end

    test "closed reports are published, byte-for-byte stable, and stored" do
      {_, 200} = post_ops([close_finance_period_op()])

      {_, 200} = first_response = get_report("2026-10-05")
      report = report_data("2026-10-05")
      assert report["status"] == "closed"

      snapshot = Repo.get_by(Snapshot, report_date: ~D[2026-10-05])
      assert Jason.decode!(snapshot.data) == report

      # A later old-dated operation posts on the first open day instead of
      # touching the closed report.
      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 2_000
          })
        ])

      {_, 200} = later_response = get_report("2026-10-05")
      assert later_response == first_response

      {_, 200} =
        post_ops([
          close_finance_period_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-20"})
        ])

      {_, 200} = final_response = get_report("2026-10-05")
      assert final_response == first_response
      assert Jason.decode!(snapshot.data) == report_data("2026-10-05")
    end

    test "every report through the cutoff is closed and later reports stay open" do
      {_, 200} = post_ops([close_finance_period_op()])

      for date <- ["2026-10-03", "2026-10-04", "2026-10-09", "2026-10-10"] do
        assert report_data(date)["status"] == "closed"
      end

      assert report_data("2026-10-11")["status"] == "open"
      assert report_data("2026-11-01")["status"] == "open"
    end

    test "a close through starts_on closes only the first day" do
      {_, 200} = post_ops([close_finance_period_op(%{"period_end_on" => "2026-10-03"})])

      assert report_data("2026-10-03")["status"] == "closed"
      assert report_data("2026-10-04")["status"] == "open"

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-03",
            "amount_cents" => 2_000
          })
        ])

      report = report_data("2026-10-04")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 0
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2_000
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts on the first open day as a late adjustment" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 2_000
          })
        ])

      report = report_data("2026-10-11")
      entry = cash_entry(report, "ams-canal")

      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 7_000

      assert late_cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "movements" => %{
                 "received_cents" => 2_000,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }

      assert late_credit(report) == empty_late_credit()

      # The closed day is untouched.
      closed = report_data("2026-10-06")
      assert closed["status"] == "closed"
      assert cash_entry(closed, "ams-canal")["movements"]["received_cents"] == 0
      assert closed["late_adjustments"] == %{"cash" => [], "credit" => empty_late_credit()}
    end

    test "an operation dated in the open period keeps its date and is not late" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-12",
            "amount_cents" => 3_000
          })
        ])

      report = report_data("2026-10-12")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 3_000
      assert report["late_adjustments"] == %{"cash" => [], "credit" => empty_late_credit()}

      report = report_data("2026-10-11")
      assert report["cash"] == []
    end

    test "an operation with occurred_on before starts_on posts on the first open day" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-09-20",
            "amount_cents" => 5_000
          })
        ])

      report = report_data("2026-10-11")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 0
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 5_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 5_000
    end

    test "an operation without occurred_on posts on the first open day after a close" do
      destination =
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-03",
          "guest_id" => "guest-22",
          "property_id" => "ams-plaza",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 20_000}]
        })

      {_, 200} =
        post_ops([
          open_group_op(),
          destination,
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          close_finance_period_op()
        ])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 2_000})])

      report = report_data("2026-10-11")

      assert cash_entry(report, "ams-canal")["movements"]["transferred_out_cents"] == 0

      assert late_cash_entry(report, "ams-canal")["movements"]["transferred_out_cents"] == 2_000
      assert late_cash_entry(report, "ams-plaza")["movements"]["transferred_in_cents"] == 2_000

      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 3_000
      assert cash_entry(report, "ams-plaza")["closing_held_cents"] == 2_000
    end

    test "two closes in one batch extend the cutoff in order" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {body, 200} =
        post_ops([
          close_finance_period_op(),
          close_finance_period_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-12"})
        ])

      assert result(body, 0)["status"] == "applied"
      assert result(body, 1)["status"] == "applied"

      assert report_data("2026-10-10")["status"] == "closed"
      assert report_data("2026-10-11")["status"] == "closed"
      assert report_data("2026-10-12")["status"] == "closed"
      assert report_data("2026-10-13")["status"] == "open"
    end

    test "an operation immediately before a close posts into the period being closed" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {body, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 2_000
          }),
          close_finance_period_op()
        ])

      assert result(body, 0)["status"] == "applied"
      assert result(body, 1)["status"] == "applied"

      report = report_data("2026-10-06")
      assert report["status"] == "closed"
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2_000
      assert report["late_adjustments"] == %{"cash" => [], "credit" => empty_late_credit()}
    end

    test "an old-dated operation immediately after a close posts on the first open day" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {body, 200} =
        post_ops([
          close_finance_period_op(),
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 2_000
          })
        ])

      assert result(body, 0)["status"] == "applied"
      assert result(body, 1)["status"] == "applied"

      closed = report_data("2026-10-06")
      assert closed["status"] == "closed"
      assert cash_entry(closed, "ams-canal")["movements"]["received_cents"] == 0

      report = report_data("2026-10-11")
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 7_000
    end

    test "an operation keeps its posting date when a later close arrives" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 2_000
          })
        ])

      {_, 200} =
        post_ops([
          close_finance_period_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-20"})
        ])

      # The late movement stayed on 2026-10-11 even though a new close arrived.
      report = report_data("2026-10-11")
      assert report["status"] == "closed"
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2_000

      report = report_data("2026-10-21")
      assert report["status"] == "open"
      assert report["late_adjustments"] == %{"cash" => [], "credit" => empty_late_credit()}
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 7_000
    end

    test "a close does not change stored operation results or the ledger" do
      {body, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      before_payment = result(body, 2)
      {_, 200} = post_ops([close_finance_period_op()])

      {stored, 200} = get_operation("op-2001")
      assert stored == %{"data" => before_payment}

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 5_000
    end
  end

  describe "late adjustments" do
    test "every successful report has late_adjustments, empty before any close" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      report = report_data("2026-10-03")
      assert report["late_adjustments"] == %{"cash" => [], "credit" => empty_late_credit()}
    end

    test "charging back a previously refunded payment reports signed late columns" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 100
          }),
          cancel_op(%{"operation_id" => "op-4001", "occurred_on" => "2026-10-06"}),
          close_finance_period_op(%{"period_end_on" => "2026-10-08"}),
          charge_back_payment_op()
        ])

      report = report_data("2026-10-09")

      assert late_cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -100,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 100
               }
             }

      assert late_credit(report) == empty_late_credit()

      # The net balance effect is zero, so the ordinary entry is omitted.
      assert is_nil(cash_entry(report, "ams-canal"))

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 100
    end

    test "late cash entries are ordered by property_id and omit all-zero properties" do
      destination =
        open_group_op(%{
          "operation_id" => "op-1002",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-03",
          "guest_id" => "guest-22",
          "property_id" => "ams-plaza",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 20_000}]
        })

      {_, 200} = post_ops([open_group_op(), destination, start_finance_reporting_op()])
      {_, 200} = post_ops([close_finance_period_op()])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          payment(%{
            "operation_id" => "op-2002",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 3_000
          })
        ])

      report = report_data("2026-10-11")

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "ams-plaza"]

      assert is_nil(late_cash_entry(report, "ams-central"))
    end

    test "a day's totals add the ordinary and late values and balances use both" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 2_000
          }),
          payment(%{
            "operation_id" => "op-2003",
            "occurred_on" => "2026-10-11",
            "amount_cents" => 1_000
          })
        ])

      report = report_data("2026-10-11")
      entry = cash_entry(report, "ams-canal")

      assert entry["movements"]["received_cents"] == 1_000
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2_000
      assert entry["closing_held_cents"] == 8_000

      # The day's total movement is the ordinary value plus the late value.
      assert entry["movements"]["received_cents"] +
               late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 3_000

      # The closing balance uses both, cumulatively: 5,000 from the payment
      # on 10-05 plus the day's 1,000 ordinary and 2,000 late receipts.
      assert entry["closing_held_cents"] ==
               5_000 + entry["movements"]["received_cents"] +
                 late_cash_entry(report, "ams-canal")["movements"]["received_cents"]
    end

    test "late credit movements appear in late_adjustments.credit" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      report = report_data("2026-10-11")

      assert report["credit"]["movements"]["issued_cents"] == 0
      assert late_credit(report)["issued_cents"] == 5_500
      assert report["credit"]["closing_liability_cents"] == 5_500

      # The held cash closed at zero and no ordinary movement happened that
      # day, so the ordinary cash entry is omitted; the late conversion
      # still reports the moved movement.
      assert is_nil(cash_entry(report, "ams-canal"))

      assert late_cash_entry(report, "ams-canal")["movements"]["converted_to_credit_cents"] ==
               5_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_converted_to_credit_cents"] == 5_000
      assert ledger["data"]["credit_liability_cents"] == 5_500
    end

    test "a close freezing a later expiry date keeps the expiry on its own day" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      {_, 200} =
        post_ops([
          close_finance_period_op(%{"operation_id" => "close-1", "period_end_on" => "2027-10-01"})
        ])

      report = report_data("2027-10-01")
      assert report["status"] == "closed"
      assert report["credit"]["movements"]["expired_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 5_500

      {_, 200} =
        post_ops([
          close_finance_period_op(%{"operation_id" => "close-2", "period_end_on" => "2027-10-10"})
        ])

      report = report_data("2027-10-07")
      assert report["status"] == "closed"
      assert report["credit"]["movements"]["expired_cents"] == 5_500
      assert report["credit"]["closing_liability_cents"] == 0
      assert late_credit(report)["expired_cents"] == 0
    end
  end

  describe "durability" do
    test "a rejected close freezes nothing" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {_, 200} =
        post_ops([
          close_finance_period_op(%{
            "operation_id" => "close-bad",
            "period_end_on" => "2026-10-02"
          })
        ])

      assert report_data("2026-10-03")["status"] == "open"

      {_, 200} = post_ops([close_finance_period_op()])
      assert report_data("2026-10-03")["status"] == "closed"
    end

    test "a durable retry does not freeze twice or report a movement twice" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          payment(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          close_finance_period_op()
        ])

      {_, 200} = post_ops([close_finance_period_op()])

      assert Repo.aggregate(Snapshot, :count) == 8

      pay =
        payment(%{
          "operation_id" => "op-2002",
          "occurred_on" => "2026-10-06",
          "amount_cents" => 2_000
        })

      {_, 200} = post_ops([pay])
      {_, 200} = post_ops([pay])

      report = report_data("2026-10-11")
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 7_000

      assert Repo.aggregate(Snapshot, :count) == 8
    end

    test "a rejected operation after a close reports nothing" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          close_finance_period_op()
        ])

      {_, 200} =
        post_ops([
          payment(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 50_000
          })
        ])

      report = report_data("2026-10-11")
      assert report["late_adjustments"] == %{"cash" => [], "credit" => empty_late_credit()}
      assert report["cash"] == []
    end
  end
end
