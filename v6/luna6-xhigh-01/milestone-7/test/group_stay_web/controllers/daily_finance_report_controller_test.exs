defmodule GroupStayWeb.DailyFinanceReportControllerTest do
  use GroupStayWeb.ConnCase

  defp open_group(
         operation_id,
         group_id,
         property_id,
         guest_id \\ "guest-report",
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        arrival_on: "2027-01-01",
        departure_on: "2027-01-02",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 10_000}]
      },
      overrides
    )
  end

  defp op(type, operation_id, overrides) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: type,
        occurred_on: "2026-10-05"
      },
      overrides
    )
  end

  defp start_reporting(operation_id \\ "report-start", starts_on \\ "2026-10-05") do
    %{operation_id: operation_id, type: "start_finance_reporting", starts_on: starts_on}
  end

  defp close_period(operation_id, period_end_on) do
    %{operation_id: operation_id, type: "close_finance_period", period_end_on: period_end_on}
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  test "validates report dates and makes reports available only from the inception date", %{
    conn: conn
  } do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report?date=not-a-date") |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(404)

    assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
             submit(conn, [start_reporting("missing-start", nil)]) |> json_response(200)

    assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
             submit(conn, [start_reporting("invalid-start", "2026-02-30")]) |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "starts_on" => "2026-10-05"}]} =
             submit(conn, [start_reporting()]) |> json_response(200)

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             submit(conn, [start_reporting("second-report-start")]) |> json_response(200)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-04") |> json_response(404)
  end

  test "captures committed pre-start balances and reports property cash transfers once", %{
    conn: conn
  } do
    setup = [
      open_group("transfer-source-open", "report-source", "hotel-a", "transfer-guest"),
      op("record_cash_payment", "transfer-source-payment", %{
        group_id: "report-source",
        amount_cents: 1_000,
        occurred_on: "2026-10-06"
      }),
      open_group("transfer-destination-open", "report-destination", "hotel-b", "transfer-guest"),
      start_reporting()
    ]

    assert %{"results" => [_, _, _, started]} = submit(conn, setup) |> json_response(200)
    assert Map.keys(started) |> Enum.sort() == ["operation_id", "starts_on", "status"]

    same_batch_payment =
      op("record_cash_payment", "report-backdated-payment", %{
        group_id: "report-source",
        amount_cents: 200,
        occurred_on: "2026-10-04"
      })

    same_batch_rejection =
      op("record_cash_payment", "report-batch-rejection", %{
        group_id: "report-source",
        amount_cents: 99_999,
        occurred_on: "2026-10-05"
      })

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "rejected"}]} =
             submit(conn, [same_batch_payment, same_batch_rejection]) |> json_response(200)

    transfer = %{
      operation_id: "report-transfer",
      type: "transfer_deposit",
      source_group_id: "report-source",
      destination_group_id: "report-destination",
      amount_cents: 400
    }

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [transfer]) |> json_response(200)

    first_report =
      get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

    assert %{
             "data" => %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "hotel-a",
                   "opening_held_cents" => 1_000,
                   "movements" => %{
                     "received_cents" => 200,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 400,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 800
                 },
                 %{
                   "property_id" => "hotel-b",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 400,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 400
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } = first_report

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200) ==
             first_report

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [transfer]) |> json_response(200)

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200) ==
             first_report
  end

  test "posts cash and credit classifications and includes passive credit expiry", %{conn: conn} do
    setup = [
      open_group("credit-source-open", "credit-source", "hotel-credit-source"),
      op("record_cash_payment", "credit-source-payment", %{
        group_id: "credit-source",
        amount_cents: 1_000,
        occurred_on: "2026-10-04"
      }),
      open_group(
        "credit-destination-open",
        "credit-destination",
        "hotel-credit-destination",
        "guest-report",
        %{
          arrival_on: "2026-10-10",
          departure_on: "2026-10-11",
          rate_plan: "advance_purchase"
        }
      ),
      start_reporting()
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, setup) |> json_response(200)

    operations = [
      op("cancel_group", "report-credit-issue", %{
        group_id: "credit-source",
        occurred_on: "2026-10-05",
        refund_method: "hotel_credit",
        expected_revision: 2
      }),
      op("record_cash_payment", "report-destination-payment", %{
        group_id: "credit-destination",
        amount_cents: 1_000,
        occurred_on: "2026-10-06",
        expected_revision: 1
      }),
      op("reduce_cash_payment", "report-destination-reduction", %{
        payment_operation_id: "report-destination-payment",
        amount_cents: 200,
        occurred_on: "2026-10-07",
        expected_revision: 2
      }),
      op("apply_hotel_credit", "report-credit-application", %{
        group_id: "credit-destination",
        amount_cents: 1_000,
        occurred_on: "2026-10-06",
        expected_revision: 3
      }),
      op("cancel_group", "report-credit-consumption", %{
        group_id: "credit-destination",
        occurred_on: "2026-10-08",
        expected_revision: 4
      })
    ]

    assert %{"results" => [_, _, _, _, _]} = submit(conn, operations) |> json_response(200)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "hotel-credit-destination",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 1_000,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 800,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 200,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "hotel-credit-source",
                   "opening_held_cents" => 1_000,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 1_000,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 1_100,
                   "expired_cents" => 0,
                   "consumed_cents" => 1_000,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 100
               }
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-08") |> json_response(200)

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 1_100,
                   "expired_cents" => 100,
                   "consumed_cents" => 1_000,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2027-10-06") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2027-10-06") |> json_response(200)
  end

  test "reports chargeback reversals as negative prior dispositions and positive chargebacks", %{
    conn: conn
  } do
    before_start = [
      open_group("chargeback-report-open", "chargeback-report-group", "hotel-chargeback"),
      op("record_cash_payment", "chargeback-report-payment", %{
        group_id: "chargeback-report-group",
        amount_cents: 800,
        occurred_on: "2026-10-04"
      }),
      op("cancel_group", "chargeback-report-cancel", %{
        group_id: "chargeback-report-group",
        occurred_on: "2026-10-04",
        expected_revision: 2
      }),
      start_reporting()
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, before_start) |> json_response(200)

    chargeback =
      op("charge_back_payment", "chargeback-report-correction", %{
        payment_operation_id: "chargeback-report-payment",
        occurred_on: "2026-10-06",
        expected_revision: 3
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [chargeback]) |> json_response(200)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "hotel-chargeback",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => -800,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 800
                   },
                   "closing_held_cents" => 0
                 }
               ]
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-06") |> json_response(200)
  end

  test "reports credit absorbed when a refundable return clears a chargeback shortfall", %{
    conn: conn
  } do
    setup = [
      open_group("absorbed-credit-source-open", "absorbed-credit-source", "hotel-absorbed"),
      op("record_cash_payment", "absorbed-credit-payment", %{
        group_id: "absorbed-credit-source",
        amount_cents: 1_000,
        occurred_on: "2026-10-04"
      }),
      open_group(
        "absorbed-credit-destination-open",
        "absorbed-credit-destination",
        "hotel-absorbed"
      ),
      start_reporting()
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, setup) |> json_response(200)

    operations = [
      op("cancel_group", "absorbed-credit-issue", %{
        group_id: "absorbed-credit-source",
        occurred_on: "2026-10-05",
        refund_method: "hotel_credit",
        expected_revision: 2
      }),
      op("apply_hotel_credit", "absorbed-credit-application", %{
        group_id: "absorbed-credit-destination",
        amount_cents: 1_100,
        occurred_on: "2026-10-06",
        expected_revision: 1
      }),
      op("charge_back_payment", "absorbed-credit-chargeback", %{
        payment_operation_id: "absorbed-credit-payment",
        occurred_on: "2026-10-07",
        expected_revision: 3
      }),
      op("cancel_group", "absorbed-credit-return", %{
        group_id: "absorbed-credit-destination",
        occurred_on: "2026-10-08",
        expected_revision: 2
      })
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, operations) |> json_response(200)

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 1_100,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 1_100
                 },
                 "closing_liability_cents" => 0
               }
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-08") |> json_response(200)
  end

  test "a later chargeback does not erase credit expiry on its original report date", %{
    conn: conn
  } do
    operations = [
      open_group("expired-clawback-open", "expired-clawback-group", "hotel-expired-clawback"),
      op("record_cash_payment", "expired-clawback-payment", %{
        group_id: "expired-clawback-group",
        amount_cents: 1_000,
        occurred_on: "2026-10-04"
      }),
      start_reporting(),
      op("cancel_group", "expired-clawback-issue", %{
        group_id: "expired-clawback-group",
        occurred_on: "2026-10-05",
        refund_method: "hotel_credit",
        expected_revision: 2
      })
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, operations) |> json_response(200)

    chargeback =
      op("charge_back_payment", "expired-clawback-chargeback", %{
        payment_operation_id: "expired-clawback-payment",
        occurred_on: "2027-10-07",
        expected_revision: 3
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [chargeback]) |> json_response(200)

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 1_100,
                   "expired_cents" => 1_100,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2027-10-06") |> json_response(200)
  end

  test "closes only valid periods and durably replays the exact close result", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_period("close-before-start", "2026-10-05")])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [start_reporting()]) |> json_response(200)

    invalid_closes = [
      close_period("close-missing-date", nil),
      close_period("close-invalid-date", "2026-02-30"),
      close_period("close-before-inception", "2026-10-04")
    ]

    assert %{
             "results" => [
               %{"code" => "invalid_period"},
               %{"code" => "invalid_period"},
               %{"code" => "invalid_period"}
             ]
           } = submit(conn, invalid_closes) |> json_response(200)

    close = close_period("first-close", "2026-10-06")

    assert %{"results" => [%{"status" => "applied"} = result]} =
             submit(conn, [close]) |> json_response(200)

    assert Map.keys(result) |> Enum.sort() == ["operation_id", "period_end_on", "status"]
    assert result["period_end_on"] == "2026-10-06"

    assert %{"results" => [^result]} = submit(conn, [close]) |> json_response(200)

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [close_period("first-close", "2026-10-07")]) |> json_response(200)

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_period("same-cutoff-again", "2026-10-06")])
             |> json_response(200)

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_period("earlier-cutoff", "2026-10-05")])
             |> json_response(200)

    assert %{"data" => %{"status" => "closed"}} =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

    assert %{"data" => %{"status" => "closed"}} =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-06") |> json_response(200)

    assert %{"data" => %{"status" => "open"}} =
             get(conn, "/api/v1/finance/daily-report?date=2026-10-07") |> json_response(200)
  end

  test "posts old-dated operations after the cutoff and keeps closed reports immutable", %{
    conn: conn
  } do
    setup = [
      open_group("close-group-open", "close-group", "hotel-close"),
      start_reporting()
    ]

    assert %{"results" => [_, _]} = submit(conn, setup) |> json_response(200)

    before_close =
      op("record_cash_payment", "before-close-payment", %{
        group_id: "close-group",
        amount_cents: 400,
        occurred_on: "2026-10-06"
      })

    late_payment =
      op("record_cash_payment", "after-close-backdated-payment", %{
        group_id: "close-group",
        amount_cents: 300,
        occurred_on: "2026-10-04",
        expected_revision: 2
      })

    closing_batch = [
      before_close,
      close_period("close-through-sixth", "2026-10-06"),
      late_payment
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ]
           } =
             submit(conn, closing_batch) |> json_response(200)

    closed_sixth = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
    closed_sixth_body = response(closed_sixth, 200)

    assert %{"data" => %{"status" => "closed", "cash" => [cash]}} =
             Jason.decode!(closed_sixth_body)

    assert cash["movements"]["received_cents"] == 400
    assert cash["closing_held_cents"] == 400

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 400},
                   "closing_held_cents" => 700
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "hotel-close",
                     "movements" => %{"received_cents" => 300}
                   }
                 ]
               }
             }
           } = get(conn, "/api/v1/finance/daily-report?date=2026-10-07") |> json_response(200)

    open_period_payment =
      op("record_cash_payment", "open-period-payment", %{
        group_id: "close-group",
        amount_cents: 100,
        occurred_on: "2026-10-08",
        expected_revision: 3
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [open_period_payment]) |> json_response(200)

    open_eighth =
      get(conn, "/api/v1/finance/daily-report?date=2026-10-08")
      |> response(200)

    assert %{
             "data" => %{
               "cash" => [%{"movements" => %{"received_cents" => 500}}],
               "late_adjustments" => %{
                 "cash" => [%{"movements" => %{"received_cents" => 300}}]
               }
             }
           } = Jason.decode!(open_eighth)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [close_period("close-through-eighth", "2026-10-08")])
             |> json_response(200)

    closed_eighth =
      get(conn, "/api/v1/finance/daily-report?date=2026-10-08")
      |> response(200)

    later_late_payment =
      op("record_cash_payment", "after-second-close-payment", %{
        group_id: "close-group",
        amount_cents: 100,
        occurred_on: "2026-10-05",
        expected_revision: 4
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [later_late_payment]) |> json_response(200)

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-06") |> response(200) ==
             closed_sixth_body

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-08") |> response(200) ==
             closed_eighth
  end

  test "moves complete cash and credit effects into late adjustments", %{conn: conn} do
    group =
      open_group("late-credit-open", "late-credit-group", "hotel-late-credit", "guest-late", %{
        arrival_on: "2026-10-30",
        departure_on: "2026-10-31"
      })

    payment =
      op("record_cash_payment", "late-credit-payment", %{
        group_id: "late-credit-group",
        amount_cents: 1_000,
        occurred_on: "2026-10-04"
      })

    assert %{"results" => [_, _, _]} =
             submit(conn, [group, payment, start_reporting()]) |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [close_period("late-credit-close", "2026-10-06")])
             |> json_response(200)

    cancellation =
      op("cancel_group", "late-credit-cancel", %{
        group_id: "late-credit-group",
        occurred_on: "2026-10-05",
        refund_method: "hotel_credit",
        expected_revision: 2
      })

    assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 1_100}]} =
             submit(conn, [cancellation]) |> json_response(200)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 1_000,
                   "movements" => %{"converted_to_credit_cents" => 0},
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "movements" => %{"issued_cents" => 0},
                 "closing_liability_cents" => 1_100
               },
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "hotel-late-credit",
                     "movements" => %{"converted_to_credit_cents" => 1_000}
                   }
                 ],
                 "credit" => %{"issued_cents" => 1_100}
               }
             }
           } = get(conn, "/api/v1/finance/daily-report?date=2026-10-07") |> json_response(200)
  end

  test "preserves signed late classifications whose balance effects cancel", %{conn: conn} do
    setup = [
      open_group("late-chargeback-open", "late-chargeback-group", "hotel-late-chargeback"),
      op("record_cash_payment", "late-chargeback-payment", %{
        group_id: "late-chargeback-group",
        amount_cents: 1_000,
        occurred_on: "2026-10-04"
      }),
      op("cancel_group", "late-chargeback-refund", %{
        group_id: "late-chargeback-group",
        occurred_on: "2026-10-05",
        expected_revision: 2
      }),
      start_reporting()
    ]

    assert %{"results" => [_, _, _, _]} = submit(conn, setup) |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [close_period("late-chargeback-close", "2026-10-06")])
             |> json_response(200)

    chargeback =
      op("charge_back_payment", "late-chargeback-correction", %{
        payment_operation_id: "late-chargeback-payment",
        occurred_on: "2026-10-05",
        expected_revision: 3
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [chargeback]) |> json_response(200)

    assert %{
             "data" => %{
               "cash" => [%{"closing_held_cents" => 0}],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "movements" => %{
                       "refunded_cents" => -1_000,
                       "charged_back_cents" => 1_000
                     }
                   }
                 ]
               }
             }
           } = get(conn, "/api/v1/finance/daily-report?date=2026-10-07") |> json_response(200)
  end

  test "reports a credit lot that expires on the day its late issuance is posted", %{conn: conn} do
    group =
      open_group(
        "expired-late-credit-open",
        "expired-late-credit-group",
        "hotel-expired-late",
        "guest-expired-late",
        %{
          occurred_on: "2024-10-01",
          arrival_on: "2024-10-30",
          departure_on: "2024-10-31"
        }
      )

    payment =
      op("record_cash_payment", "expired-late-credit-payment", %{
        group_id: "expired-late-credit-group",
        amount_cents: 1_000,
        occurred_on: "2024-10-02"
      })

    assert %{"results" => [_, _, _]} =
             submit(conn, [group, payment, start_reporting("expired-late-start", "2026-10-01")])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [close_period("expired-late-close", "2026-10-02")])
             |> json_response(200)

    cancellation =
      op("cancel_group", "expired-late-credit-cancel", %{
        group_id: "expired-late-credit-group",
        occurred_on: "2024-10-05",
        refund_method: "hotel_credit",
        expected_revision: 2
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [cancellation]) |> json_response(200)

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 0, "expired_cents" => 0},
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "credit" => %{"issued_cents" => 1_100, "expired_cents" => 1_100}
               }
             }
           } = get(conn, "/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200)
  end
end
