defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts reporting at an in-batch durable boundary and validates report dates", %{
    conn: conn
  } do
    missing_date = %{
      "operation_id" => "missing-reporting-date",
      "type" => "start_finance_reporting"
    }

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [missing_date]})

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "missing-reporting-date",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }

    operations = [
      open("group-a", "guest", "ams-canal", 5_000),
      operation("pay-before", "record_cash_payment", "2027-01-03", %{
        "group_id" => "group-a",
        "amount_cents" => 400
      }),
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-05"
      },
      operation("pay-after", "record_cash_payment", "2027-01-04", %{
        "group_id" => "group-a",
        "amount_cents" => 300
      }),
      operation("rejected-payment", "record_cash_payment", "2027-01-05", %{
        "group_id" => "group-a",
        "amount_cents" => 301
      })
    ]

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => operations})
    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.at(results, 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2027-01-05"
           }

    assert Enum.at(results, 4)["code"] == "payment_exceeds_outstanding"

    assert get_json("/api/v1/finance/daily-report?date=2027-01-05") == %{
             "data" => %{
               "date" => "2027-01-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 400,
                   "movements" => cash_movements(%{"received_cents" => 300}),
                   "closing_held_cents" => 700
                 }
               ],
               "credit" => credit_report(0, %{}, 0)
             }
           }

    assert response_status("/api/v1/finance/daily-report", 422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert response_status("/api/v1/finance/daily-report?date=nope", 422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert response_status("/api/v1/finance/daily-report?date=2027-01-04", 404) ==
             %{"error" => %{"code" => "report_not_available"}}

    retry = Enum.at(operations, 2)

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [retry, retry]})
    assert %{"results" => [first, second]} = json_response(conn, 200)
    assert first == Enum.at(results, 2)
    assert second == first

    another = %{
      "operation_id" => "another-start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-06"
    }

    conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => [another]})

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             json_response(conn, 200)
  end

  test "reports transferred cash and later corrections at the property holding or settling it", %{
    conn: conn
  } do
    setup = [
      open("source", "guest", "a-property", 5_000),
      operation("payment", "record_cash_payment", "2027-01-02", %{
        "group_id" => "source",
        "amount_cents" => 800
      }),
      open("destination", "guest", "b-property", 5_000),
      start("2027-01-05")
    ]

    assert_all_applied(post_batch(conn, setup))

    movements = [
      operation("transfer", "transfer_deposit", "2027-01-05", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 300
      }),
      operation("reduce", "reduce_cash_payment", "2027-01-05", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 200
      }),
      operation("chargeback", "charge_back_payment", "2027-01-05", %{
        "payment_operation_id" => "payment"
      })
    ]

    assert_all_applied(post_batch(build_conn(), movements))

    assert %{"data" => %{"cash" => cash, "credit" => credit}} =
             get_json("/api/v1/finance/daily-report?date=2027-01-05")

    assert cash == [
             %{
               "property_id" => "a-property",
               "opening_held_cents" => 800,
               "movements" =>
                 cash_movements(%{
                   "transferred_out_cents" => 300,
                   "charged_back_cents" => 500
                 }),
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "b-property",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{
                   "transferred_in_cents" => 300,
                   "reduced_cents" => 200,
                   "charged_back_cents" => 100
                 }),
               "closing_held_cents" => 0
             }
           ]

    assert credit == credit_report(0, %{}, 0)
  end

  test "reports automatic expiry and expiry on restoration without changing state on reads", %{
    conn: conn
  } do
    operations = [
      open("source", "guest", "source-property", 5_000),
      operation("payment", "record_cash_payment", "2027-01-02", %{
        "group_id" => "source",
        "amount_cents" => 100
      }),
      operation("issue", "cancel_group", "2027-01-10", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open("target", "guest", "target-property", 5_000, %{
        "arrival_on" => "2028-12-01",
        "departure_on" => "2028-12-02"
      }),
      operation("apply", "apply_hotel_credit", "2027-01-11", %{
        "group_id" => "target",
        "amount_cents" => 40
      }),
      start("2027-01-05")
    ]

    assert_all_applied(post_batch(conn, operations))

    expiry_report = get_json("/api/v1/finance/daily-report?date=2028-01-11")

    assert expiry_report["data"]["credit"] ==
             credit_report(110, %{"expired_cents" => 70}, 40)

    assert get_json("/api/v1/finance/daily-report?date=2028-01-11") == expiry_report

    restore =
      operation("restore-expired", "cancel_group", "2028-01-12", %{
        "group_id" => "target"
      })

    assert_all_applied(post_batch(build_conn(), [restore]))

    assert get_json("/api/v1/finance/daily-report?date=2028-01-12")["data"]["credit"] ==
             credit_report(40, %{"expired_cents" => 40}, 0)
  end

  test "reports credit revocation reversals and shortfall absorption", %{conn: conn} do
    operations = [
      start("2027-01-01"),
      open("source", "guest", "source-property", 5_000),
      operation("payment", "record_cash_payment", "2027-01-02", %{
        "group_id" => "source",
        "amount_cents" => 100
      }),
      operation("issue", "cancel_group", "2027-01-10", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open("target", "guest", "target-property", 5_000, %{
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02"
      }),
      operation("apply", "apply_hotel_credit", "2027-01-11", %{
        "group_id" => "target",
        "amount_cents" => 110
      }),
      operation("chargeback", "charge_back_payment", "2027-01-12", %{
        "payment_operation_id" => "payment"
      }),
      operation("absorb", "cancel_group", "2027-01-13", %{"group_id" => "target"})
    ]

    assert_all_applied(post_batch(conn, operations))

    assert get_json("/api/v1/finance/daily-report?date=2027-01-12")["data"] == %{
             "date" => "2027-01-12",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "source-property",
                 "opening_held_cents" => 0,
                 "movements" =>
                   cash_movements(%{
                     "converted_to_credit_cents" => -100,
                     "charged_back_cents" => 100
                   }),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => credit_report(110, %{}, 110)
           }

    assert get_json("/api/v1/finance/daily-report?date=2027-01-13")["data"]["credit"] ==
             credit_report(110, %{"absorbed_cents" => 110}, 0)
  end

  defp start(starts_on) do
    %{
      "operation_id" => "start-#{starts_on}",
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open(group_id, guest_id, property_id, nightly_rate, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => property_id,
        "arrival_on" => "2027-05-01",
        "departure_on" => "2027-05-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
      },
      overrides
    )
  end

  defp operation(operation_id, type, occurred_on, fields) do
    Map.merge(
      %{"operation_id" => operation_id, "type" => type, "occurred_on" => occurred_on},
      fields
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp assert_all_applied(%{"results" => results}) do
    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  defp get_json(path) do
    build_conn()
    |> get(path)
    |> json_response(200)
  end

  defp response_status(path, status) do
    build_conn()
    |> get(path)
    |> json_response(status)
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

  defp credit_report(opening, overrides, closing) do
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
          overrides
        ),
      "closing_liability_cents" => closing
    }
  end
end
