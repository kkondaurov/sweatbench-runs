defmodule GroupStayWeb.DailyFinanceReportTest do
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
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  test "starts reporting at a durable inception point and rolls balances by day", %{conn: conn} do
    assert %{"results" => [_, _, start, _]} =
             json_response(
               submit(conn, [
                 open("report-group"),
                 %{
                   "operation_id" => "before-reporting",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-02",
                   "group_id" => "report-group",
                   "amount_cents" => 1_000
                 },
                 %{
                   "operation_id" => "start-reporting",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2026-01-10"
                 },
                 %{
                   "operation_id" => "after-reporting",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-01-11",
                   "group_id" => "report-group",
                   "amount_cents" => 500
                 }
               ]),
               200
             )

    assert start == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-01-10"
           }

    assert %{
             "data" => %{
               "date" => "2026-01-10",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "property-1",
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
                   "closing_held_cents" => 1_000
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-10"), 200)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 1_000,
                   "movements" => %{"received_cents" => 500},
                   "closing_held_cents" => 1_500
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-11"), 200)

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-09"), 404)["error"][
             "code"
           ] ==
             "report_not_available"

    assert json_response(get(conn, "/api/v1/finance/daily-report"), 422)["error"]["code"] ==
             "invalid_reporting_date"
  end

  test "reports credit issuance and expiry without a partner operation", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      open("credit-source", %{
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-11"
      }),
      %{
        "operation_id" => "credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 3)["credit_issued_cents"] == 1_100

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 1_100,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 1_100
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-03"), 200)

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 1_100,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 1_100,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-04"), 200)
  end

  test "allows only one valid reporting start", %{conn: conn} do
    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_reporting_date"}]} =
             json_response(
               submit(conn, [
                 %{"operation_id" => "bad-start", "type" => "start_finance_reporting"}
               ]),
               200
             )

    assert %{"results" => [%{"status" => "applied"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "start-reporting",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2026-01-01"
                 }
               ]),
               200
             )

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             json_response(
               submit(conn, [
                 %{
                   "operation_id" => "another-start",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2026-01-02"
                 }
               ]),
               200
             )
  end

  test "posts transfers and later cash corrections at the property holding the cash", %{
    conn: conn
  } do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      open("source", %{"property_id" => "property-a"}),
      open("destination", %{"property_id" => "property-b"}),
      %{
        "operation_id" => "payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "source",
        "amount_cents" => 2_000
      },
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1_000,
        "occurred_on" => "2026-01-03"
      },
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "payment",
        "amount_cents" => 500,
        "occurred_on" => "2026-01-04"
      },
      %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-05",
        "group_id" => "destination"
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "payment",
        "occurred_on" => "2026-01-06"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 5)["status"] == "applied"
    assert Enum.at(results, 6)["status"] == "applied"

    assert %{"data" => %{"cash" => cash}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-06"), 200)

    assert cash == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 1_000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 1_000
               },
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "property-b",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -500,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 500
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports credit consumption, revocation, and shortfall absorption", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
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
        "operation_id" => "credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", %{
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      %{
        "operation_id" => "credit-application",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "credit-target",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "credit-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "credit-payment",
        "occurred_on" => "2026-01-05"
      },
      %{
        "operation_id" => "target-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-06",
        "group_id" => "credit-target"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 3)["credit_issued_cents"] == 1_100
    assert Enum.at(results, 6)["charged_back_cents"] == 1_000
    assert Enum.at(results, 7)["refunded_cents"] == 0

    assert %{"data" => %{"credit" => credit}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-05"), 200)

    assert credit["opening_liability_cents"] == 1_100

    assert credit["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 600,
             "absorbed_cents" => 0
           }

    assert credit["closing_liability_cents"] == 500

    assert %{"data" => %{"credit" => credit}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-06"), 200)

    assert credit["opening_liability_cents"] == 500

    assert credit["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 500
           }

    assert credit["closing_liability_cents"] == 0
  end

  test "counts only cash in a mixed deposit transfer", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
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
        "operation_id" => "credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("transfer-source", %{"property_id" => "property-a"}),
      %{
        "operation_id" => "transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-04",
        "group_id" => "transfer-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "transfer-application",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "transfer-source",
        "amount_cents" => 500
      },
      open("transfer-destination", %{"property_id" => "property-b"}),
      %{
        "operation_id" => "mixed-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "transfer-source",
        "destination_group_id" => "transfer-destination",
        "amount_cents" => 1_500,
        "occurred_on" => "2026-01-05"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 8)["status"] == "applied"

    assert %{"data" => %{"cash" => cash}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-01-05"), 200)

    assert Enum.find(cash, &(&1["property_id"] == "property-a"))["movements"] == %{
             "received_cents" => 0,
             "transferred_in_cents" => 0,
             "transferred_out_cents" => 1_000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert Enum.find(cash, &(&1["property_id"] == "property-b"))["movements"] == %{
             "received_cents" => 0,
             "transferred_in_cents" => 1_000,
             "transferred_out_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }
  end

  test "uses durable operation order when a credit application is backdated", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
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
        "operation_id" => "credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", %{
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      %{
        "operation_id" => "backdated-application",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-02",
        "group_id" => "credit-target",
        "amount_cents" => 500
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 5)["status"] == "applied"

    assert %{"data" => %{"credit" => credit}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-04"), 200)

    assert credit["opening_liability_cents"] == 1_100
    assert credit["movements"]["expired_cents"] == 600
    assert credit["closing_liability_cents"] == 500
  end

  test "posts a late-created lot that is already expired as a balanced movement", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-10"
      },
      open("expired-source", %{
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-11"
      }),
      %{
        "operation_id" => "expired-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-01",
        "group_id" => "expired-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "expired-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-01",
        "group_id" => "expired-source",
        "refund_method" => "hotel_credit"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 3)["status"] == "applied"

    assert %{"data" => %{"credit" => credit}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-10"), 200)

    assert credit["movements"]["issued_cents"] == 1_100
    assert credit["movements"]["expired_cents"] == 1_100
    assert credit["closing_liability_cents"] == 0
  end

  test "expires both unused and restored credit when restoration follows expiry", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
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
        "operation_id" => "credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", %{
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      %{
        "operation_id" => "credit-application",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "credit-target",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "target-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-04",
        "group_id" => "credit-target"
      }
    ]

    assert %{"results" => results} = json_response(submit(conn, operations), 200)
    assert Enum.at(results, 6)["status"] == "applied"

    assert %{"data" => %{"credit" => credit}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-04"), 200)

    assert credit["opening_liability_cents"] == 1_100
    assert credit["movements"]["expired_cents"] == 1_100
    assert credit["closing_liability_cents"] == 0
  end
end
