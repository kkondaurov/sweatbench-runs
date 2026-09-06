defmodule GroupStayWeb.PeriodCloseReportTest do
  @moduledoc """
  What a signed-off period does to the daily report: published days stop moving,
  and everything that arrives for them afterwards is reported on the first open
  day as a late adjustment.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.PartnerCase

  @no_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @no_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  describe "published days" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        close_period_op(%{"period_end_on" => "2026-10-31"})
      ])

      :ok
    end

    test "report as closed through the cutoff and open after it", %{conn: conn} do
      for date <- ["2026-10-04", "2026-10-20", "2026-10-31"] do
        assert read_daily_report(conn, date)["status"] == "closed"
      end

      for date <- ["2026-11-01", "2027-01-01"] do
        assert read_daily_report(conn, date)["status"] == "open"
      end
    end

    test "move their status forward when a later period is closed", %{conn: conn} do
      assert read_daily_report(conn, "2026-11-15")["status"] == "open"

      submit_one(
        conn,
        close_period_op(%{"operation_id" => "op-close-nov", "period_end_on" => "2026-11-30"})
      )

      assert read_daily_report(conn, "2026-11-15")["status"] == "closed"
      assert read_daily_report(conn, "2026-12-01")["status"] == "open"
    end

    test "stay byte for byte the same across later operations and later closes", %{conn: conn} do
      published =
        for date <- ["2026-10-04", "2026-10-20", "2026-10-31"], do: raw_report(conn, date)

      submit(conn, [
        payment_op(%{
          "operation_id" => "pay-late",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 2500
        }),
        reduce_op(%{
          "occurred_on" => "2026-10-06",
          "payment_operation_id" => "pay-late",
          "amount_cents" => 500
        }),
        cancel_op(%{"occurred_on" => "2026-10-30", "refund_method" => "hotel_credit"}),
        close_period_op(%{"operation_id" => "op-close-nov", "period_end_on" => "2026-11-30"})
      ])

      assert published ==
               for(date <- ["2026-10-04", "2026-10-20", "2026-10-31"], do: raw_report(conn, date))
    end

    test "publish their fields in a fixed order rather than a map's own", %{conn: conn} do
      assert key_order(raw_report(conn, "2026-10-04")) == ~w(
               data
               date
               status
               cash
               property_id
               opening_held_cents
               movements
               received_cents
               transferred_in_cents
               transferred_out_cents
               refunded_cents
               retained_cents
               converted_to_credit_cents
               reduced_cents
               charged_back_cents
               closing_held_cents
               credit
               opening_liability_cents
               movements
               issued_cents
               expired_cents
               consumed_cents
               revoked_cents
               absorbed_cents
               closing_liability_cents
               late_adjustments
               cash
               credit
               issued_cents
               expired_cents
               consumed_cents
               revoked_cents
               absorbed_cents
             )
    end

    test "are unchanged by reading them repeatedly and out of order", %{conn: conn} do
      first = raw_report(conn, "2026-10-31")

      for date <- ["2026-11-05", "2026-10-04", "2026-10-31", "2027-03-01"] do
        read_daily_report(conn, date)
      end

      assert raw_report(conn, "2026-10-31") == first
    end
  end

  describe "posting after a close" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        close_period_op(%{"period_end_on" => "2026-10-31"})
      ])

      :ok
    end

    test "posts an operation dated inside the closed period on the first open day",
         %{conn: conn} do
      submit_one(
        conn,
        payment_op(%{
          "operation_id" => "pay-late",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 3000
        })
      )

      assert cash(read_daily_report(conn, "2026-10-20")) == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 10_000
             }

      report = read_daily_report(conn, "2026-11-01")

      assert cash(report) == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 13_000
             }

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{@no_cash_movements | "received_cents" => 3000}
               }
             ]
    end

    test "keeps the date of an operation that is already in the open period", %{conn: conn} do
      submit_one(
        conn,
        payment_op(%{
          "operation_id" => "pay-open",
          "occurred_on" => "2026-11-05",
          "amount_cents" => 3000
        })
      )

      report = read_daily_report(conn, "2026-11-05")

      assert movements(report)["received_cents"] == 3000
      assert report["late_adjustments"]["cash"] == []
    end

    test "carries a late adjustment into the next day's opening balance", %{conn: conn} do
      submit_one(
        conn,
        payment_op(%{
          "operation_id" => "pay-late",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 3000
        })
      )

      assert cash(read_daily_report(conn, "2026-11-02")) == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 13_000,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 13_000
             }
    end

    test "never moves a posting date again once a later period is closed", %{conn: conn} do
      submit_one(
        conn,
        payment_op(%{
          "operation_id" => "pay-late",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 3000
        })
      )

      submit(conn, [
        close_period_op(%{"operation_id" => "op-close-nov", "period_end_on" => "2026-11-30"}),
        payment_op(%{
          "operation_id" => "pay-later",
          "occurred_on" => "2026-10-21",
          "amount_cents" => 500
        })
      ])

      assert late_movements(read_daily_report(conn, "2026-11-01"))["received_cents"] == 3000
      assert late_movements(read_daily_report(conn, "2026-12-01"))["received_cents"] == 500
    end

    test "posts on the first open day even when the operation is dated far in the past",
         %{conn: conn} do
      submit_one(
        conn,
        payment_op(%{
          "operation_id" => "pay-ancient",
          "occurred_on" => "2020-01-01",
          "amount_cents" => 1000
        })
      )

      assert late_movements(read_daily_report(conn, "2026-11-01"))["received_cents"] == 1000
    end
  end

  describe "a close inside a batch" do
    test "takes the operation before it into the period and the one after it out",
         %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{
          "operation_id" => "pay-in",
          "occurred_on" => "2026-10-10",
          "amount_cents" => 3000
        }),
        close_period_op(%{"period_end_on" => "2026-10-31"}),
        payment_op(%{
          "operation_id" => "pay-out",
          "occurred_on" => "2026-10-10",
          "amount_cents" => 4000
        })
      ])

      inside = read_daily_report(conn, "2026-10-10")

      assert inside["status"] == "closed"
      assert movements(inside)["received_cents"] == 3000
      assert inside["late_adjustments"]["cash"] == []

      outside = read_daily_report(conn, "2026-11-01")

      assert movements(outside)["received_cents"] == 0
      assert late_movements(outside)["received_cents"] == 4000
      assert cash(outside)["closing_held_cents"] == 7000
    end
  end

  describe "signed classifications in a late adjustment" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20"}),
        close_period_op(%{"period_end_on" => "2026-11-30"}),
        charge_back_op(%{"occurred_on" => "2026-11-25"})
      ])

      :ok
    end

    test "reports a reversed refund rather than a zero net adjustment", %{conn: conn} do
      report = read_daily_report(conn, "2026-12-01")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   @no_cash_movements
                   | "refunded_cents" => -10_000,
                     "charged_back_cents" => 10_000
                 }
               }
             ]
    end

    test "keeps the property in the day's cash even though the day's balances are zero",
         %{conn: conn} do
      assert cash(read_daily_report(conn, "2026-12-01")) == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 0
             }
    end

    test "leaves the published refund where it was", %{conn: conn} do
      published = read_daily_report(conn, "2026-11-20")

      assert published["status"] == "closed"
      assert movements(published)["refunded_cents"] == 10_000
      assert published["late_adjustments"]["cash"] == []
    end
  end

  describe "credit late adjustments" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        close_period_op(%{"period_end_on" => "2026-10-31"}),
        cancel_op(%{"occurred_on" => "2026-10-20", "refund_method" => "hotel_credit"})
      ])

      :ok
    end

    test "report the lot the settlement issued on the first open day", %{conn: conn} do
      report = read_daily_report(conn, "2026-11-01")

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 11_000
             }

      assert report["late_adjustments"]["credit"] == %{
               @no_credit_movements
               | "issued_cents" => 11_000
             }

      assert late_movements(report)["converted_to_credit_cents"] == 10_000
    end

    test "carry the liability into the next day's opening", %{conn: conn} do
      assert read_daily_report(conn, "2026-11-02")["credit"]["opening_liability_cents"] == 11_000
    end

    test "leave the closed day the cancellation happened on untouched", %{conn: conn} do
      published = read_daily_report(conn, "2026-10-20")

      assert published["credit"]["closing_liability_cents"] == 0
      assert published["late_adjustments"]["credit"] == @no_credit_movements
    end
  end

  describe "a day with both ordinary movements and late adjustments" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        close_period_op(%{"period_end_on" => "2026-10-31"}),
        payment_op(%{
          "operation_id" => "pay-open",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 2000
        }),
        reduce_op(%{
          "occurred_on" => "2026-10-20",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 2500
        })
      ])

      :ok
    end

    test "reports each in its own block and adds them into the balances", %{conn: conn} do
      report = read_daily_report(conn, "2026-11-01")

      assert movements(report) == %{@no_cash_movements | "received_cents" => 2000}
      assert late_movements(report) == %{@no_cash_movements | "reduced_cents" => 2500}

      assert cash(report) == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => %{@no_cash_movements | "received_cents" => 2000},
               "closing_held_cents" => 9500
             }
    end
  end

  describe "credit that a late restoration returns to an expired lot" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{
          "operation_id" => "op-open-92",
          "occurred_on" => "2026-11-21",
          "group_id" => "group-92",
          "property_id" => "ber-mitte",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
        }),
        credit_op(%{
          "occurred_on" => "2026-11-22",
          "group_id" => "group-92",
          "amount_cents" => 11_000
        }),
        # The lot was available through 2027-11-20; the open period starts well
        # after that, so the credit comes back to a lot that has already expired.
        close_period_op(%{"period_end_on" => "2027-12-31"}),
        cancel_op(%{
          "operation_id" => "op-cancel-92",
          "occurred_on" => "2027-01-10",
          "group_id" => "group-92"
        })
      ])

      :ok
    end

    test "reports the expiry as a late adjustment on the first open day", %{conn: conn} do
      report = read_daily_report(conn, "2028-01-01")

      assert report["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 0
             }

      assert report["late_adjustments"]["credit"] == %{
               @no_credit_movements
               | "expired_cents" => 11_000
             }
    end

    test "reconciles the closing liability with the ledger", %{conn: conn} do
      report = read_daily_report(conn, "2028-01-01")

      assert report["credit"]["closing_liability_cents"] ==
               read_ledger(conn, on: "2028-01-01")["credit_liability_cents"]
    end
  end

  describe "late adjustments across properties" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "ber-mitte"
        }),
        open_group_op(%{
          "operation_id" => "op-open-93",
          "group_id" => "group-93",
          "property_id" => "zrh-lake"
        }),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000}),
        payment_op(%{
          "operation_id" => "pay-93",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-93",
          "amount_cents" => 1000
        }),
        close_period_op(%{"period_end_on" => "2026-10-31"}),
        transfer_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 4000})
      ])

      :ok
    end

    test "are ordered by property and omit the properties they did not touch", %{conn: conn} do
      report = read_daily_report(conn, "2026-11-01")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{@no_cash_movements | "transferred_out_cents" => 4000}
               },
               %{
                 "property_id" => "ber-mitte",
                 "movements" => %{@no_cash_movements | "transferred_in_cents" => 4000}
               }
             ]
    end

    test "balance every property's day against its closing position", %{conn: conn} do
      report = read_daily_report(conn, "2026-11-01")
      late = Map.new(report["late_adjustments"]["cash"], &{&1["property_id"], &1["movements"]})

      for entry <- report["cash"] do
        moved =
          Map.merge(
            entry["movements"],
            Map.get(late, entry["property_id"], @no_cash_movements),
            fn _column, ordinary, adjustment -> ordinary + adjustment end
          )

        assert entry["closing_held_cents"] ==
                 entry["opening_held_cents"] + moved["received_cents"] +
                   moved["transferred_in_cents"] - moved["transferred_out_cents"] -
                   moved["refunded_cents"] - moved["retained_cents"] -
                   moved["converted_to_credit_cents"] - moved["reduced_cents"] -
                   moved["charged_back_cents"]
      end
    end

    test "reconcile the day's closing balances with the ledger", %{conn: conn} do
      report = read_daily_report(conn, "2026-11-01")
      ledger = read_ledger(conn, on: "2026-11-01")

      held = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

      assert held == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end
  end

  describe "what a close does not change" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-04", "amount_cents" => 10_000})
      ])

      :ok
    end

    test "leaves the group, the ledger, and the payment statement alone", %{conn: conn} do
      group = read_group(conn, "group-81")
      ledger = read_ledger(conn)
      payment = read_payment(conn, "op-pay")

      submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-31"}))

      assert read_group(conn, "group-81") == group
      assert read_ledger(conn) == ledger
      assert read_payment(conn, "op-pay") == payment
    end

    test "takes a late correction into the current views straight away", %{conn: conn} do
      submit(conn, [
        close_period_op(%{"period_end_on" => "2026-10-31"}),
        reduce_op(%{"occurred_on" => "2026-10-20", "amount_cents" => 2500})
      ])

      assert %{"outstanding_deposit_cents" => 12_000, "cash_paid_cents" => 7500} =
               read_group(conn, "group-81")

      assert %{"cash_held_cents" => 7500, "cash_reduced_cents" => 2500} = read_ledger(conn)
      assert %{"held_cents" => 7500, "reduced_cents" => 2500} = read_payment(conn, "op-pay")

      assert late_movements(read_daily_report(conn, "2026-11-01"))["reduced_cents"] == 2500
    end

    test "still refuses to report a date before reporting started", %{conn: conn} do
      submit_one(conn, close_period_op(%{"period_end_on" => "2026-10-31"}))

      assert conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end
  end

  # Every object key in the order the response body names it.
  defp key_order(body), do: ~r/"([a-z_]+)":/ |> Regex.scan(body) |> Enum.map(&List.last/1)

  defp raw_report(conn, date) do
    conn |> get("/api/v1/finance/daily-report?" <> URI.encode_query(date: date)) |> response(200)
  end

  defp cash(report, property_id \\ "ams-canal"),
    do: Enum.find(report["cash"], &(&1["property_id"] == property_id))

  defp movements(report, property_id \\ "ams-canal"),
    do: cash(report, property_id)["movements"]

  defp late_movements(report, property_id \\ "ams-canal") do
    case Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id)) do
      nil -> @no_cash_movements
      entry -> entry["movements"]
    end
  end
end
