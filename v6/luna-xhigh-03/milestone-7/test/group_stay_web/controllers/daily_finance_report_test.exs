defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-group",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-15",
        "departure_on" => "2027-04-16",
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
    |> json_response(200)
  end

  test "starts from the current position and reports cash by posting date", %{conn: conn} do
    post_batch(conn, [operation()])

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-before-start",
        "type" => "record_cash_payment",
        "amount_cents" => 1_000,
        "occurred_on" => "2027-01-02"
      })
    ])

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(404)

    assert %{"results" => [%{"starts_on" => "2027-01-03"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reporting-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-01-03"
               }
             ])

    assert %{"results" => [%{"status" => "rejected", "code" => "reporting_already_started"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "other-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-01-03"
               }
             ])

    assert %{"data" => report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
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

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-after-start",
        "type" => "record_cash_payment",
        "amount_cents" => 500,
        "occurred_on" => "2027-01-04"
      })
    ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 1_000,
                   "closing_held_cents" => 1_500,
                   "movements" => %{"received_cents" => 500}
                 }
               ]
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-04") |> json_response(200)
  end

  test "reports credit conversion and expiry without requiring an operation on expiry day", %{
    conn: conn
  } do
    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      operation(),
      operation(%{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "amount_cents" => 1_000
      }),
      operation(%{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "refund_method" => "hotel_credit"
      })
    ])

    assert %{"data" => %{"cash" => [%{"movements" => cash_movements}], "credit" => credit}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert cash_movements["converted_to_credit_cents"] == 1_000
    assert cash_movements["received_cents"] == 0

    assert credit["movements"] == %{
             "issued_cents" => 1_100,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert %{"data" => %{"credit" => credit}} =
             get(conn, "/api/v1/finance/daily-report?date=2028-01-03") |> json_response(200)

    assert credit["opening_liability_cents"] == 1_100
    assert credit["movements"]["expired_cents"] == 1_100
    assert credit["closing_liability_cents"] == 0
  end

  test "requires an ISO reporting date", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report?date=tomorrow") |> json_response(422)
  end

  test "reverses a refund on the property where it was settled", %{conn: conn} do
    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      operation(),
      operation(%{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "amount_cents" => 1_000
      }),
      operation(%{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02"
      })
    ])

    assert %{"data" => %{"cash" => [%{"movements" => movements}]}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert movements["refunded_cents"] == 1_000

    post_batch(conn, [
      operation(%{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay",
        "occurred_on" => "2027-01-03"
      })
    ])

    assert %{
             "data" => %{
               "cash" => [
                 %{"opening_held_cents" => 0, "movements" => movements, "closing_held_cents" => 0}
               ]
             }
           } =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)

    assert movements["refunded_cents"] == -1_000
    assert movements["charged_back_cents"] == 1_000
  end

  test "reports transfer directions and follows a later reduction", %{conn: conn} do
    source = operation(%{"group_id" => "source", "property_id" => "ams-canal"})

    destination =
      operation(%{
        "operation_id" => "open-destination",
        "group_id" => "destination",
        "property_id" => "rotterdam-centre",
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 10_000}]
      })

    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      source,
      destination,
      operation(%{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-02",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 500
      }
    ])

    assert %{"data" => %{"cash" => cash}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert [
             %{"property_id" => "ams-canal", "movements" => %{"transferred_out_cents" => 500}},
             %{
               "property_id" => "rotterdam-centre",
               "movements" => %{"transferred_in_cents" => 500}
             }
           ] = cash

    post_batch(conn, [
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2027-01-03",
        "payment_operation_id" => "pay",
        "amount_cents" => 500
      }
    ])

    assert %{"data" => %{"cash" => cash}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)

    assert Enum.find(cash, &(&1["property_id"] == "rotterdam-centre"))["movements"][
             "reduced_cents"
           ] == 500
  end
end
