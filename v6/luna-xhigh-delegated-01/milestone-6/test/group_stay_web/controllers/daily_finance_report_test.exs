defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  test "starts from the committed position and posts later same-batch operations", %{conn: conn} do
    submit(conn, [open_operation()])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "payment-before-start",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "group-1",
                 "amount_cents" => 500
               }
             ])

    assert %{"results" => [%{"starts_on" => "2026-10-03"}, %{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-03"
               },
               %{
                 "operation_id" => "payment-after-start",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-1",
                 "amount_cents" => 300
               }
             ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200)

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 500,
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
               "closing_held_cents" => 500
             }
           ]

    assert %{"data" => next_report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200)

    assert hd(next_report["cash"])["opening_held_cents"] == 500
    assert hd(next_report["cash"])["movements"]["received_cents"] == 300
    assert hd(next_report["cash"])["closing_held_cents"] == 800
  end

  test "reports credit issuance and expiry without an expiry operation", %{conn: conn} do
    submit(conn, [
      open_operation(),
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "group-1",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200)

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 500,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 500,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert report["credit"]["movements"] == %{
             "issued_cents" => 550,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert %{"data" => expired_report} =
             conn
             |> get("/api/v1/finance/daily-report?date=2027-10-05")
             |> json_response(200)

    assert expired_report["credit"]["movements"]["expired_cents"] == 550
    assert expired_report["credit"]["closing_liability_cents"] == 0
  end

  test "invalid and unavailable report dates are rejected without state changes", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             conn |> get("/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             conn
             |> get("/api/v1/finance/daily-report?date=2026-10-01")
             |> json_response(404)

    assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
             submit(conn, [
               %{
                 "operation_id" => "bad-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "not-a-date"
               }
             ])
  end

  test "follows transferred cash to its settlement property and reverses refunds on chargeback",
       %{
         conn: conn
       } do
    submit(conn, [
      open_operation(),
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "group-2",
        "property_id" => "rotterdam"
      }),
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "group-1",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-03",
        "source_group_id" => "group-1",
        "destination_group_id" => "group-2",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-2"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200)

    assert report["cash"] == [
             %{
               "property_id" => "rotterdam",
               "opening_held_cents" => 20,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 20,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert %{"results" => [%{"charged_back_cents" => 20}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

    assert hd(report["cash"])["property_id"] == "rotterdam"
    assert hd(report["cash"])["movements"]["refunded_cents"] == -20
    assert hd(report["cash"])["movements"]["charged_back_cents"] == 20
    assert hd(report["cash"])["closing_held_cents"] == 0
  end

  test "reports credit restored after its expiry as expired, not consumed", %{conn: conn} do
    submit(conn, [
      open_operation(%{"group_id" => "credit-source"}),
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-source",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "arrival_on" => "2028-12-10",
        "departure_on" => "2028-12-11"
      }),
      %{
        "operation_id" => "apply-before-start",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => "target",
        "amount_cents" => 20
      },
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-11-03"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2027-11-03") |> json_response(200)

    assert report["credit"]["opening_liability_cents"] == 20
    assert report["credit"]["closing_liability_cents"] == 20

    submit(conn, [
      %{
        "operation_id" => "target-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-11-04",
        "group_id" => "target"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2027-11-04") |> json_response(200)

    assert report["credit"]["movements"]["expired_cents"] == 20
    assert report["credit"]["movements"]["consumed_cents"] == 0
    assert report["credit"]["closing_liability_cents"] == 0
  end

  test "keeps cash movement classifications balanced through reduction and chargeback", %{
    conn: conn
  } do
    submit(conn, [
      open_operation(),
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "group-1",
        "amount_cents" => 800
      },
      %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-03",
        "payment_operation_id" => "payment-1",
        "amount_cents" => 200
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-11-01") |> json_response(200)

    entry = hd(report["cash"])
    assert entry["opening_held_cents"] == 600
    assert entry["movements"]["reduced_cents"] == 0
    assert entry["movements"]["refunded_cents"] == 600
    assert entry["closing_held_cents"] == 0

    assert %{"results" => [%{"charged_back_cents" => 600}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-11-02",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-11-02") |> json_response(200)

    entry = hd(report["cash"])
    assert entry["movements"]["refunded_cents"] == -600
    assert entry["movements"]["charged_back_cents"] == 600
    assert entry["closing_held_cents"] == 0
  end
end
