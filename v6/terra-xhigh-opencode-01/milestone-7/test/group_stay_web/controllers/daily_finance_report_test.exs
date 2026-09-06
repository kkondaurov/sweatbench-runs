defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: true

  test "starts reporting from the committed position and records later credit movements", %{
    conn: conn
  } do
    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-03")
    assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=not-a-date")
    assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)

    conn =
      post_operations(conn, [
        start_reporting("invalid-start", "not-a-date"),
        open_operation("credit-issuer", property_id: "ams-canal", rooms: rooms(500)),
        cash_payment("issuer-payment", "credit-issuer", 100, "2027-01-05", 1),
        open_operation("credit-consumer",
          property_id: "paris-left",
          rate_plan: "advance_purchase",
          rooms: rooms(100)
        ),
        start_reporting("start-reporting", "2027-01-03")
      ])

    assert %{
             "results" => [
               %{"status" => "rejected", "code" => "invalid_reporting_date"},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"revision" => 1},
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2027-01-03"
               } = start_result
             ]
           } = json_response(conn, 200)

    assert start_result == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2027-01-03"
           }

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "issue-report-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "credit-issuer",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 110}]} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-03")

    assert %{
             "data" => %{
               "date" => "2027-01-03",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 100,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 110,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 110
               }
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "apply-report-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-04",
          "group_id" => "credit-consumer",
          "amount_cents" => 100,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "consume-report-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "credit-consumer",
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"revision" => 2}, %{"status" => "applied", "revision" => 3}]} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-04")

    assert %{
             "data" => %{
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 110,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 100,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 10
               }
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2028-01-04")

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 10,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 10,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(conn, 200)

    conn = post_operations(conn, [start_reporting("start-reporting", "2027-01-03")])
    assert %{"results" => [^start_result]} = json_response(conn, 200)

    conn = post_operations(conn, [start_reporting("second-start", "2027-01-04")])

    assert %{"results" => [%{"status" => "rejected", "code" => "reporting_already_started"}]} =
             json_response(conn, 200)
  end

  test "reports transfers, settlements, reductions, and chargebacks at affected properties", %{
    conn: conn
  } do
    conn =
      post_operations(conn, [
        open_operation("cash-source",
          property_id: "ams-canal",
          rate_plan: "advance_purchase",
          rooms: rooms(100)
        ),
        open_operation("cash-destination",
          property_id: "berlin-mitte",
          rate_plan: "advance_purchase",
          rooms: rooms(100)
        ),
        cash_payment("cash-payment", "cash-source", 100, "2027-01-02", 1),
        start_reporting("cash-start", "2027-01-03"),
        %{
          "operation_id" => "cash-transfer",
          "type" => "transfer_deposit",
          "occurred_on" => "2027-01-03",
          "source_group_id" => "cash-source",
          "destination_group_id" => "cash-destination",
          "amount_cents" => 50,
          "expected_revision" => 2,
          "destination_expected_revision" => 1
        },
        %{
          "operation_id" => "retain-destination",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "cash-destination",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "reduce-source-payment",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-04",
          "payment_operation_id" => "cash-payment",
          "amount_cents" => 10,
          "expected_revision" => 3
        },
        %{
          "operation_id" => "charge-back-source-payment",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-05",
          "payment_operation_id" => "cash-payment",
          "expected_revision" => 4
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"status" => "applied"},
               %{"source_revision" => 3, "destination_revision" => 2},
               %{"status" => "applied", "retained_cents" => 50},
               %{"status" => "applied", "revision" => 4},
               %{"status" => "applied", "charged_back_cents" => 90, "revision" => 5}
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-03")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{"transferred_out_cents" => 50},
                   "closing_held_cents" => 50
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 0,
                   "movements" => %{"transferred_in_cents" => 50},
                   "closing_held_cents" => 50
                 }
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-04")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 50,
                   "movements" => %{"reduced_cents" => 10},
                   "closing_held_cents" => 40
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 50,
                   "movements" => %{"retained_cents" => 50},
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-05")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 40,
                   "movements" => %{"charged_back_cents" => 40},
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "retained_cents" => -50,
                     "charged_back_cents" => 50
                   },
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = json_response(conn, 200)
  end

  test "nets an already-expired issued lot and does not revoke it a second time", %{conn: conn} do
    conn =
      post_operations(conn, [
        open_operation("historical-credit", rooms: rooms(500)),
        cash_payment("historical-payment", "historical-credit", 100, "2027-01-02", 1),
        start_reporting("historical-start", "2028-01-05"),
        %{
          "operation_id" => "historical-cancellation",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-03",
          "group_id" => "historical-credit",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "historical-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2028-01-06",
          "payment_operation_id" => "historical-payment",
          "expected_revision" => 3
        }
      ])

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"status" => "applied"},
               %{"credit_issued_cents" => 110, "revision" => 3},
               %{"charged_back_cents" => 100, "revision" => 4}
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2028-01-05")

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 110, "expired_cents" => 110},
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2028-01-06")

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{"revoked_cents" => 0},
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(conn, 200)
  end

  defp post_operations(conn, operations) do
    post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_operation(group_id, overrides) do
    operation = %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-05",
      "departure_on" => "2027-03-06",
      "rate_plan" => "flexible",
      "rooms" => rooms(100)
    }

    Enum.reduce(overrides, operation, fn {key, value}, operation ->
      Map.put(operation, Atom.to_string(key), value)
    end)
  end

  defp cash_payment(operation_id, group_id, amount_cents, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp rooms(rate) do
    [%{"room_id" => "room-a", "nightly_rate_cents" => rate}]
  end
end
