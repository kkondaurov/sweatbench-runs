defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp open_group(operation_id, group_id, property_id \\ "ams-canal", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => property_id,
        "arrival_on" => "2026-03-01",
        "departure_on" => "2026-03-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 1_000}]
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => 200
    }
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_period(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}")
  end

  test "starts reporting durably and exposes only reports on or after its date", %{conn: conn} do
    assert report(conn, "2026-01-01") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    response =
      submit(conn, [
        %{"operation_id" => "bad-start", "type" => "start_finance_reporting"},
        start_reporting("start-reporting", "2026-01-02")
      ])
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "bad-start",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             },
             %{
               "operation_id" => "start-reporting",
               "status" => "applied",
               "starts_on" => "2026-01-02"
             }
           ]

    assert report(build_conn(), "2026-01-01") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert report(build_conn(), "2026-01-02") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-01-02",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => late_adjustments()
             }
           }

    start = Enum.at(response["results"], 1)

    assert submit(build_conn(), [start_reporting("start-reporting", "2026-01-02")])
           |> json_response(200) == %{"results" => [start]}

    assert submit(build_conn(), [start_reporting("second-start", "2026-01-03")])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "second-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    assert report(build_conn(), "not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }
  end

  test "uses pre-start state as opening and clamps post-start postings to the inception date", %{
    conn: conn
  } do
    submit(conn, [
      open_group("open-opening", "opening"),
      cash_payment("opening-payment", "opening", "2026-12-01"),
      start_reporting("start-reporting", "2026-01-03"),
      open_group("open-clamped", "clamped", "ams-canal", %{"occurred_on" => "2026-01-03"}),
      cash_payment("clamped-payment", "clamped", "2026-01-01")
    ])

    assert report(build_conn(), "2026-01-03") |> json_response(200) == %{
             "data" => %{
               "date" => "2026-01-03",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 200,
                   "movements" => cash_movements(%{"received_cents" => 200}),
                   "closing_held_cents" => 400
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => late_adjustments()
             }
           }
  end

  test "reports cash transfers and a later reduction at the property currently holding cash", %{
    conn: conn
  } do
    submit(conn, [
      start_reporting("start-reporting", "2026-01-01"),
      open_group("open-source", "source", "ams-canal"),
      cash_payment("source-payment", "source", "2026-01-02"),
      open_group("open-destination", "destination", "lon-city"),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-01-03",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 200
      },
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-01-04",
        "payment_operation_id" => "source-payment",
        "amount_cents" => 50
      }
    ])

    assert get_in(report(build_conn(), "2026-01-03") |> json_response(200), ["data", "cash"]) == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 200,
               "movements" => cash_movements(%{"transferred_out_cents" => 200}),
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "lon-city",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"transferred_in_cents" => 200}),
               "closing_held_cents" => 200
             }
           ]

    assert get_in(report(build_conn(), "2026-01-04") |> json_response(200), ["data", "cash"]) == [
             %{
               "property_id" => "lon-city",
               "opening_held_cents" => 200,
               "movements" => cash_movements(%{"reduced_cents" => 50}),
               "closing_held_cents" => 150
             }
           ]
  end

  test "reclassifies a prior refund as a negative refund and positive chargeback", %{conn: conn} do
    submit(conn, [
      start_reporting("start-reporting", "2026-01-01"),
      open_group("open-group", "group"),
      cash_payment("cash-payment", "group", "2026-01-02"),
      %{
        "operation_id" => "refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "group"
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-01-04",
        "payment_operation_id" => "cash-payment"
      }
    ])

    assert get_in(report(build_conn(), "2026-01-04") |> json_response(200), ["data", "cash"]) == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{"refunded_cents" => -200, "charged_back_cents" => 200}),
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports credit issuance, consumption, and automatic expiry without a partner operation",
       %{
         conn: conn
       } do
    submit(conn, [
      start_reporting("start-reporting", "2026-01-01"),
      open_group("open-source", "source"),
      cash_payment("source-cash", "source", "2026-01-01"),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-02",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open_group("open-target", "target", "ams-canal", %{
        "arrival_on" => "2026-01-10",
        "departure_on" => "2026-01-11"
      }),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-03",
        "group_id" => "target",
        "amount_cents" => 200
      },
      %{
        "operation_id" => "consume-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-05",
        "group_id" => "target"
      }
    ])

    assert get_in(report(build_conn(), "2026-01-02") |> json_response(200), ["data", "credit"]) ==
             %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(%{"issued_cents" => 220}),
               "closing_liability_cents" => 220
             }

    assert get_in(report(build_conn(), "2026-01-05") |> json_response(200), ["data", "credit"]) ==
             %{
               "opening_liability_cents" => 220,
               "movements" => credit_movements(%{"consumed_cents" => 200}),
               "closing_liability_cents" => 20
             }

    assert get_in(report(build_conn(), "2027-01-03") |> json_response(200), ["data", "credit"]) ==
             %{
               "opening_liability_cents" => 20,
               "movements" => credit_movements(%{"expired_cents" => 20}),
               "closing_liability_cents" => 0
             }
  end

  test "late submissions update an open report without reads changing its contents", %{conn: conn} do
    submit(conn, [start_reporting("start-reporting", "2026-01-01")])

    initial = report(build_conn(), "2026-01-02") |> json_response(200)
    assert report(build_conn(), "2026-01-02") |> json_response(200) == initial

    submit(build_conn(), [
      open_group("open-late", "late"),
      cash_payment("late-payment", "late", "2026-01-02")
    ])

    assert get_in(report(build_conn(), "2026-01-02") |> json_response(200), ["data", "cash"]) == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"received_cents" => 200}),
               "closing_held_cents" => 200
             }
           ]
  end

  test "closes valid periods durably and rejects every other cutoff", %{conn: conn} do
    assert submit(conn, [close_period("close-before-start", "2026-01-02")])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    submit(build_conn(), [start_reporting("start-reporting", "2026-01-02")])

    assert submit(build_conn(), [
             close_period("close-before-period", "2026-01-01"),
             %{"operation_id" => "close-malformed", "type" => "close_finance_period"}
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "close-malformed",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    close = %{
      "operation_id" => "close-period",
      "status" => "applied",
      "period_end_on" => "2026-01-02"
    }

    assert submit(build_conn(), [close_period("close-period", "2026-01-02")])
           |> json_response(200) == %{"results" => [close]}

    assert submit(build_conn(), [close_period("close-period", "2026-01-02")])
           |> json_response(200) == %{"results" => [close]}

    assert get(build_conn(), "/api/v1/operations/close-period") |> json_response(200) == %{
             "data" => close
           }

    assert submit(build_conn(), [
             close_period("same-cutoff", "2026-01-02"),
             close_period("earlier-cutoff", "2026-01-01"),
             close_period("close-period", "2026-01-03")
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "same-cutoff",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "earlier-cutoff",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "close-period",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }
  end

  test "keeps closed report data stable and posts old cash into late adjustments", %{conn: conn} do
    submit(conn, [
      start_reporting("start-reporting", "2026-01-01"),
      open_group("open-closed", "closed"),
      cash_payment("closed-payment", "closed", "2026-01-02"),
      close_period("close-first", "2026-01-02")
    ])

    closed_report = report(build_conn(), "2026-01-02") |> json_response(200)

    assert closed_report["data"]["status"] == "closed"

    assert closed_report["data"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"received_cents" => 200}),
               "closing_held_cents" => 200
             }
           ]

    submit(build_conn(), [
      open_group("open-late", "late"),
      cash_payment("late-payment", "late", "2026-01-02")
    ])

    assert report(build_conn(), "2026-01-02") |> json_response(200) == closed_report

    open_report = report(build_conn(), "2026-01-03") |> json_response(200)
    assert open_report["data"]["status"] == "open"

    assert open_report["data"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 200,
               "movements" => cash_movements(%{}),
               "closing_held_cents" => 400
             }
           ]

    assert open_report["data"]["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"received_cents" => 200})
               }
             ],
             "credit" => credit_movements()
           }

    submit(build_conn(), [close_period("close-second", "2026-01-03")])

    assert report(build_conn(), "2026-01-02") |> json_response(200) == closed_report

    assert get_in(report(build_conn(), "2026-01-03") |> json_response(200), ["data"]) ==
             open_report["data"] |> Map.put("status", "closed")
  end

  test "keeps signed zero-net chargebacks visible as late adjustments", %{conn: conn} do
    submit(conn, [
      start_reporting("start-reporting", "2026-01-01"),
      open_group("open-group", "group"),
      cash_payment("cash-payment", "group", "2026-01-02"),
      %{
        "operation_id" => "refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "group"
      },
      close_period("close-period", "2026-01-03"),
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-01-03",
        "payment_operation_id" => "cash-payment"
      }
    ])

    assert get_in(report(build_conn(), "2026-01-04") |> json_response(200), [
             "data",
             "late_adjustments",
             "cash"
           ]) == [
             %{
               "property_id" => "ams-canal",
               "movements" =>
                 cash_movements(%{"refunded_cents" => -200, "charged_back_cents" => 200})
             }
           ]
  end

  test "posts the expiry of late-issued credit in the first open period", %{conn: conn} do
    submit(conn, [
      start_reporting("start-reporting", "2026-01-01"),
      open_group("open-source", "source"),
      cash_payment("source-cash", "source", "2026-01-02"),
      close_period("close-period", "2026-01-05"),
      %{
        "operation_id" => "late-credit",
        "type" => "cancel_group",
        "occurred_on" => "2025-01-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ])

    open_report = report(build_conn(), "2026-01-06") |> json_response(200)

    assert get_in(open_report, ["data", "credit"]) == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(),
             "closing_liability_cents" => 0
           }

    assert get_in(open_report, ["data", "late_adjustments", "credit"]) ==
             credit_movements(%{"issued_cents" => 220, "expired_cents" => 220})

    submit(build_conn(), [close_period("close-second", "2026-01-06")])

    assert get_in(report(build_conn(), "2026-01-06") |> json_response(200), ["data"]) ==
             open_report["data"] |> Map.put("status", "closed")
  end

  test "expires a late backdated credit issuance on the reporting inception date", %{conn: conn} do
    submit(conn, [
      start_reporting("start-reporting", "2027-01-03"),
      open_group("open-source", "source"),
      cash_payment("source-cash", "source", "2026-01-01"),
      %{
        "operation_id" => "issue-expired-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ])

    assert get_in(report(build_conn(), "2027-01-03") |> json_response(200), ["data", "credit"]) ==
             %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(%{"issued_cents" => 220, "expired_cents" => 220}),
               "closing_liability_cents" => 0
             }
  end

  defp cash_movements(overrides) do
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
      overrides
    )
  end

  defp credit_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end

  defp late_adjustments do
    %{"cash" => [], "credit" => credit_movements()}
  end
end
