defmodule GroupStayWeb.FinanceDailyReportControllerTest do
  use GroupStayWeb.ConnCase

  test "starts from the committed opening position and posts later same-batch operations", %{
    conn: conn
  } do
    opening_group = open_group_operation("open-opening", "opening-group", "2026-10-03")

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          opening_group,
          cash_payment("pay-before-reporting", "opening-group", "2026-10-03", 1_000)
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    start = %{
      "operation_id" => "start-finance-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-02"
    }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          start,
          cash_payment("pay-after-reporting", "opening-group", "2026-10-01", 500)
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "start-finance-reporting",
               "status" => "applied",
               "starts_on" => "2026-10-02"
             },
             %{
               "operation_id" => "pay-after-reporting",
               "status" => "applied",
               "group_id" => "opening-group",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 4_500,
               "revision" => 3
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-02")

    assert json_response(conn, 200) == %{
             "data" => %{
               "date" => "2026-10-02",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "movements" => %{
                     "received_cents" => 500,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 1_500
                 }
               ],
               "credit" => credit_entry(0, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [start]})

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "start-finance-reporting",
               "status" => "applied",
               "starts_on" => "2026-10-02"
             }
           ]

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "second-finance-start",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-10-03"
          },
          %{
            "operation_id" => "invalid-finance-start",
            "type" => "start_finance_reporting",
            "starts_on" => "not-a-date"
          }
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "second-finance-start",
               "status" => "rejected",
               "code" => "reporting_already_started"
             },
             %{
               "operation_id" => "invalid-finance-start",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }
           ]
  end

  test "reports transfers, settlement at the holding property, and a chargeback reversal", %{
    conn: conn
  } do
    source =
      open_group_operation("open-source", "source", "2026-10-01", %{"property_id" => "ams"})

    destination =
      open_group_operation("open-destination", "destination", "2026-10-01", %{
        "property_id" => "nyc",
        "guest_id" => "guest-1"
      })

    start = %{
      "operation_id" => "start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-01"
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          start,
          source,
          cash_payment("source-payment", "source", "2026-10-02", 1_000),
          destination,
          cash_payment("destination-payment", "destination", "2026-10-02", 500),
          %{
            "operation_id" => "transfer-cash",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-03",
            "source_group_id" => "source",
            "destination_group_id" => "destination",
            "amount_cents" => 400,
            "expected_revision" => 2,
            "destination_expected_revision" => 2
          },
          %{
            "operation_id" => "refund-destination",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "destination",
            "expected_revision" => 3
          },
          %{
            "operation_id" => "charge-back-destination-payment",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "destination-payment",
            "expected_revision" => 4
          }
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn = get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")
    transfer_report = json_response(conn, 200)["data"]

    assert transfer_report["cash"] == [
             cash_entry("ams", 1_000, %{"transferred_out_cents" => 400}, 600),
             cash_entry("nyc", 500, %{"transferred_in_cents" => 400}, 900)
           ]

    conn = get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-05")
    chargeback_report = json_response(conn, 200)["data"]

    assert chargeback_report["cash"] == [
             cash_entry("ams", 600, %{}, 600),
             cash_entry(
               "nyc",
               0,
               %{"refunded_cents" => -500, "charged_back_cents" => 500},
               0
             )
           ]
  end

  test "reports calendar expiry without a partner operation and reads are side-effect free", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "start-expiry-reporting",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-10-01"
          },
          open_group_operation("open-credit-source", "credit-source", "2026-10-02"),
          cash_payment("cash-for-credit", "credit-source", "2026-10-02", 1_000),
          %{
            "operation_id" => "convert-cash-to-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "credit-source",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          }
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn = get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")

    assert json_response(conn, 200)["data"]["credit"] ==
             credit_entry(0, 1_100, %{"issued_cents" => 1_100})

    path = ~p"/api/v1/finance/daily-report?date=2027-10-04"
    first = get(build_conn(), path) |> json_response(200)
    second = get(build_conn(), path) |> json_response(200)

    assert first == second

    assert first == %{
             "data" => %{
               "date" => "2027-10-04",
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(1_100, 0, %{"expired_cents" => 1_100}),
               "late_adjustments" => late_adjustments()
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger?on=2027-10-04")
    assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
  end

  test "validates report dates and availability", %{conn: conn} do
    assert get(conn, ~p"/api/v1/finance/daily-report") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=not-a-date")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "start-for-availability",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-10-02"
          }
        ]
      })

    assert json_response(conn, 200)["results"] |> hd() |> Map.fetch!("status") == "applied"

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "closes reporting periods sequentially and preserves durable close outcomes", %{conn: conn} do
    close_before_start = close_period("close-before-start", "2026-10-01")

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [close_before_start]})

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "close-before-start",
               "status" => "rejected",
               "code" => "invalid_period"
             }
           ]

    start = %{
      "operation_id" => "start-for-close",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-02"
    }

    close = close_period("close-first-day", "2026-10-02")

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [start, close]})

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "start-for-close",
               "status" => "applied",
               "starts_on" => "2026-10-02"
             },
             %{
               "operation_id" => "close-first-day",
               "status" => "applied",
               "period_end_on" => "2026-10-02"
             }
           ]

    assert post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [close]})
           |> json_response(200) ==
             %{
               "results" => [
                 %{
                   "operation_id" => "close-first-day",
                   "status" => "applied",
                   "period_end_on" => "2026-10-02"
                 }
               ]
             }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          close_period("close-duplicate-day", "2026-10-02"),
          close_period("close-before-starts-on", "2026-10-01"),
          close_period("close-invalid-date", "not-a-date")
        ]
      })

    assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) == [
             "invalid_period",
             "invalid_period",
             "invalid_period"
           ]

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-02")
           |> json_response(200) ==
             %{
               "data" => %{
                 "date" => "2026-10-02",
                 "status" => "closed",
                 "cash" => [],
                 "credit" => credit_entry(0, 0),
                 "late_adjustments" => late_adjustments()
               }
             }
  end

  test "freezes closed days and posts old-dated cash into the first open day as a late adjustment",
       %{
         conn: conn
       } do
    start = %{
      "operation_id" => "start-freeze-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-01"
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          start,
          open_group_operation("open-freeze-group", "freeze-group", "2026-10-01"),
          cash_payment("pay-before-close", "freeze-group", "2026-10-02", 1_000),
          close_period("close-through-october-second", "2026-10-02")
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    closed_path = ~p"/api/v1/finance/daily-report?date=2026-10-02"
    closed_before = get(build_conn(), closed_path) |> json_response(200)

    assert closed_before == %{
             "data" => %{
               "date" => "2026-10-02",
               "status" => "closed",
               "cash" => [cash_entry("ams-canal", 0, %{"received_cents" => 1_000}, 1_000)],
               "credit" => credit_entry(0, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [cash_payment("pay-after-close", "freeze-group", "2026-10-02", 500)]
      })

    assert json_response(conn, 200)["results"] == [
             %{
               "operation_id" => "pay-after-close",
               "status" => "applied",
               "group_id" => "freeze-group",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 4_500,
               "revision" => 3
             }
           ]

    assert get(build_conn(), closed_path) |> json_response(200) == closed_before

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")
           |> json_response(200) ==
             %{
               "data" => %{
                 "date" => "2026-10-03",
                 "status" => "open",
                 "cash" => [cash_entry("ams-canal", 1_000, %{}, 1_500)],
                 "credit" => credit_entry(0, 0),
                 "late_adjustments" =>
                   late_adjustments([
                     late_cash_entry("ams-canal", %{"received_cents" => 500})
                   ])
               }
             }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [close_period("close-through-october-third", "2026-10-03")]
      })

    assert json_response(conn, 200)["results"] |> hd() |> Map.fetch!("status") == "applied"
    assert get(build_conn(), closed_path) |> json_response(200) == closed_before

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")
           |> json_response(200)
           |> get_in(["data", "status"]) == "closed"
  end

  test "marks every finance effect of a late hotel-credit conversion", %{conn: conn} do
    start = %{
      "operation_id" => "start-late-credit-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-01"
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          start,
          open_group_operation("open-late-credit-group", "late-credit-group", "2026-10-01"),
          cash_payment("pay-late-credit-group", "late-credit-group", "2026-10-02", 1_000),
          close_period("close-before-late-credit", "2026-10-02")
        ]
      })

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "late-credit-conversion",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-02",
            "group_id" => "late-credit-group",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          }
        ]
      })

    assert json_response(conn, 200)["results"]
           |> hd()
           |> Map.take([
             "operation_id",
             "status",
             "credit_issued_cents"
           ]) ==
             %{
               "operation_id" => "late-credit-conversion",
               "status" => "applied",
               "credit_issued_cents" => 1_100
             }

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-10-03")
           |> json_response(200) ==
             %{
               "data" => %{
                 "date" => "2026-10-03",
                 "status" => "open",
                 "cash" => [cash_entry("ams-canal", 1_000, %{}, 0)],
                 "credit" => credit_entry(0, 1_100),
                 "late_adjustments" =>
                   late_adjustments(
                     [
                       late_cash_entry(
                         "ams-canal",
                         %{"converted_to_credit_cents" => 1_000}
                       )
                     ],
                     %{"issued_cents" => 1_100}
                   )
               }
             }
  end

  defp cash_payment(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp close_period(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_group_operation(operation_id, group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp cash_entry(property_id, opening, movement_overrides, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" =>
        Map.merge(
          %{
            "received_cents" => 0,
            "transferred_in_cents" => 0,
            "transferred_out_cents" => 0,
            "refunded_cents" => 0,
            "retained_cents" => 0,
            "converted_to_credit_cents" => 0,
            "reduced_cents" => 0,
            "charged_back_cents" => 0
          },
          movement_overrides
        ),
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, closing, movement_overrides \\ %{}) do
    %{
      "opening_liability_cents" => opening,
      "movements" =>
        Map.merge(
          %{
            "issued_cents" => 0,
            "expired_cents" => 0,
            "consumed_cents" => 0,
            "revoked_cents" => 0,
            "absorbed_cents" => 0
          },
          movement_overrides
        ),
      "closing_liability_cents" => closing
    }
  end

  defp late_cash_entry(property_id, movement_overrides) do
    %{
      "property_id" => property_id,
      "movements" =>
        Map.merge(
          %{
            "received_cents" => 0,
            "transferred_in_cents" => 0,
            "transferred_out_cents" => 0,
            "refunded_cents" => 0,
            "retained_cents" => 0,
            "converted_to_credit_cents" => 0,
            "reduced_cents" => 0,
            "charged_back_cents" => 0
          },
          movement_overrides
        )
    }
  end

  defp late_adjustments(cash \\ [], credit_overrides \\ %{}) do
    %{
      "cash" => cash,
      "credit" =>
        Map.merge(
          %{
            "issued_cents" => 0,
            "expired_cents" => 0,
            "consumed_cents" => 0,
            "revoked_cents" => 0,
            "absorbed_cents" => 0
          },
          credit_overrides
        )
    }
  end
end
