defmodule GroupStayWeb.PeriodCloseTest do
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
        "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 1_000}]
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

  test "validates, durably replays, and advances finance periods", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [
               %{
                 "operation_id" => "close-before-start",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-01"
               }
             ])

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             submit(conn, [
               open_operation(),
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-01"
               }
             ])

    close = %{
      "operation_id" => "close-1",
      "type" => "close_finance_period",
      "period_end_on" => "2026-10-02"
    }

    assert %{"results" => [first]} = submit(conn, [close])

    assert first == %{
             "operation_id" => "close-1",
             "period_end_on" => "2026-10-02",
             "status" => "applied"
           }

    assert %{"results" => [^first]} = submit(conn, [close])

    assert %{
             "results" => [
               %{"code" => "invalid_period"},
               %{"code" => "invalid_period"}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "close-same",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-02"
               },
               %{
                 "operation_id" => "close-earlier",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-01"
               }
             ])

    assert %{"data" => %{"status" => "closed"}} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-01") |> json_response(200)

    assert %{"data" => %{"status" => "closed"}} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200)

    assert %{"data" => %{"status" => "open"}} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200)

    assert %{"results" => [%{"period_end_on" => "2026-10-04"}]} =
             submit(conn, [
               %{
                 "operation_id" => "close-2",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-04"
               }
             ])

    assert %{"data" => %{"status" => "closed"}} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(200)
  end

  test "freezes closed report data and identifies late adjustments", %{conn: conn} do
    close = %{
      "operation_id" => "close-1",
      "type" => "close_finance_period",
      "period_end_on" => "2026-10-01"
    }

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
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1",
        "amount_cents" => 100
      },
      close,
      %{
        "operation_id" => "payment-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1",
        "amount_cents" => 50
      }
    ])

    closed_before =
      conn |> get("/api/v1/finance/daily-report?date=2026-10-01") |> json_response(200)

    assert closed_before["data"]["status"] == "closed"
    assert closed_before["data"]["cash"] |> hd() |> get_in(["movements", "received_cents"]) == 100

    closed_after =
      conn |> get("/api/v1/finance/daily-report?date=2026-10-01") |> json_response(200)

    assert closed_after["data"] == closed_before["data"]

    assert %{"data" => late_report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200)

    assert late_report["status"] == "open"
    assert hd(late_report["cash"])["movements"]["received_cents"] == 0
    assert late_report["cash"] |> hd() |> get_in(["closing_held_cents"]) == 150

    assert late_report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => %{
                 "received_cents" => 50,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
           ]

    assert late_report["late_adjustments"]["credit"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    submit(conn, [
      %{
        "operation_id" => "close-2",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-02"
      }
    ])

    closed_late =
      conn |> get("/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200)

    assert closed_late["data"]["status"] == "closed"
    assert closed_late["data"]["late_adjustments"] == late_report["late_adjustments"]
  end

  test "keeps signed net-zero late cash classifications visible", %{conn: conn} do
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
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1"
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-01"
      }
    ])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-01",
                 "payment_operation_id" => "payment-1",
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2026-10-02") |> json_response(200)

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
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
           ]

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -100,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 100
               }
             }
           ]
  end

  test "posts an expired late credit issuance on the first open day", %{conn: conn} do
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
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2027-10-02"
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2027-10-03") |> json_response(200)

    assert report["credit"]["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 110,
             "expired_cents" => 110,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report["credit"]["closing_liability_cents"] == 0
  end

  test "reports a late credit application that reverses a closed expiry", %{conn: conn} do
    submit(conn, [
      open_operation(%{"operation_id" => "source-open", "group_id" => "source"}),
      open_operation(%{
        "operation_id" => "target-open",
        "group_id" => "target",
        "property_id" => "rotterdam"
      }),
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2027-10-02"
      }
    ])

    submit(conn, [
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-01",
        "group_id" => "target",
        "amount_cents" => 100
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2027-10-03") |> json_response(200)

    assert report["credit"]["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 0,
             "expired_cents" => -100,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report["credit"]["opening_liability_cents"] == 0
    assert report["credit"]["closing_liability_cents"] == 100
  end

  test "reports late restoration of credit that expired in a closed period", %{conn: conn} do
    submit(conn, [
      open_operation(%{"operation_id" => "source-open", "group_id" => "source"}),
      open_operation(%{
        "operation_id" => "target-open",
        "group_id" => "target",
        "property_id" => "rotterdam"
      }),
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-01",
        "group_id" => "target",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2027-10-02"
      }
    ])

    submit(conn, [
      %{
        "operation_id" => "target-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "target"
      }
    ])

    assert %{"data" => report} =
             conn |> get("/api/v1/finance/daily-report?date=2027-10-03") |> json_response(200)

    assert report["credit"]["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 0,
             "expired_cents" => 100,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report["credit"]["opening_liability_cents"] == 100
    assert report["credit"]["closing_liability_cents"] == 0
  end
end
