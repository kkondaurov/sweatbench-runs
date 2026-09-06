defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "property-1",
        "arrival_on" => "2026-01-20",
        "departure_on" => "2026-01-21",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  test "validates and durably replays finance period closes", %{conn: conn} do
    close = %{
      "operation_id" => "close-1",
      "type" => "close_finance_period",
      "period_end_on" => "2026-01-03"
    }

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             json_response(submit(conn, [Map.put(close, "operation_id", "before-start")]), 200)

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "start",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2026-01-01"
                 }
               ]),
               200
             )

    assert %{"results" => [%{"code" => "invalid_period"}, %{"code" => "invalid_period"}]} =
             json_response(
               submit(conn, [
                 Map.merge(close, %{"operation_id" => "bad-date", "period_end_on" => "not-a-date"}),
                 Map.merge(close, %{
                   "operation_id" => "bad-before",
                   "period_end_on" => "2025-12-31"
                 })
               ]),
               200
             )

    assert %{"results" => [close_result]} = json_response(submit(conn, [close]), 200)

    assert close_result == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2026-01-03"
           }

    assert %{"results" => [%{"code" => "invalid_period"}, %{"code" => "invalid_period"}]} =
             json_response(
               submit(conn, [
                 Map.put(close, "operation_id", "equal-close"),
                 Map.merge(close, %{
                   "operation_id" => "earlier-close",
                   "period_end_on" => "2026-01-02"
                 })
               ]),
               200
             )

    assert %{"results" => [replayed]} = json_response(submit(conn, [close]), 200)
    assert replayed == close_result

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             json_response(submit(conn, [Map.put(close, "period_end_on", "2026-01-04")]), 200)
  end

  test "closes empty days and keeps ordinary and late posting separate", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      open("period-group"),
      %{
        "operation_id" => "payment-before-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "period-group",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2026-01-03"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 3)["status"] == "applied"

    closed = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-02"), 200)

    assert %{
             "data" => %{
               "date" => "2026-01-02",
               "status" => "closed",
               "cash" => [%{"movements" => %{"received_cents" => 1_000}}],
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = closed

    assert %{
             "data" => %{
               "date" => "2026-01-01",
               "status" => "closed",
               "cash" => [],
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
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-01"), 200)

    assert %{"data" => %{"status" => "open"}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-04"), 200)

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "late-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "period-group",
                   "amount_cents" => 500
                 },
                 %{
                   "operation_id" => "open-date-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-05",
                   "group_id" => "period-group",
                   "amount_cents" => 200
                 }
               ]),
               200
             )

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-02"), 200) == closed

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{
                   "opening_held_cents" => 1_000,
                   "movements" => %{
                     "received_cents" => 0,
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
               "late_adjustments" => %{
                 "cash" => [
                   %{"property_id" => "property-1", "movements" => %{"received_cents" => 500}}
                 ],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-04"), 200)

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [%{"movements" => %{"received_cents" => 200}}]
             }
           } =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-05"), 200)

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "close-2",
                   "type" => "close_finance_period",
                   "period_end_on" => "2026-01-05"
                 }
               ]),
               200
             )

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-02"), 200) == closed
  end

  test "classifies signed late chargebacks and late credit issuance", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      open("chargeback-group"),
      %{
        "operation_id" => "chargeback-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "chargeback-group",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "cancel-before-close",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-02",
        "group_id" => "chargeback-group"
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2026-01-03"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 4)["status"] == "applied"

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "late-chargeback",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => "chargeback-payment",
                   "occurred_on" => "2026-01-02"
                 }
               ]),
               200
             )

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 0
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "property-1",
                     "movements" => %{
                       "received_cents" => 0,
                       "transferred_in_cents" => 0,
                       "transferred_out_cents" => 0,
                       "refunded_cents" => -1_000,
                       "retained_cents" => 0,
                       "converted_to_credit_cents" => 0,
                       "reduced_cents" => 0,
                       "charged_back_cents" => 1_000
                     }
                   }
                 ]
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-04"), 200)

    assert %{"results" => [_, _, %{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 open("credit-group"),
                 %{
                   "operation_id" => "credit-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "credit-group",
                   "amount_cents" => 1_000
                 },
                 %{
                   "operation_id" => "late-credit-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "credit-group",
                   "refund_method" => "hotel_credit"
                 }
               ]),
               200
             )

    assert %{
             "data" => %{
               "credit" => %{"movements" => %{"issued_cents" => 0}},
               "late_adjustments" => %{"credit" => %{"issued_cents" => 1_100}}
             }
           } =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-04"), 200)
  end

  test "posts expired credit restored after a close as a late expiry", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      open("credit-source"),
      %{
        "operation_id" => "credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", %{
        "arrival_on" => "2028-01-20",
        "departure_on" => "2028-01-21"
      }),
      %{
        "operation_id" => "credit-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-target",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-03"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 6)["status"] == "applied"

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "late-target-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-01-04",
                   "group_id" => "credit-target"
                 }
               ]),
               200
             )

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 500,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 500,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-04"), 200)
  end

  test "keeps late credit corrections signed after a published expiry", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      open("credit-source"),
      %{
        "operation_id" => "credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", %{
        "arrival_on" => "2028-01-20",
        "departure_on" => "2028-01-21"
      }),
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-03"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 5)["status"] == "applied"

    assert %{"results" => [_, %{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "late-apply",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2026-01-03",
                   "group_id" => "credit-target",
                   "amount_cents" => 500
                 },
                 %{
                   "operation_id" => "late-chargeback",
                   "type" => "charge_back_payment",
                   "payment_operation_id" => "credit-payment",
                   "occurred_on" => "2026-01-04"
                 }
               ]),
               200
             )

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 500
               },
               "late_adjustments" => %{
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => -1_100,
                   "consumed_cents" => 0,
                   "revoked_cents" => 600,
                   "absorbed_cents" => 0
                 }
               }
             }
           } =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-04"), 200)
  end
end
