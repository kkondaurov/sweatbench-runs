defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp batch(conn, operations) do
    json_post(conn, %{"operations" => operations}) |> json_response(200)
  end

  defp open_operation(group_id, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "#{group_id}-room", "nightly_rate_cents" => 1000}]
    }
  end

  defp start_operation(operation_id \\ "start-1", starts_on \\ "2026-10-01") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}") |> json_response(200)
  end

  test "closes reports durably and requires a strictly later cutoff", %{conn: conn} do
    assert batch(conn, [close_operation("close-before-start", "2026-10-01")]) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert batch(conn, [start_operation(), close_operation("close-1", "2026-10-02")]) == %{
             "results" => [
               %{
                 "operation_id" => "start-1",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               },
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-10-02"
               }
             ]
           }

    assert batch(conn, [close_operation("close-1", "2026-10-02")]) == %{
             "results" => [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-10-02"
               }
             ]
           }

    assert batch(conn, [close_operation("close-same", "2026-10-02")]) == %{
             "results" => [
               %{
                 "operation_id" => "close-same",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert batch(conn, [close_operation("close-earlier", "2026-10-01")]) == %{
             "results" => [
               %{
                 "operation_id" => "close-earlier",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert report(conn, "2026-10-01")["data"]["status"] == "closed"
    assert report(conn, "2026-10-02")["data"]["status"] == "closed"
    assert report(conn, "2026-10-03")["data"]["status"] == "open"
  end

  test "freezes a report and posts old-dated later effects in the first open day", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             batch(conn, [open_operation("group-81", "open-1"), start_operation()])

    assert batch(conn, [close_operation("close-1", "2026-10-01")])

    before = report(conn, "2026-10-01")
    assert before["data"]["status"] == "closed"
    assert before["data"]["cash"] == []

    assert batch(conn, [
             %{
               "operation_id" => "pay-late",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-01",
               "group_id" => "group-81",
               "amount_cents" => 100
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "pay-late",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 100,
                 "outstanding_deposit_cents" => 100,
                 "revision" => 2
               }
             ]
           }

    assert report(conn, "2026-10-01") == before

    assert report(conn, "2026-10-02")["data"] == %{
             "date" => "2026-10-02",
             "status" => "open",
             "cash" => [
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
                 "closing_held_cents" => 100
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
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{
                     "received_cents" => 100,
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
           }
  end

  test "an extended close publishes new dates without rewriting an older snapshot", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             batch(conn, [open_operation("group-81", "open-1"), start_operation()])

    assert batch(conn, [close_operation("close-1", "2026-10-01")])
    original = report(conn, "2026-10-01")

    assert batch(conn, [
             %{
               "operation_id" => "pay-1",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-02",
               "group_id" => "group-81",
               "amount_cents" => 100
             },
             close_operation("close-2", "2026-10-03")
           ])

    assert report(conn, "2026-10-01") == original
    assert report(conn, "2026-10-02")["data"]["status"] == "closed"
    assert report(conn, "2026-10-03")["data"]["status"] == "closed"
    assert report(conn, "2026-10-04")["data"]["status"] == "open"
  end

  test "classifies a late cancellation's cash and credit effects as adjustments", %{conn: conn} do
    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ]
           } =
             batch(conn, [
               start_operation(),
               open_operation("group-81", "open-1"),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-01",
                 "group_id" => "group-81",
                 "amount_cents" => 100
               }
             ])

    assert batch(conn, [close_operation("close-1", "2026-10-02")])

    assert batch(conn, [
             %{
               "operation_id" => "cancel-1",
               "type" => "cancel_group",
               "occurred_on" => "2026-10-01",
               "group_id" => "group-81",
               "refund_method" => "hotel_credit"
             }
           ])

    data = report(conn, "2026-10-03")["data"]

    assert data["late_adjustments"] == %{
             "cash" => [
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
             ],
             "credit" => %{
               "issued_cents" => 110,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
           }

    assert data["cash"] == [
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

    assert data["credit"]["closing_liability_cents"] == 110
  end

  test "keeps signed late refund reversals visible by classification", %{conn: conn} do
    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ]
           } =
             batch(conn, [
               start_operation(),
               open_operation("group-81", "open-1"),
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-01",
                 "group_id" => "group-81",
                 "amount_cents" => 100
               }
             ])

    assert batch(conn, [
             %{
               "operation_id" => "cancel-1",
               "type" => "cancel_group",
               "occurred_on" => "2026-10-02",
               "group_id" => "group-81"
             },
             close_operation("close-1", "2026-10-02")
           ])

    assert batch(conn, [
             %{
               "operation_id" => "chargeback-1",
               "type" => "charge_back_payment",
               "occurred_on" => "2026-10-02",
               "payment_operation_id" => "pay-1"
             }
           ])

    assert report(conn, "2026-10-03")["data"]["late_adjustments"] == %{
             "cash" => [
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

  test "rejects malformed close dates as invalid periods without confusing the operation id", %{
    conn: conn
  } do
    assert batch(conn, [
             %{
               "type" => "close_finance_period",
               "period_end_on" => "2026-10-01"
             },
             %{
               "operation_id" => "bad-date",
               "type" => "close_finance_period",
               "period_end_on" => "not-a-date"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => nil,
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "bad-date",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }
  end
end
