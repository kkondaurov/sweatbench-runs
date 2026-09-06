defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

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

  describe "closing a period" do
    test "the applied result contains exactly the operation, its status, and the cutoff" do
      submit_one(start_finance_reporting())

      assert submit_one(close_finance_period()) == %{
               "operation_id" => "op-close-period",
               "status" => "applied",
               "period_end_on" => "2026-10-31"
             }
    end

    test "a close is rejected before reporting has started" do
      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(close_finance_period())
    end

    test "a cutoff before the reporting start date is rejected" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-05"}))

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(close_finance_period(%{"period_end_on" => "2026-10-04"}))

      assert %{"status" => "applied"} =
               submit_one(
                 close_finance_period(%{
                   "operation_id" => "op-close-first-day",
                   "period_end_on" => "2026-10-05"
                 })
               )
    end

    test "a cutoff that does not move the published period forward is rejected" do
      submit([start_finance_reporting(), close_finance_period()])

      for period_end_on <- ["2026-10-31", "2026-10-30", "2026-10-01"] do
        assert %{"status" => "rejected", "code" => "invalid_period"} =
                 submit_one(
                   close_finance_period(%{
                     "operation_id" => "op-close-" <> period_end_on,
                     "period_end_on" => period_end_on
                   })
                 )
      end

      assert %{"status" => "applied"} =
               submit_one(
                 close_finance_period(%{
                   "operation_id" => "op-close-november",
                   "period_end_on" => "2026-11-01"
                 })
               )
    end

    test "an unusable cutoff is rejected" do
      submit_one(start_finance_reporting())

      for period_end_on <- ["", "not-a-date", "2026-13-01", 20_261_031, nil] do
        assert %{"status" => "rejected", "code" => "invalid_period"} =
                 submit_one(
                   close_finance_period(%{
                     "operation_id" => "op-close-#{inspect(period_end_on)}",
                     "period_end_on" => period_end_on
                   })
                 )
      end
    end

    test "a missing cutoff is rejected" do
      submit_one(start_finance_reporting())

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(Map.delete(close_finance_period(), "period_end_on"))
    end

    test "a rejected close publishes nothing" do
      submit_one(start_finance_reporting())
      submit_one(close_finance_period(%{"period_end_on" => "nope"}))

      assert daily_report("2026-10-01")["status"] == "open"
    end

    test "a retry returns the stored result and does not close again" do
      submit_one(start_finance_reporting())
      first = submit_one(close_finance_period())

      assert submit_one(close_finance_period()) == first
      assert {200, %{"data" => stored}} = read_operation("op-close-period")
      assert stored == first
    end

    test "reusing the identifier with a different cutoff conflicts" do
      submit([start_finance_reporting(), close_finance_period()])

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(close_finance_period(%{"period_end_on" => "2026-11-30"}))
    end

    test "a close does not address a group and takes no revision guard" do
      submit([open_group(), start_finance_reporting()])

      assert %{"status" => "applied"} =
               submit_one(close_finance_period(%{"expected_revision" => 99}))
    end
  end

  describe "publishing reports" do
    setup do
      submit([open_group(), start_finance_reporting(%{"starts_on" => "2026-10-01"})])
      :ok
    end

    test "every day through the cutoff is closed and later days stay open" do
      submit_one(close_finance_period(%{"period_end_on" => "2026-10-31"}))

      for date <- ["2026-10-01", "2026-10-15", "2026-10-31"] do
        assert daily_report(date)["status"] == "closed"
      end

      for date <- ["2026-11-01", "2027-01-01"] do
        assert daily_report(date)["status"] == "open"
      end
    end

    test "a later close publishes further days" do
      submit_one(close_finance_period(%{"period_end_on" => "2026-10-31"}))
      assert daily_report("2026-11-15")["status"] == "open"

      submit_one(
        close_finance_period(%{
          "operation_id" => "op-close-november",
          "period_end_on" => "2026-11-30"
        })
      )

      assert daily_report("2026-11-15")["status"] == "closed"
      assert daily_report("2026-12-01")["status"] == "open"
    end

    test "a day before reporting started is still unavailable after a close" do
      submit_one(close_finance_period(%{"period_end_on" => "2026-10-31"}))

      assert {404, %{"error" => %{"code" => "report_not_available"}}} =
               read_daily_report("2026-09-30")
    end
  end

  describe "posting after a close" do
    setup do
      submit([open_group(), start_finance_reporting(%{"starts_on" => "2026-10-01"})])
      submit_one(close_finance_period(%{"period_end_on" => "2026-10-31"}))
      :ok
    end

    test "an operation dated inside the closed period posts on the first open day" do
      submit_one(pay("op-pay-late", "2026-10-10", 500))

      # The closed day the payment happened on says nothing at all about it.
      assert property_cash("2026-10-10", "ams-canal") == nil

      assert late_cash("2026-11-01", "ams-canal") ==
               %{@no_cash_movements | "received_cents" => 500}
    end

    test "an operation dated in the open period keeps its own date" do
      submit_one(pay("op-pay-open", "2026-11-20", 500))

      assert property_cash("2026-11-20", "ams-canal")["movements"] ==
               %{@no_cash_movements | "received_cents" => 500}

      assert late_cash("2026-11-20", "ams-canal") == nil
    end

    test "an operation dated on the first open day is not a late adjustment" do
      submit_one(pay("op-pay-boundary", "2026-11-01", 500))

      assert property_cash("2026-11-01", "ams-canal")["movements"] ==
               %{@no_cash_movements | "received_cents" => 500}

      assert late_cash("2026-11-01", "ams-canal") == nil
    end

    test "an operation before a close posts into the period it closes, one after it does not" do
      submit([
        pay("op-pay-before", "2026-11-10", 500),
        close_finance_period(%{
          "operation_id" => "op-close-november",
          "period_end_on" => "2026-11-30"
        }),
        pay("op-pay-after", "2026-11-10", 500)
      ])

      assert daily_report("2026-11-10")["status"] == "closed"

      assert property_cash("2026-11-10", "ams-canal")["movements"] ==
               %{@no_cash_movements | "received_cents" => 500}

      assert late_cash("2026-12-01", "ams-canal") ==
               %{@no_cash_movements | "received_cents" => 500}
    end

    test "a later close never moves a posting that has already been chosen" do
      submit_one(pay("op-pay-late", "2026-10-10", 500))

      before = daily_report("2026-11-01")

      submit_one(
        close_finance_period(%{
          "operation_id" => "op-close-november",
          "period_end_on" => "2026-11-30"
        })
      )

      assert daily_report("2026-11-01") == %{before | "status" => "closed"}
    end
  end

  describe "late adjustments" do
    setup do
      submit([open_group(), start_finance_reporting(%{"starts_on" => "2026-10-01"})])
      :ok
    end

    test "the block is present on every report and is empty without a close" do
      submit_one(pay("op-pay-1", "2026-10-10", 500))

      assert daily_report("2026-10-10")["late_adjustments"] ==
               %{"cash" => [], "credit" => @no_credit_movements}
    end

    test "the day's total movement is the ordinary value plus the late one" do
      submit_one(close_finance_period())
      submit([pay("op-pay-open", "2026-11-01", 700), pay("op-pay-late", "2026-10-10", 500)])

      entry = property_cash("2026-11-01", "ams-canal")

      assert entry["movements"] == %{@no_cash_movements | "received_cents" => 700}

      assert late_cash("2026-11-01", "ams-canal") ==
               %{@no_cash_movements | "received_cents" => 500}

      assert entry["opening_held_cents"] == 0
      assert entry["closing_held_cents"] == 1_200
    end

    test "opening and closing balances count the late movements of earlier days" do
      submit_one(close_finance_period())
      submit_one(pay("op-pay-late", "2026-10-10", 500))

      assert property_cash("2026-11-01", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 500
             }

      assert property_cash("2026-11-02", "ams-canal")["opening_held_cents"] == 500
    end

    test "late adjustments are ordered by property and leave out quiet properties" do
      submit([
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "zrh-lake"
        }),
        open_group(%{
          "operation_id" => "op-open-3",
          "group_id" => "group-93",
          "property_id" => "ber-mitte"
        }),
        close_finance_period()
      ])

      submit([
        pay("op-pay-zrh", "2026-10-10", 500, "group-92"),
        pay("op-pay-ber", "2026-10-10", 300, "group-93")
      ])

      late = daily_report("2026-11-01")["late_adjustments"]["cash"]

      assert Enum.map(late, & &1["property_id"]) == ["ber-mitte", "zrh-lake"]
      assert Enum.map(late, & &1["movements"]["received_cents"]) == [300, 500]
    end

    test "a classification that nets to nothing is still stated on both sides" do
      submit([
        pay("op-pay", "2026-10-04", 1_000),
        cancel_group(%{"occurred_on" => "2026-10-06"}),
        close_finance_period()
      ])

      submit_one(charge_back_payment(%{"occurred_on" => "2026-10-07"}))

      assert property_cash("2026-11-01", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 0
             }

      assert late_cash("2026-11-01", "ams-canal") == %{
               @no_cash_movements
               | "refunded_cents" => -1_000,
                 "charged_back_cents" => 1_000
             }
    end

    test "credit issued into the open period is a late credit adjustment" do
      submit([
        pay("op-pay", "2026-10-04", 1_000),
        close_finance_period()
      ])

      submit_one(
        cancel_group(%{"occurred_on" => "2026-10-06", "refund_method" => "hotel_credit"})
      )

      report = daily_report("2026-11-01")

      assert report["credit"]["movements"] == @no_credit_movements

      assert report["late_adjustments"]["credit"] == %{
               @no_credit_movements
               | "issued_cents" => 1_100
             }

      assert report["credit"]["closing_liability_cents"] == 1_100
    end
  end

  describe "published reports never move" do
    test "a closed day is byte for byte the same after later operations and later closes" do
      submit([
        open_group(),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "zrh-lake"
        }),
        start_finance_reporting(%{"starts_on" => "2026-10-01"})
      ])

      submit([
        pay("op-pay-1", "2026-10-04", 1_000),
        pay("op-pay-2", "2026-10-05", 800, "group-92"),
        cancel_group(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-20",
          "refund_method" => "hotel_credit"
        }),
        close_finance_period(%{"period_end_on" => "2026-10-31"})
      ])

      published =
        Map.new(Date.range(~D[2026-10-01], ~D[2026-10-31]), fn date ->
          {date, daily_report_body(Date.to_iso8601(date))}
        end)

      # Every kind of finance effect the service has, all of it dated inside the closed period.
      submit([
        pay("op-pay-3", "2026-10-06", 500),
        reduce_cash_payment(%{
          "occurred_on" => "2026-10-07",
          "payment_operation_id" => "op-pay-1"
        }),
        apply_hotel_credit(%{
          "operation_id" => "op-apply",
          "occurred_on" => "2026-10-25",
          "amount_cents" => 880
        }),
        charge_back_payment(%{
          "occurred_on" => "2026-10-26",
          "payment_operation_id" => "op-pay-2"
        }),
        cancel_group(%{"occurred_on" => "2026-10-28"}),
        close_finance_period(%{
          "operation_id" => "op-close-november",
          "period_end_on" => "2026-11-30"
        })
      ])

      for {date, body} <- published do
        assert daily_report_body(Date.to_iso8601(date)) == body
      end
    end

    test "reading a published report repeatedly changes nothing" do
      submit([open_group(), start_finance_reporting(), pay("op-pay-1", "2026-10-04", 1_000)])
      submit_one(close_finance_period())

      body = daily_report_body("2026-10-04")

      assert daily_report_body("2026-10-04") == body
      assert daily_report_body("2026-10-04") == body
      assert read_ledger()["cash_held_cents"] == 1_000
    end
  end

  describe "credit across a close" do
    test "an expiry a close pushed into the open period is a late adjustment" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      issue_credit(group_id: "group-credit", cash_cents: 1_000, operation_id: "op-issue")
      open_credit_group("group-b")

      submit_one(
        apply_hotel_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-b",
          "occurred_on" => "2026-12-01",
          "amount_cents" => 1_100
        })
      )

      submit_one(
        close_finance_period(%{"occurred_on" => "2028-02-01", "period_end_on" => "2028-01-31"})
      )

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2026-12-05"
        })
      )

      report = daily_report("2028-02-01")

      assert report["credit"]["opening_liability_cents"] == 1_100
      assert report["credit"]["movements"] == @no_credit_movements

      assert report["late_adjustments"]["credit"] ==
               %{@no_credit_movements | "expired_cents" => 1_100}

      assert report["credit"]["closing_liability_cents"] == 1_100 - 1_100
      assert read_ledger(%{"on" => "2028-02-01"})["credit_liability_cents"] == 0
    end

    test "credit redeemed after the report expired its lot comes back into the liability" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      issue_credit(group_id: "group-credit", cash_cents: 1_000, operation_id: "op-issue")

      assert daily_report("2027-11-27")["credit"]["movements"]["expired_cents"] == 1_100

      submit_one(
        close_finance_period(%{"occurred_on" => "2028-02-01", "period_end_on" => "2028-01-31"})
      )

      open_credit_group("group-b")

      submit_one(
        apply_hotel_credit(%{
          "operation_id" => "op-apply",
          "group_id" => "group-b",
          "occurred_on" => "2027-11-20",
          "amount_cents" => 1_100
        })
      )

      report = daily_report("2028-02-01")

      assert report["credit"]["opening_liability_cents"] == 0

      assert report["late_adjustments"]["credit"] ==
               %{@no_credit_movements | "expired_cents" => -1_100}

      assert report["credit"]["closing_liability_cents"] == 1_100
      assert read_ledger(%{"on" => "2028-02-01"})["credit_liability_cents"] == 1_100
    end
  end

  describe "reconciling a closed service" do
    test "the reports still add up to the ledger once corrections arrive late" do
      submit([
        open_group(),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "zrh-lake"
        }),
        start_finance_reporting(%{"starts_on" => "2026-10-01"})
      ])

      submit([
        pay("op-pay-1", "2026-10-04", 1_000),
        pay("op-pay-2", "2026-10-05", 800, "group-92"),
        close_finance_period()
      ])

      submit([
        transfer_deposit(%{"occurred_on" => "2026-10-06", "amount_cents" => 400}),
        reduce_cash_payment(%{
          "occurred_on" => "2026-10-06",
          "payment_operation_id" => "op-pay-2",
          "amount_cents" => 300
        })
      ])

      report = daily_report("2026-11-01")
      assert_balanced(report)

      assert closing_held(report) == read_ledger()["cash_held_cents"]
      assert closing_held(report) == 1_000 + 800 - 300
    end
  end

  # A payment of the fixture group unless another group is named.
  defp pay(operation_id, occurred_on, amount_cents, group_id \\ "group-81") do
    record_cash_payment(%{
      "operation_id" => operation_id,
      "group_id" => group_id,
      "occurred_on" => occurred_on,
      "amount_cents" => amount_cents
    })
  end

  # The late adjustment reported for one property on a date, or `nil` when it has none.
  defp late_cash(date, property_id) do
    entry =
      date
      |> daily_report()
      |> get_in(["late_adjustments", "cash"])
      |> Enum.find(&(&1["property_id"] == property_id))

    entry && entry["movements"]
  end

  # A flexible group of the credit-holding guest with room enough to take the whole lot.
  defp open_credit_group(group_id) do
    submit_one(
      open_group(%{
        "operation_id" => "op-open-" <> group_id,
        "group_id" => group_id,
        "property_id" => "par-rive",
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-11",
        "rooms" => [room("room-a", 10_000)]
      })
    )
  end

  defp closing_held(report),
    do: Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"]))

  # Every property's day adds up out of its ordinary movements and its late adjustments together,
  # and cash only ever moves between properties, never in or out of the report as a whole.
  defp assert_balanced(report) do
    late = Map.new(report["late_adjustments"]["cash"], &{&1["property_id"], &1["movements"]})

    for entry <- report["cash"] do
      moved = total_movements(entry["movements"], Map.get(late, entry["property_id"]))

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + moved["received_cents"] +
                 moved["transferred_in_cents"] - moved["transferred_out_cents"] -
                 moved["refunded_cents"] - moved["retained_cents"] -
                 moved["converted_to_credit_cents"] - moved["reduced_cents"] -
                 moved["charged_back_cents"]
    end

    totals =
      for entry <- report["cash"],
          reduce: @no_cash_movements do
        acc ->
          moved = total_movements(entry["movements"], Map.get(late, entry["property_id"]))
          Map.new(acc, fn {kind, cents} -> {kind, cents + moved[kind]} end)
      end

    assert totals["transferred_in_cents"] == totals["transferred_out_cents"]

    credit = report["credit"]
    moved = total_movements(credit["movements"], report["late_adjustments"]["credit"])

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + moved["issued_cents"] - moved["expired_cents"] -
               moved["consumed_cents"] - moved["revoked_cents"] - moved["absorbed_cents"]
  end

  defp total_movements(movements, nil), do: movements

  defp total_movements(movements, late),
    do: Map.new(movements, fn {kind, cents} -> {kind, cents + late[kind]} end)
end
