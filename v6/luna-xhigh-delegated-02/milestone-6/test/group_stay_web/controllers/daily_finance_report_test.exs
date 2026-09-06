defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp batch(conn, operations) do
    json_post(conn, %{"operations" => operations}) |> json_response(200)
  end

  defp open_operation(group_id, operation_id, property_id \\ "ams-canal") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "#{group_id}-room", "nightly_rate_cents" => 500}]
    }
  end

  defp report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}") |> json_response(200)
  end

  test "starts reporting at a durable batch boundary and reports property cash movements", %{
    conn: conn
  } do
    assert %{"results" => [_, payment, start]} =
             batch(conn, [
               open_operation("group-81", "open-1"),
               %{
                 "operation_id" => "pay-before-start",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-20",
                 "group_id" => "group-81",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-03"
               }
             ])

    assert payment["status"] == "applied"

    assert start == %{
             "operation_id" => "start-1",
             "status" => "applied",
             "starts_on" => "2026-10-03"
           }

    assert %{"results" => [_, transfer]} =
             batch(conn, [
               open_operation("group-82", "open-2", "rotterdam"),
               %{
                 "operation_id" => "transfer-1",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-82",
                 "amount_cents" => 40
               }
             ])

    assert transfer["status"] == "applied"

    assert report(conn, "2026-10-03") == %{
             "data" => %{
               "date" => "2026-10-03",
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
               }
             }
           }

    assert report(conn, "2026-10-05") == %{
             "data" => %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 40,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 60
                 },
                 %{
                   "property_id" => "rotterdam",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 0,
                     "transferred_in_cents" => 40,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 40
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
               }
             }
           }
  end

  test "clamps backdated postings, replays starts idempotently, and keeps reads pure", %{
    conn: conn
  } do
    start = %{
      "operation_id" => "start-1",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-10"
    }

    assert %{"results" => [applied]} = batch(conn, [start])
    assert batch(conn, [start]) == %{"results" => [applied]}

    assert batch(conn, [
             %{
               "operation_id" => "start-2",
               "type" => "start_finance_reporting",
               "starts_on" => "2026-10-11"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "start-2",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-01",
      "group_id" => "group-81",
      "amount_cents" => 100
    }

    assert %{"results" => [_, _]} =
             batch(conn, [open_operation("group-81", "open-1"), payment])

    assert get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-09")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    first = report(conn, "2026-10-10")
    second = report(conn, "2026-10-10")
    assert first == second

    assert first["data"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 100,
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
           ]
  end

  test "reports credit issuance, consumption, and expiry without read side effects", %{conn: conn} do
    assert %{"results" => [_, _, _, _]} =
             batch(conn, [
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-01"
               },
               open_operation("source", "open-source"),
               %{
                 "operation_id" => "pay-source",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "source",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "cancel-source",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert report(conn, "2026-10-03")["data"]["credit"] == %{
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

    assert %{"results" => [_, _, _]} =
             batch(conn, [
               open_operation("target", "open-target", "rotterdam"),
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "target",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "target"
               }
             ])

    assert report(conn, "2026-12-01")["data"]["credit"] == %{
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

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-10-03")
           |> json_response(200)

    expires_on = Date.add(~D[2026-10-03], 366) |> Date.to_iso8601()

    assert report(conn, expires_on)["data"]["credit"]["movements"]["expired_cents"] == 10
  end

  test "follows a transferred payment to its settlement property and reverses a refund", %{
    conn: conn
  } do
    assert %{"results" => [_, _, _, _, _]} =
             batch(conn, [
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-01"
               },
               open_operation("source", "open-source"),
               open_operation("target", "open-target", "rotterdam"),
               %{
                 "operation_id" => "pay-source",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "source",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "transfer-1",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-03",
                 "source_group_id" => "source",
                 "destination_group_id" => "target",
                 "amount_cents" => 100
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "target"
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "pay-source"
               }
             ])

    assert report(conn, "2026-10-04")["data"]["cash"] == [
             %{
               "property_id" => "rotterdam",
               "opening_held_cents" => 100,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 100,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert report(conn, "2026-10-05")["data"]["cash"] == [
             %{
               "property_id" => "rotterdam",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -100,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 100
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "reverses converted cash and its credit liability on a chargeback", %{conn: conn} do
    assert %{"results" => [_, _, _, _]} =
             batch(conn, [
               %{
                 "operation_id" => "start-1",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-01"
               },
               open_operation("source", "open-source"),
               %{
                 "operation_id" => "pay-source",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "source",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "cancel-source",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             batch(conn, [
               %{
                 "operation_id" => "chargeback-source",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-04",
                 "payment_operation_id" => "pay-source"
               }
             ])

    assert report(conn, "2026-10-04")["data"] == %{
             "date" => "2026-10-04",
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
                   "converted_to_credit_cents" => -100,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 100
                 },
                 "closing_held_cents" => 0
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 110,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 110,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }
           }
  end

  test "returns the reporting-specific validation errors", %{conn: conn} do
    assert get(conn, "/api/v1/finance/daily-report") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert get(conn, "/api/v1/finance/daily-report?date=not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert batch(conn, [
             %{
               "operation_id" => "bad-start",
               "type" => "start_finance_reporting",
               "starts_on" => "nope"
             }
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "bad-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }
  end
end
