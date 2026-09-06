defmodule GroupStayWeb.DailyReportTest do
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

  describe "reading a day" do
    test "refuses a missing or unusable date", %{conn: conn} do
      submit_one(conn, start_reporting_op())

      for query <- ["", "?date=", "?date=soon", "?date=2026-13-01", "?on=2026-10-04"] do
        assert conn |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
                 %{"error" => %{"code" => "invalid_reporting_date"}}
      end
    end

    test "has nothing to report before reporting starts", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      assert conn |> get("/api/v1/finance/daily-report?date=2026-10-04") |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "has nothing to report for a date before it started", %{conn: conn} do
      submit_one(conn, start_reporting_op(%{"starts_on" => "2026-10-04"}))

      assert conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}

      assert %{"date" => "2026-10-04", "status" => "open"} = read_daily_report(conn, "2026-10-04")
    end

    test "reports a quiet first day with no properties and no credit", %{conn: conn} do
      submit_one(conn, start_reporting_op())

      assert read_daily_report(conn, "2026-10-04") == %{
               "date" => "2026-10-04",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => @no_credit_movements,
                 "closing_liability_cents" => 0
               }
             }
    end
  end

  describe "the opening position" do
    test "carries everything committed before the start operation", %{conn: conn} do
      submit(conn, [
        open_group_op(),
        # Occurs after reporting starts, but is committed before it: opening.
        payment_op(%{
          "operation_id" => "pay-before",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 5000
        }),
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        payment_op(%{
          "operation_id" => "pay-after",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 4000
        })
      ])

      assert cash(read_daily_report(conn, "2026-10-04"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 5000
             }

      assert cash(read_daily_report(conn, "2026-10-05"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5000,
               "movements" => %{@no_cash_movements | "received_cents" => 4000},
               "closing_held_cents" => 9000
             }

      # The day the earlier payment happened to occur on reports nothing.
      assert cash(read_daily_report(conn, "2026-10-20"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 9000,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 9000
             }
    end

    test "carries credit liability as well as cash", %{conn: conn} do
      submit(conn, [
        open_group_op(),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        start_reporting_op(%{"starts_on" => "2026-12-01"})
      ])

      report = read_daily_report(conn, "2026-12-01")

      assert report["cash"] == []

      assert report["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 11_000
             }
    end

    test "posts an operation that occurred before reporting started on the first day",
         %{conn: conn} do
      submit(conn, [
        open_group_op(),
        start_reporting_op(%{"starts_on" => "2026-11-01"}),
        payment_op(%{"occurred_on" => "2026-10-05", "amount_cents" => 5000})
      ])

      assert cash(read_daily_report(conn, "2026-11-01"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{@no_cash_movements | "received_cents" => 5000},
               "closing_held_cents" => 5000
             }
    end
  end

  describe "cash movements" do
    setup %{conn: conn} do
      submit(conn, [start_reporting_op(%{"starts_on" => "2026-10-04"}), open_group_op()])
      :ok
    end

    test "reports a refund on cancellation", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20"})
      ])

      assert cash(read_daily_report(conn, "2026-11-20"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => %{@no_cash_movements | "refunded_cents" => 10_000},
               "closing_held_cents" => 0
             }
    end

    test "adds up everything a property received on one day", %{conn: conn} do
      submit(conn, [
        payment_op(%{
          "operation_id" => "pay-one",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 5000
        }),
        payment_op(%{
          "operation_id" => "pay-two",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 3000
        })
      ])

      assert cash(read_daily_report(conn, "2026-10-05"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{@no_cash_movements | "received_cents" => 8000},
               "closing_held_cents" => 8000
             }
    end

    test "reports settling only some of the rooms", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        cancel_rooms_op(%{"occurred_on" => "2026-11-20", "room_ids" => ["room-a"]})
      ])

      assert cash(read_daily_report(conn, "2026-11-20"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => %{@no_cash_movements | "refunded_cents" => 9000},
               "closing_held_cents" => 1000
             }
    end

    test "reports retained cash on a late cancellation", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-12-01"})
      ])

      assert %{"retained_cents" => 10_000} =
               movements(read_daily_report(conn, "2026-12-01"), "ams-canal")
    end

    test "reports cash converted to credit", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      report = read_daily_report(conn, "2026-11-20")

      assert %{"converted_to_credit_cents" => 10_000} = movements(report, "ams-canal")
      assert cash(report, "ams-canal")["closing_held_cents"] == 0

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{@no_credit_movements | "issued_cents" => 11_000},
               "closing_liability_cents" => 11_000
             }
    end

    test "reports a provider reduction", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        reduce_op(%{"occurred_on" => "2026-10-09", "amount_cents" => 2500})
      ])

      assert cash(read_daily_report(conn, "2026-10-09"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => %{@no_cash_movements | "reduced_cents" => 2500},
               "closing_held_cents" => 7500
             }
    end

    test "reports a chargeback of held cash", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        charge_back_op(%{"occurred_on" => "2026-10-09"})
      ])

      assert cash(read_daily_report(conn, "2026-10-09"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => %{@no_cash_movements | "charged_back_cents" => 10_000},
               "closing_held_cents" => 0
             }
    end

    test "reverses an earlier refund as a negative refund", %{conn: conn} do
      submit(conn, [
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20"}),
        charge_back_op(%{"occurred_on" => "2026-11-25"})
      ])

      assert cash(read_daily_report(conn, "2026-11-25"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 @no_cash_movements
                 | "refunded_cents" => -10_000,
                   "charged_back_cents" => 10_000
               },
               "closing_held_cents" => 0
             }
    end

    test "omits a property that neither held nor moved anything", %{conn: conn} do
      submit(conn, [payment_op(%{"occurred_on" => "2026-10-05", "amount_cents" => 10_000})])

      assert read_daily_report(conn, "2026-10-04")["cash"] == []
      assert [%{"property_id" => "ams-canal"}] = read_daily_report(conn, "2026-10-05")["cash"]
    end
  end

  describe "transfers between properties" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "ber-mitte"
        }),
        payment_op(%{"amount_cents" => 10_000})
      ])

      :ok
    end

    test "leaves one property and arrives at the other", %{conn: conn} do
      submit_one(conn, transfer_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 4000}))

      report = read_daily_report(conn, "2026-10-06")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10_000,
                 "movements" => %{@no_cash_movements | "transferred_out_cents" => 4000},
                 "closing_held_cents" => 6000
               },
               %{
                 "property_id" => "ber-mitte",
                 "opening_held_cents" => 0,
                 "movements" => %{@no_cash_movements | "transferred_in_cents" => 4000},
                 "closing_held_cents" => 4000
               }
             ]
    end

    test "moves the same amount in as out across the day", %{conn: conn} do
      submit(conn, [
        transfer_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 4000}),
        transfer_op(%{
          "operation_id" => "op-transfer-back",
          "occurred_on" => "2026-10-06",
          "source_group_id" => "group-92",
          "destination_group_id" => "group-81",
          "amount_cents" => 1500
        })
      ])

      entries = read_daily_report(conn, "2026-10-06")["cash"]

      assert Enum.map(entries, & &1["movements"]["transferred_in_cents"]) |> Enum.sum() ==
               Enum.map(entries, & &1["movements"]["transferred_out_cents"]) |> Enum.sum()
    end

    test "reverses a settlement at the property that made it", %{conn: conn} do
      submit(conn, [
        transfer_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 5000}),
        cancel_op(%{
          "operation_id" => "op-cancel-92",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-92"
        }),
        charge_back_op(%{"occurred_on" => "2026-11-25"})
      ])

      report = read_daily_report(conn, "2026-11-25")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => %{@no_cash_movements | "charged_back_cents" => 5000},
                 "closing_held_cents" => 0
               },
               %{
                 "property_id" => "ber-mitte",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   @no_cash_movements
                   | "refunded_cents" => -5000,
                     "charged_back_cents" => 5000
                 },
                 "closing_held_cents" => 0
               }
             ]
    end

    test "follows a correction to the property now holding the cash", %{conn: conn} do
      submit(conn, [
        transfer_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 4000}),
        reduce_op(%{"occurred_on" => "2026-10-07", "amount_cents" => 4000})
      ])

      report = read_daily_report(conn, "2026-10-07")

      assert movements(report, "ber-mitte")["reduced_cents"] == 4000
      assert movements(report, "ams-canal")["reduced_cents"] == 0
    end
  end

  describe "credit liability" do
    setup %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"amount_cents" => 10_000}),
        cancel_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        open_group_op(%{
          "operation_id" => "op-open-92",
          "occurred_on" => "2026-11-21",
          "group_id" => "group-92",
          "property_id" => "ber-mitte",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
        })
      ])

      :ok
    end

    test "does not move when credit is applied to a deposit", %{conn: conn} do
      submit_one(
        conn,
        credit_op(%{
          "occurred_on" => "2026-11-22",
          "group_id" => "group-92",
          "amount_cents" => 11_000
        })
      )

      assert read_daily_report(conn, "2026-11-22")["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 11_000
             }
    end

    test "expires a lot the day after it was last available, with no operation", %{conn: conn} do
      assert read_daily_report(conn, "2027-11-20")["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 11_000
             }

      assert read_daily_report(conn, "2027-11-21")["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => %{@no_credit_movements | "expired_cents" => 11_000},
               "closing_liability_cents" => 0
             }

      assert read_daily_report(conn, "2027-11-22")["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 0
             }
    end

    test "consumes applied credit on a non-refundable settlement", %{conn: conn} do
      submit(conn, [
        credit_op(%{
          "occurred_on" => "2026-11-22",
          "group_id" => "group-92",
          "amount_cents" => 11_000
        }),
        cancel_op(%{
          "operation_id" => "op-cancel-92",
          "occurred_on" => "2027-02-20",
          "group_id" => "group-92"
        })
      ])

      assert read_daily_report(conn, "2027-02-20")["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => %{@no_credit_movements | "consumed_cents" => 11_000},
               "closing_liability_cents" => 0
             }
    end

    test "revokes unspent entitlement when the payment behind it is charged back",
         %{conn: conn} do
      submit_one(conn, charge_back_op(%{"occurred_on" => "2026-11-25"}))

      report = read_daily_report(conn, "2026-11-25")

      assert report["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => %{@no_credit_movements | "revoked_cents" => 11_000},
               "closing_liability_cents" => 0
             }

      assert movements(report, "ams-canal") == %{
               @no_cash_movements
               | "converted_to_credit_cents" => -10_000,
                 "charged_back_cents" => 10_000
             }
    end

    test "absorbs a restoration into a lot a chargeback left short", %{conn: conn} do
      submit(conn, [
        credit_op(%{
          "occurred_on" => "2026-11-22",
          "group_id" => "group-92",
          "amount_cents" => 11_000
        }),
        charge_back_op(%{"occurred_on" => "2026-11-25"}),
        cancel_op(%{
          "operation_id" => "op-cancel-92",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-92"
        })
      ])

      assert read_daily_report(conn, "2026-11-25")["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 11_000
             }

      assert read_daily_report(conn, "2026-11-26")["credit"] == %{
               "opening_liability_cents" => 11_000,
               "movements" => %{@no_credit_movements | "absorbed_cents" => 11_000},
               "closing_liability_cents" => 0
             }
    end
  end

  describe "reconciling with the current views" do
    test "closing balances agree with the ledger", %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"amount_cents" => 10_000}),
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
        payment_op(%{
          "operation_id" => "pay-92",
          "occurred_on" => "2026-11-22",
          "group_id" => "group-92",
          "amount_cents" => 1000
        }),
        credit_op(%{
          "occurred_on" => "2026-11-23",
          "group_id" => "group-92",
          "amount_cents" => 11_000
        })
      ])

      report = read_daily_report(conn, "2026-11-23")
      ledger = read_ledger(conn, on: "2026-11-23")

      held = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

      assert held == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end

    test "balances every property's movements against its closing position", %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        open_group_op(%{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "ber-mitte"
        }),
        payment_op(%{"amount_cents" => 10_000}),
        transfer_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 4000}),
        reduce_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 1000}),
        cancel_op(%{"occurred_on" => "2026-11-20"}),
        charge_back_op(%{"occurred_on" => "2026-11-21"})
      ])

      for date <- ["2026-10-04", "2026-10-05", "2026-10-06", "2026-11-20", "2026-11-21"] do
        for entry <- read_daily_report(conn, date)["cash"] do
          moved = entry["movements"]

          assert entry["closing_held_cents"] ==
                   entry["opening_held_cents"] + moved["received_cents"] +
                     moved["transferred_in_cents"] - moved["transferred_out_cents"] -
                     moved["refunded_cents"] - moved["retained_cents"] -
                     moved["converted_to_credit_cents"] - moved["reduced_cents"] -
                     moved["charged_back_cents"]
        end
      end
    end

    test "carries each day's closing position into the next day's opening", %{conn: conn} do
      submit(conn, [
        start_reporting_op(%{"starts_on" => "2026-10-04"}),
        open_group_op(),
        payment_op(%{"occurred_on" => "2026-10-05", "amount_cents" => 10_000}),
        reduce_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 1000})
      ])

      dates = ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"]

      for [today, tomorrow] <- Enum.chunk_every(dates, 2, 1, :discard) do
        closing = closing_held(read_daily_report(conn, today), "ams-canal")
        opening = read_daily_report(conn, tomorrow) |> cash("ams-canal")

        assert closing == (opening && opening["opening_held_cents"]) || closing == 0
      end
    end
  end

  describe "what does not move a report" do
    setup %{conn: conn} do
      submit(conn, [start_reporting_op(%{"starts_on" => "2026-10-04"}), open_group_op()])
      :ok
    end

    test "a rejected operation posts nothing", %{conn: conn} do
      assert %{"status" => "rejected"} =
               submit_one(conn, payment_op(%{"amount_cents" => 99_999}))

      assert read_daily_report(conn, "2026-10-04")["cash"] == []
    end

    test "a later rejection keeps the movements of the applied operations before it",
         %{conn: conn} do
      assert [%{"status" => "applied"}, %{"status" => "rejected"}] =
               submit(conn, [
                 payment_op(%{"amount_cents" => 5000}),
                 payment_op(%{"operation_id" => "pay-too-much", "amount_cents" => 99_999})
               ])["results"]

      assert movements(read_daily_report(conn, "2026-10-04"), "ams-canal")["received_cents"] ==
               5000
    end

    test "a durable retry posts nothing a second time", %{conn: conn} do
      submit_one(conn, payment_op(%{"amount_cents" => 5000}))
      submit_one(conn, payment_op(%{"amount_cents" => 5000}))
      submit_one(conn, payment_op(%{"amount_cents" => 5000}))

      assert movements(read_daily_report(conn, "2026-10-04"), "ams-canal")["received_cents"] ==
               5000
    end

    test "reading a report leaves the report and the domain alone", %{conn: conn} do
      submit_one(conn, payment_op(%{"amount_cents" => 5000}))

      first = read_daily_report(conn, "2026-10-04")
      group = read_group(conn, "group-81")

      for date <- ["2026-11-01", "2026-10-04", "2026-10-05", "2026-10-04"] do
        read_daily_report(conn, date)
      end

      assert read_daily_report(conn, "2026-10-04") == first
      assert read_group(conn, "group-81") == group
    end
  end

  test "a batch and the same operations submitted one at a time report the same day",
       %{conn: conn} do
    submit_one(conn, start_reporting_op(%{"starts_on" => "2026-10-04"}))

    batched = funding_operations("batched", "hotel-batched")
    submit(conn, batched)

    for operation <- funding_operations("apart", "hotel-apart") do
      submit_one(conn, operation)
    end

    assert without_property(read_daily_report(conn, "2026-10-05"), "hotel-batched") ==
             without_property(read_daily_report(conn, "2026-10-05"), "hotel-apart")
  end

  # The same funding, told twice, against a property and identifiers of its own.
  defp funding_operations(suffix, property_id) do
    [
      open_group_op(%{
        "operation_id" => "open-#{suffix}",
        "group_id" => "group-#{suffix}",
        "property_id" => property_id
      }),
      payment_op(%{
        "operation_id" => "pay-#{suffix}",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-#{suffix}",
        "amount_cents" => 10_000
      }),
      reduce_op(%{
        "operation_id" => "reduce-#{suffix}",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "pay-#{suffix}",
        "amount_cents" => 2000
      })
    ]
  end

  defp without_property(report, property_id),
    do: report |> cash(property_id) |> Map.delete("property_id")

  defp cash(report, property_id),
    do: Enum.find(report["cash"], &(&1["property_id"] == property_id))

  defp movements(report, property_id), do: cash(report, property_id)["movements"]

  defp closing_held(report, property_id) do
    case cash(report, property_id) do
      nil -> 0
      entry -> entry["closing_held_cents"]
    end
  end
end
