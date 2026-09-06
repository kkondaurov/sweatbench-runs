defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "closes reports, freezes them, and posts old-dated operations as late adjustments", %{
    conn: conn
  } do
    post_batch(conn, [open_operation("period-group", "2026-10-01")])

    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      cash_payment("before-close", "period-group", 40, "2026-10-01")
    ])

    close = %{
      "operation_id" => "close-2026-10-02",
      "type" => "close_finance_period",
      "period_end_on" => "2026-10-02"
    }

    assert post_batch(conn, [close]) == %{
             "results" => [
               %{
                 "operation_id" => "close-2026-10-02",
                 "status" => "applied",
                 "period_end_on" => "2026-10-02"
               }
             ]
           }

    closed_before =
      conn
      |> get("/api/v1/finance/daily-report?date=2026-10-02")
      |> json_response(200)

    assert closed_before["data"]["status"] == "closed"
    assert closed_before["data"]["late_adjustments"]["cash"] == []

    assert post_batch(conn, [close]) == %{
             "results" => [
               %{
                 "operation_id" => "close-2026-10-02",
                 "status" => "applied",
                 "period_end_on" => "2026-10-02"
               }
             ]
           }

    assert post_batch(conn, [
             %{
               "operation_id" => "close-again",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-02"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-again",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    late_payment = cash_payment("after-close-old-date", "period-group", 20, "2026-10-01")
    post_batch(conn, [late_payment])

    assert closed_before ==
             conn
             |> get("/api/v1/finance/daily-report?date=2026-10-02")
             |> json_response(200)

    assert %{"data" => report} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-03"), 200)

    assert report["status"] == "open"

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
               "closing_held_cents" => 60
             }
           ]

    assert report["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   "received_cents" => 20,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 }
               }
             ],
             "credit" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
           }
  end

  test "rejects closes before reporting and at or before the latest cutoff", %{conn: conn} do
    assert post_batch(conn, [
             %{
               "operation_id" => "close-before-start",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-01"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-02"
      }
    ])

    assert post_batch(conn, [
             %{
               "operation_id" => "close-before-start-date",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-01"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start-date",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    post_batch(conn, [
      %{
        "operation_id" => "close-first",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-03"
      }
    ])

    assert post_batch(conn, [
             %{
               "operation_id" => "close-equal",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-03"
             },
             %{
               "operation_id" => "close-earlier",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-02"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-equal",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "close-earlier",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }
  end

  test "late cancellation effects are separated for cash and credit", %{conn: conn} do
    post_batch(conn, [
      open_operation("late-credit", "2026-10-01"),
      cash_payment("late-credit-payment", "late-credit", 100, "2026-10-01"),
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "close-before-cancel",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-02"
      },
      %{
        "operation_id" => "late-credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-01",
        "group_id" => "late-credit",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{"data" => report} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-03"), 200)

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 100,
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
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 100,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
           ]

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 110,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end

  test "sequential closes publish only the newly open reports", %{conn: conn} do
    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      %{
        "operation_id" => "close-first",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-02"
      }
    ])

    first_report =
      conn
      |> get("/api/v1/finance/daily-report?date=2026-10-01")
      |> json_response(200)

    assert first_report["data"]["status"] == "closed"

    assert post_batch(conn, [
             %{
               "operation_id" => "close-second",
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-04"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "close-second",
                 "status" => "applied",
                 "period_end_on" => "2026-10-04"
               }
             ]
           }

    assert first_report ==
             conn
             |> get("/api/v1/finance/daily-report?date=2026-10-01")
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-04"), 200)["data"][
             "status"
           ] == "closed"

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-05"), 200)["data"] ==
             %{
               "date" => "2026-10-05",
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
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(group_id, occurred_on) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
