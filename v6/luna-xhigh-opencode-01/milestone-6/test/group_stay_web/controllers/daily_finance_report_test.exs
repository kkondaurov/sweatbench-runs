defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "starts from the committed position and posts later operations on the start date", %{
    conn: conn
  } do
    submit(conn, [open_group("group-1", "2026-01-01", "2026-02-10", "property-1")])
    submit(conn, [payment("pay-before", "group-1", 5_000, "2026-01-02")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "start-1",
                 "status" => "applied",
                 "starts_on" => "2026-01-10"
               },
               %{"operation_id" => "pay-after", "status" => "applied"}
             ]
           } =
             submit(conn, [
               start_reporting("start-1", "2026-01-10"),
               payment("pay-after", "group-1", 3_000, "2026-01-05")
             ])

    assert %{"error" => %{"code" => "report_not_available"}} =
             get_report(conn, "2026-01-09", 404)

    assert %{
             "data" => %{
               "date" => "2026-01-10",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "property-1",
                   "opening_held_cents" => 5_000,
                   "movements" => %{
                     "received_cents" => 3_000,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 8_000
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
           } = get_report(conn, "2026-01-10")

    assert %{"data" => first_report} = get_report(conn, "2026-01-10")
    assert %{"data" => ^first_report} = get_report(conn, "2026-01-10")
  end

  test "reports transfer and settlement effects at the affected properties", %{conn: conn} do
    submit(conn, [open_group("source", "2026-01-01", "2026-02-10", "property-a")])
    submit(conn, [open_group("destination", "2026-01-01", "2026-02-10", "property-b")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-1", "source", 6_000, "2026-01-02")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [transfer("transfer-1", "source", "destination", 2_000)])

    assert %{"results" => [%{"refunded_cents" => 2_000}]} =
             submit(conn, [cancel("cancel-1", "destination", "2026-01-04")])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "movements" => %{"transferred_out_cents" => 2_000},
                   "closing_held_cents" => 4_000
                 },
                 %{
                   "property_id" => "property-b",
                   "movements" => %{"transferred_in_cents" => 2_000},
                   "closing_held_cents" => 2_000
                 }
               ]
             }
           } = get_report(conn, "2026-01-03")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "closing_held_cents" => 4_000
                 },
                 %{
                   "property_id" => "property-b",
                   "movements" => %{"refunded_cents" => 2_000},
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = get_report(conn, "2026-01-04")
  end

  test "shows credit expiry without changing domain state", %{conn: conn} do
    submit(conn, [open_group("source", "2026-01-01", "2026-02-01", "property-1")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-1", "source", 2_000, "2026-01-02")])

    assert %{"results" => [%{"credit_issued_cents" => 2_200}]} =
             submit(conn, [cancel("cancel-1", "source", "2026-01-03") |> hotel_credit()])

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 2_200, "expired_cents" => 0},
                 "closing_liability_cents" => 2_200
               }
             }
           } = get_report(conn, "2026-01-03")

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 0, "expired_cents" => 2_200},
                 "closing_liability_cents" => 0
               }
             }
           } = get_report(conn, "2027-01-04")

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} = get_credit(conn, "guest-1")
  end

  test "carries opening credit through application and later consumption", %{conn: conn} do
    submit(conn, [open_group("source", "2026-01-01", "2026-02-01", "property-1")])
    submit(conn, [payment("pay-1", "source", 2_000, "2026-01-02")])
    submit(conn, [cancel("cancel-1", "source", "2026-01-03") |> hotel_credit()])
    submit(conn, [start_reporting("start-1", "2026-01-10")])

    submit(conn, [open_group("target", "2026-01-10", "2026-02-10", "property-2") |> advance()])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [credit_payment("apply-1", "target", 1_000, "2026-01-11")])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 2_200,
                 "movements" => %{"issued_cents" => 0, "consumed_cents" => 0},
                 "closing_liability_cents" => 2_200
               }
             }
           } = get_report(conn, "2026-01-11")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [cancel("cancel-target", "target", "2026-01-12")])

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"consumed_cents" => 1_000},
                 "closing_liability_cents" => 1_200
               }
             }
           } = get_report(conn, "2026-01-12")
  end

  test "reports reductions and chargebacks where held cash is currently allocated", %{conn: conn} do
    submit(conn, [open_group("source", "2026-01-01", "2026-02-10", "property-a")])
    submit(conn, [open_group("destination", "2026-01-01", "2026-02-10", "property-b")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-1", "source", 6_000, "2026-01-02")])
    submit(conn, [transfer("transfer-1", "source", "destination", 2_000)])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [reduce("reduce-1", "pay-1", 1_000, "2026-01-04")])

    assert %{"results" => [%{"charged_back_cents" => 5_000}]} =
             submit(conn, [chargeback("chargeback-1", "pay-1", "2026-01-05")])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "movements" => %{"charged_back_cents" => 4_000},
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "property-b",
                   "movements" => %{"charged_back_cents" => 1_000},
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = get_report(conn, "2026-01-05")

    assert %{
             "data" => %{
               "cash" => [
                 %{"property_id" => "property-a", "closing_held_cents" => 4_000},
                 %{
                   "property_id" => "property-b",
                   "movements" => %{"reduced_cents" => 1_000},
                   "closing_held_cents" => 1_000
                 }
               ]
             }
           } = get_report(conn, "2026-01-04")
  end

  test "reverses refund and credit issuance classifications on a chargeback", %{conn: conn} do
    submit(conn, [open_group("source", "2026-01-01", "2026-02-01", "property-1")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-1", "source", 2_000, "2026-01-02")])
    submit(conn, [cancel("cancel-1", "source", "2026-01-03") |> hotel_credit()])

    assert %{"results" => [%{"charged_back_cents" => 2_000}]} =
             submit(conn, [chargeback("chargeback-1", "pay-1", "2026-01-04")])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-1",
                   "movements" => %{
                     "refunded_cents" => 0,
                     "converted_to_credit_cents" => -2_000,
                     "charged_back_cents" => 2_000
                   },
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "movements" => %{"issued_cents" => 0, "revoked_cents" => 2_200},
                 "closing_liability_cents" => 0
               }
             }
           } = get_report(conn, "2026-01-04")
  end

  test "validates reporting dates and does not allow a second inception", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
             submit(conn, [start_reporting("bad", "not-a-date")])

    assert %{"results" => [%{"starts_on" => "2026-01-01"}]} =
             submit(conn, [start_reporting("start-1", "2026-01-01")])

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             submit(conn, [start_reporting("start-2", "2026-01-02")])

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get_report(conn, "2026-01-40", 422)
  end

  defp open_group(group_id, booked_on, arrival_on, property_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => booked_on,
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => arrival_on,
      "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 1) |> Date.to_iso8601(),
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100_000}]
    }
  end

  defp payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-01-03",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce(operation_id, payment_operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp chargeback(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp credit_payment(operation_id, group_id, amount_cents, occurred_on) do
    payment(operation_id, group_id, amount_cents, occurred_on)
    |> Map.put("type", "apply_hotel_credit")
  end

  defp advance(operation), do: Map.put(operation, "rate_plan", "advance_purchase")

  defp cancel(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp hotel_credit(operation), do: Map.put(operation, "refund_method", "hotel_credit")

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_report(conn, date, status \\ 200) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(status)
  end

  defp get_credit(conn, guest_id) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=2027-01-04")
    |> json_response(200)
  end
end
