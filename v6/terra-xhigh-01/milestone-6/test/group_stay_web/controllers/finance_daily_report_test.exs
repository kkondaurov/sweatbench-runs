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
               "credit" => credit_report(0, %{}, 0)
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
               "credit" => credit_report(0, %{}, 0)
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
               "credit" => credit_report(0, %{}, 0)
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
               "credit" => credit_report(0, %{}, 0)
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
               "credit" => credit_report(0, %{}, 0)
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [cash_report("ams-canal", 1_000, %{refunded_cents: 1_000}, 0)],
               "credit" => credit_report(0, %{}, 0)
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
        "credit" => credit_report(1_100, %{expired_cents: 1_100}, 0)
      }
    }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [
                 cash_report("ams-canal", 1_000, %{converted_to_credit_cents: 1_000}, 0)
               ],
               "credit" => credit_report(0, %{issued_cents: 1_100}, 1_100)
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
               "credit" => credit_report(1_100, %{}, 1_100)
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
               "credit" => credit_report(1_100, %{consumed_cents: 1_100}, 0)
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
               "credit" => credit_report(1_100, %{}, 1_100)
             }
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-06") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-10-06",
               "status" => "open",
               "cash" => [],
               "credit" => credit_report(1_100, %{absorbed_cents: 1_100}, 0)
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
end
