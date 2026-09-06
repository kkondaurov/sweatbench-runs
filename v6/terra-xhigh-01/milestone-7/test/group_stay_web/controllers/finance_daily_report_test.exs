defmodule GroupStayWeb.FinanceDailyReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts reporting from the committed opening position and enforces its durable inception",
       %{
         conn: conn
       } do
    assert get(conn, "/api/v1/finance/daily-report") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert get(conn, "/api/v1/finance/daily-report?date=bad") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-01") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert submit(conn, [
             %{"operation_id" => "missing-start-date", "type" => "start_finance_reporting"}
           ])["results"] == [
             %{
               "operation_id" => "missing-start-date",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }
           ]

    response =
      submit(conn, [
        open_operation("opening"),
        cash_operation("opening-cash", "opening", 1_000, "2026-10-03"),
        %{
          "operation_id" => "start-reporting",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-10-05"
        },
        cash_operation("same-batch-cash", "opening", 500, "2026-10-05")
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-10-05"
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-04") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [cash_report("ams-canal", 1_000, %{received_cents: 500}, 1_500)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    assert submit(conn, [
             %{
               "operation_id" => "start-reporting",
               "type" => "start_finance_reporting",
               "starts_on" => "2026-10-05"
             },
             %{
               "operation_id" => "second-start",
               "type" => "start_finance_reporting",
               "starts_on" => "2026-10-06"
             },
             %{
               "operation_id" => "bad-start",
               "type" => "start_finance_reporting",
               "starts_on" => "nope"
             }
           ])["results"] == [
             %{
               "operation_id" => "start-reporting",
               "status" => "applied",
               "starts_on" => "2026-10-05"
             },
             %{
               "operation_id" => "second-start",
               "status" => "rejected",
               "code" => "reporting_already_started"
             },
             %{
               "operation_id" => "bad-start",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }
           ]
  end

  test "reports cash received, moved between properties, reduced, and charged back in posting-date order",
       %{conn: conn} do
    response =
      submit(conn, [
        %{
          "operation_id" => "start-reporting",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-10-01"
        },
        open_operation("source", property_id: "ams-canal", room_rate: 10_000),
        open_operation("destination", property_id: "lon-river", room_rate: 10_000),
        cash_operation("payment", "source", 1_000, "2026-10-02"),
        %{
          "operation_id" => "move-cash",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-03",
          "source_group_id" => "source",
          "destination_group_id" => "destination",
          "amount_cents" => 600
        },
        %{
          "operation_id" => "reduce-cash",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-04",
          "payment_operation_id" => "payment",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "charge-back-cash",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "payment"
        }
      ])

    assert Enum.map(response["results"], & &1["status"]) == [
             "applied",
             "applied",
             "applied",
             "applied",
             "applied",
             "applied",
             "applied"
           ]

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [
                 cash_report(
                   "ams-canal",
                   1_000,
                   %{transferred_out_cents: 600},
                   400
                 ),
                 cash_report("lon-river", 0, %{transferred_in_cents: 600}, 600)
               ],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-04",
               "status" => "open",
               "cash" => [
                 cash_report("ams-canal", 400, %{}, 400),
                 cash_report("lon-river", 600, %{reduced_cents: 100}, 500)
               ],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 cash_report("ams-canal", 400, %{charged_back_cents: 400}, 0),
                 cash_report("lon-river", 500, %{charged_back_cents: 500}, 0)
               ],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }
  end

  test "reports cash-refund reversals once and does not duplicate a durable payment retry", %{
    conn: conn
  } do
    submit(conn, [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("refundable"),
      cash_operation("payment", "refundable", 1_000, "2026-10-02"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "refundable"
      },
      %{
        "operation_id" => "charge-back",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-04",
        "payment_operation_id" => "payment"
      }
    ])

    assert submit(conn, [cash_operation("payment", "refundable", 1_000, "2026-10-02")])["results"] ==
             [
               %{
                 "operation_id" => "payment",
                 "status" => "applied",
                 "group_id" => "refundable",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 8_000,
                 "revision" => 2
               }
             ]

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-04",
               "status" => "open",
               "cash" => [
                 cash_report(
                   "ams-canal",
                   0,
                   %{refunded_cents: -1_000, charged_back_cents: 1_000},
                   0
                 )
               ],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [cash_report("ams-canal", 1_000, %{refunded_cents: 1_000}, 0)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }
  end

  test "reports issued credit and its automatic expiry without mutating the report", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("credit-source"),
      cash_operation("payment", "credit-source", 1_000, "2026-10-02"),
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      }
    ])

    expected_expiry_report = %{
      "data" => %{
        "date" => "2027-10-04",
        "status" => "open",
        "cash" => [],
        "credit" => credit_report(1_100, %{expired_cents: 1_100}, 0),
        "late_adjustments" => late_adjustments()
      }
    }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [
                 cash_report("ams-canal", 1_000, %{converted_to_credit_cents: 1_000}, 0)
               ],
               "credit" => credit_report(0, %{issued_cents: 1_100}, 1_100),
               "late_adjustments" => late_adjustments()
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2027-10-04") |> json_response(200) ==
             expected_expiry_report

    assert get(conn, "/api/v1/finance/daily-report?date=2027-10-04") |> json_response(200) ==
             expected_expiry_report
  end

  test "keeps applied credit through expiry and reports consumption only when it is settled", %{
    conn: conn
  } do
    submit(conn, [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("credit-source"),
      cash_operation("payment", "credit-source", 1_000, "2026-10-02"),
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-destination"),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-destination",
        "amount_cents" => 1_100
      }
    ])

    assert get(conn, "/api/v1/finance/daily-report?date=2027-10-04") |> json_response(200) == %{
             "data" => %{
               "date" => "2027-10-04",
               "status" => "open",
               "cash" => [],
               "credit" => credit_report(1_100, %{}, 1_100),
               "late_adjustments" => late_adjustments()
             }
           }

    submit(conn, [
      %{
        "operation_id" => "consume-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "credit-destination"
      }
    ])

    assert get(conn, "/api/v1/finance/daily-report?date=2026-12-01") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-12-01",
               "status" => "open",
               "cash" => [],
               "credit" => credit_report(1_100, %{consumed_cents: 1_100}, 0),
               "late_adjustments" => late_adjustments()
             }
           }
  end

  test "reports shortfall absorption when a clawed-back credit payment is restored", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("credit-source"),
      cash_operation("payment", "credit-source", 1_000, "2026-10-02"),
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-destination"),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-destination",
        "amount_cents" => 1_100
      },
      %{
        "operation_id" => "charge-back",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "payment"
      },
      %{
        "operation_id" => "restore-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-06",
        "group_id" => "credit-destination"
      }
    ])

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 cash_report(
                   "ams-canal",
                   0,
                   %{converted_to_credit_cents: -1_000, charged_back_cents: 1_000},
                   0
                 )
               ],
               "credit" => credit_report(1_100, %{}, 1_100),
               "late_adjustments" => late_adjustments()
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-06") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-06",
               "status" => "open",
               "cash" => [],
               "credit" => credit_report(1_100, %{absorbed_cents: 1_100}, 0),
               "late_adjustments" => late_adjustments()
             }
           }
  end

  test "publishes closed days and forward-posts later old-dated cash as a late adjustment", %{
    conn: conn
  } do
    assert submit(conn, [
             %{
               "operation_id" => "close-before-reporting",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-02"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-reporting",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    submit(conn, [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("period-close"),
      cash_operation("initial-payment", "period-close", 1_000, "2026-10-02")
    ])

    assert submit(conn, [
             %{
               "operation_id" => "close-first-period",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-02"
             },
             %{
               "operation_id" => "same-period-close",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-02"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-first-period",
                 "status" => "applied",
                 "period_end_on" => "2026-10-02"
               },
               %{
                 "operation_id" => "same-period-close",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert submit(conn, [
             %{
               "operation_id" => "close-first-period",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-02"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-first-period",
                 "status" => "applied",
                 "period_end_on" => "2026-10-02"
               }
             ]
           }

    closed_day =
      get(conn, "/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200)

    assert closed_day == %{
             "data" => %{
               "date" => "2026-10-02",
               "status" => "closed",
               "cash" => [cash_report("ams-canal", 0, %{received_cents: 1_000}, 1_000)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    assert submit(conn, [cash_operation("late-payment", "period-close", 500, "2026-10-02")])[
             "results"
           ] == [
             %{
               "operation_id" => "late-payment",
               "status" => "applied",
               "group_id" => "period-close",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 7_500,
               "revision" => 3
             }
           ]

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200) ==
             closed_day

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [cash_report("ams-canal", 1_000, %{}, 1_500)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" =>
                 late_adjustments([late_cash_report("ams-canal", %{received_cents: 500})])
             }
           }

    assert submit(conn, [
             %{
               "operation_id" => "close-second-period",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-03"
             },
             cash_operation("later-payment", "period-close", 100, "2026-10-02")
           ])["results"]
           |> Enum.map(& &1["status"]) == ["applied", "applied"]

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "closed",
               "cash" => [cash_report("ams-canal", 1_000, %{}, 1_500)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" =>
                 late_adjustments([late_cash_report("ams-canal", %{received_cents: 500})])
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-04",
               "status" => "open",
               "cash" => [cash_report("ams-canal", 1_500, %{}, 1_600)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" =>
                 late_adjustments([late_cash_report("ams-canal", %{received_cents: 100})])
             }
           }
  end

  test "reports a late hotel-credit issuance without rewriting the closed cash day", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("late-credit"),
      cash_operation("late-credit-payment", "late-credit", 1_000, "2026-10-02"),
      %{
        "operation_id" => "close-cash-day",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-02"
      },
      %{
        "operation_id" => "late-credit-conversion",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-02",
        "group_id" => "late-credit",
        "refund_method" => "hotel_credit"
      }
    ])

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-02",
               "status" => "closed",
               "cash" => [cash_report("ams-canal", 0, %{received_cents: 1_000}, 1_000)],
               "credit" => credit_report(0, %{}, 0),
               "late_adjustments" => late_adjustments()
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [cash_report("ams-canal", 1_000, %{}, 0)],
               "credit" => credit_report(0, %{}, 1_100),
               "late_adjustments" =>
                 late_adjustments(
                   [late_cash_report("ams-canal", %{converted_to_credit_cents: 1_000})],
                   %{issued_cents: 1_100}
                 )
             }
           }
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations}) |> json_response(200)
  end

  defp open_operation(group_id, overrides \\ []) do
    room_rate = Keyword.get(overrides, :room_rate, 15_000)

    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-30",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => Keyword.get(overrides, :property_id, "ams-canal"),
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => room_rate}]
    }
  end

  defp cash_operation(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cash_report(property_id, opening_held_cents, overrides, closing_held_cents) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening_held_cents,
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
          Map.new(overrides, fn {field, value} -> {Atom.to_string(field), value} end)
        ),
      "closing_held_cents" => closing_held_cents
    }
  end

  defp credit_report(opening_liability_cents, overrides, closing_liability_cents) do
    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" =>
        Map.merge(
          %{
            "issued_cents" => 0,
            "expired_cents" => 0,
            "consumed_cents" => 0,
            "revoked_cents" => 0,
            "absorbed_cents" => 0
          },
          Map.new(overrides, fn {field, value} -> {Atom.to_string(field), value} end)
        ),
      "closing_liability_cents" => closing_liability_cents
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
          Map.new(credit_overrides, fn {field, value} -> {Atom.to_string(field), value} end)
        )
    }
  end

  defp late_cash_report(property_id, overrides) do
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
          Map.new(overrides, fn {field, value} -> {Atom.to_string(field), value} end)
        )
    }
  end
end
