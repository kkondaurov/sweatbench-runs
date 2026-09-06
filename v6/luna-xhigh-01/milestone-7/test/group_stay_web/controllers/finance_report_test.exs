defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "takes the opening position at start and posts later cash movements", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_group("open", "group-a", "property-a"),
               cash_payment("pay-before", "group-a", 100, "2026-12-20", 1)
             ])

    assert %{
             "results" => [
               %{
                 "operation_id" => "start",
                 "status" => "applied",
                 "starts_on" => "2027-01-01"
               }
             ]
           } = post_batch(conn, [start_reporting("start", "2027-01-01")])

    assert %{"results" => [%{"revision" => 3}]} =
             post_batch(conn, [cash_payment("pay-after", "group-a", 50, "2026-12-31", 2)])

    assert %{
             "data" => %{
               "date" => "2027-01-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "opening_held_cents" => 100,
                   "movements" => %{
                     "received_cents" => 50,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 150
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
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-01"), 200)

    assert %{"results" => [%{"refunded_cents" => 150, "revision" => 4}]} =
             post_batch(conn, [cancel("cancel", "group-a", "2027-01-10", 3)])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 100,
                   "movements" => %{"received_cents" => 50, "refunded_cents" => 150},
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-10"), 200)
  end

  test "rejects unavailable and malformed reports", %{conn: conn} do
    assert %{"error" => %{"code" => "report_not_available"}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-01"), 404)

    assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
             post_batch(conn, [start_reporting("bad-start", "not-a-date")])

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             json_response(get(conn, "/api/v1/finance/daily-report"), 422)
  end

  test "reports credit issuance and later consumption", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_group("source-open", "source", "property-a"),
               cash_payment("source-pay", "source", 100, "2026-12-20", 1)
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start_reporting("start-credit", "2027-01-01")])

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 3}]} =
             post_batch(conn, [
               open_group("target-open", "target", "property-b"),
               cancel("source-cancel", "source", "2027-01-01", 2)
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert %{"results" => [%{"revision" => 2, "outstanding_deposit_cents" => 90}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "credit-use",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "target",
                 "amount_cents" => 110,
                 "expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"revision" => 3}]} =
             post_batch(conn, [cancel("target-cancel", "target", "2027-02-10", 2)])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "opening_held_cents" => 100,
                   "movements" => %{"converted_to_credit_cents" => 100},
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
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-02"), 200)

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 110, "consumed_cents" => 110},
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-02-10"), 200)
  end

  test "follows held cash through transfers, reductions, and chargebacks", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}]} =
             post_batch(conn, [
               open_group("source-open", "source", "property-a"),
               open_group("destination-open", "destination", "property-b")
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start_reporting("start-cash", "2027-01-01")])

    assert %{"results" => [%{"revision" => 2}]} =
             post_batch(conn, [cash_payment("pay", "source", 100, "2027-01-01", 1)])

    assert %{
             "results" => [
               %{
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "transfer",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2027-01-02",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 60,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"revision" => 4}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2027-01-03",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 20,
                 "expected_revision" => 3
               }
             ])

    assert %{"results" => [%{"revision" => 5}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2027-01-04",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 4
               }
             ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "movements" => %{
                     "received_cents" => 100,
                     "transferred_out_cents" => 60,
                     "charged_back_cents" => 40
                   },
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "property-b",
                   "movements" => %{
                     "transferred_in_cents" => 60,
                     "reduced_cents" => 20,
                     "charged_back_cents" => 40
                   },
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-04"), 200)
  end

  test "reports credit expiry on the day after its expiry date", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_group("open-expiry", "expiry-group", "property-a"),
               cash_payment("pay-expiry", "expiry-group", 100, "2026-12-20", 1)
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start_reporting("start-expiry", "2027-01-01")])

    assert %{"results" => [%{"credit_issued_cents" => 110}]} =
             post_batch(conn, [
               cancel("cancel-expiry", "expiry-group", "2027-01-01", 2)
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 110, "expired_cents" => 0},
                 "closing_liability_cents" => 110
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2028-01-01"), 200)

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{"issued_cents" => 110, "expired_cents" => 110},
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2028-01-02"), 200)

    assert %{"results" => [%{"charged_back_cents" => 100, "revision" => 4}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "chargeback-expired",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2028-01-03",
                 "payment_operation_id" => "pay-expiry",
                 "expected_revision" => 3
               }
             ])

    assert %{
             "data" => %{
               "credit" => %{
                 "movements" => %{
                   "issued_cents" => 110,
                   "expired_cents" => 110,
                   "revoked_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2028-01-03"), 200)
  end

  test "reverses a pre-reporting refund when its payment is charged back", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open_group("open-pre-refund", "pre-refund", "property-a"),
               cash_payment("pay-pre-refund", "pre-refund", 100, "2026-11-01", 1),
               cancel("cancel-pre-refund", "pre-refund", "2026-12-01", 2)
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start_reporting("start-pre-refund", "2027-01-01")])

    assert %{"results" => [%{"charged_back_cents" => 100, "revision" => 4}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "chargeback-pre-refund",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2027-01-02",
                 "payment_operation_id" => "pay-pre-refund",
                 "expected_revision" => 3
               }
             ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "refunded_cents" => -100,
                     "charged_back_cents" => 100
                   },
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-02"), 200)
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_group(operation_id, group_id, property_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-a",
      "property_id" => property_id,
      "arrival_on" => "2027-02-01",
      "departure_on" => "2027-02-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1_000}]
    }
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

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp cancel(operation_id, group_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
  end
end
