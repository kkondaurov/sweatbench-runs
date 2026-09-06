defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp open_operation(group_id, operation_id), do: open_operation(group_id, operation_id, %{})

  defp open_operation(group_id, operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2028-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-report",
        "property_id" => "ams-canal",
        "arrival_on" => "2028-06-10",
        "departure_on" => "2028-06-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}")
  end

  test "starts once, preserves the exact result, and exposes report availability", %{conn: conn} do
    assert json_response(report(conn, "not-a-date"), 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert json_response(report(conn, "2028-01-01"), 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    start = %{
      "operation_id" => "start-1",
      "type" => "start_finance_reporting",
      "starts_on" => "2028-01-10"
    }

    assert json_response(post_batch(conn, [start]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "start-1",
                 "status" => "applied",
                 "starts_on" => "2028-01-10"
               }
             ]
           }

    assert json_response(post_batch(conn, [start]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "start-1",
                 "status" => "applied",
                 "starts_on" => "2028-01-10"
               }
             ]
           }

    assert json_response(
             post_batch(conn, [
               %{
                 "operation_id" => "start-2",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2028-01-11"
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "start-2",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    assert json_response(report(conn, "2028-01-09"), 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert json_response(report(conn, "2028-01-10"), 200) == %{
             "data" => %{
               "date" => "2028-01-10",
               "status" => "open",
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
               },
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
           }
  end

  test "uses commit order for opening and posting dates for later operations", %{conn: conn} do
    operations = [
      open_operation("group-1", "open-1", %{"occurred_on" => "2028-02-20"}),
      %{
        "operation_id" => "pay-before-start",
        "type" => "record_cash_payment",
        "occurred_on" => "2028-02-20",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2028-02-01"
      },
      %{
        "operation_id" => "pay-after-start",
        "type" => "record_cash_payment",
        "occurred_on" => "2028-01-01",
        "group_id" => "group-1",
        "amount_cents" => 500
      }
    ]

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"status" => "applied"},
               %{"revision" => 3}
             ]
           } =
             post_batch(conn, operations) |> json_response(200)

    assert %{"results" => [%{"revision" => 3}]} =
             post_batch(conn, [List.last(operations)]) |> json_response(200)

    assert json_response(report(conn, "2028-02-01"), 200)["data"] == %{
             "date" => "2028-02-01",
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
             },
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
  end

  test "reports cash by property through transfers and reductions", %{conn: conn} do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"status" => "applied"}
             ]
           } =
             post_batch(conn, [
               open_operation("source", "source-open", %{"property_id" => "ams-canal"}),
               open_operation("destination", "destination-open", %{"property_id" => "bru-centre"}),
               %{
                 "operation_id" => "source-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2028-01-02",
                 "group_id" => "source",
                 "amount_cents" => 5_000
               },
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2028-01-03"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"source_revision" => 3, "destination_revision" => 2}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "transfer-1",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2028-01-04",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 3_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 4}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce-1",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2028-01-05",
                 "payment_operation_id" => "source-pay",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert json_response(report(conn, "2028-01-04"), 200)["data"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5_000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 3_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 2_000
             },
             %{
               "property_id" => "bru-centre",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 3_000,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 3_000
             }
           ]

    assert json_response(report(conn, "2028-01-05"), 200)["data"]["cash"]
           |> Enum.find(&(&1["property_id"] == "bru-centre"))
           |> Map.take(["movements", "closing_held_cents"]) == %{
             "movements" => %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             },
             "closing_held_cents" => 2_000
           }
  end

  test "reverses a refund and expires credit without a partner operation", %{conn: conn} do
    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"revision" => 3}
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2028-01-01"
               },
               open_operation("refund-group", "refund-open"),
               %{
                 "operation_id" => "refund-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2028-01-02",
                 "group_id" => "refund-group",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "refund-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2028-01-03",
                 "group_id" => "refund-group"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"charged_back_cents" => 1_000, "revision" => 4}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "refund-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2028-01-04",
                 "payment_operation_id" => "refund-pay"
               }
             ])
             |> json_response(200)

    assert json_response(report(conn, "2028-01-03"), 200)["data"] == %{
             "date" => "2028-01-03",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 1_000,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 0
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
             },
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

    assert json_response(report(conn, "2028-01-04"), 200)["data"]["cash"]
           |> hd()
           |> Map.take(["movements", "closing_held_cents"]) == %{
             "movements" => %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => -1_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 1_000
             },
             "closing_held_cents" => 0
           }

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"credit_issued_cents" => 1_100}
             ]
           } =
             post_batch(conn, [
               open_operation("credit-group", "credit-open", %{"guest_id" => "credit-guest"}),
               %{
                 "operation_id" => "credit-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2028-01-05",
                 "group_id" => "credit-group",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2028-01-06",
                 "group_id" => "credit-group",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert json_response(report(conn, "2029-01-07"), 200)["data"]["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 1_100,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end
end
