defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "starts reporting from the committed position and posts later effects", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-09-30"), 404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert json_response(get(conn, "/api/v1/finance/daily-report"), 422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=not-a-date"), 422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert %{"results" => [open, payment, started]} =
             post_batch(conn, [
               open_operation("reporting", "2026-10-02"),
               cash_payment("before-start", "reporting", 40, "2026-10-03"),
               %{
                 "operation_id" => "reporting-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-01"
               }
             ])

    assert open["status"] == "applied"
    assert payment["status"] == "applied"

    assert started == %{
             "operation_id" => "reporting-start",
             "status" => "applied",
             "starts_on" => "2026-10-01"
           }

    after_start = cash_payment("after-start", "reporting", 20, "2026-09-01")
    assert %{"results" => [applied]} = post_batch(conn, [after_start])
    assert applied["revision"] == 3
    assert post_batch(conn, [after_start]) == %{"results" => [applied]}

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-09-30"), 404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-01"), 200) ==
             %{
               "data" => %{
                 "date" => "2026-10-01",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 40,
                     "movements" => %{
                       "received_cents" => 20,
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
             }
  end

  test "reports refunds, credit issuance, and automatic expiry", %{conn: conn} do
    post_batch(conn, [
      open_operation("credit-reporting", "2026-10-01"),
      cash_payment("credit-payment", "credit-reporting", 100, "2026-10-02"),
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      }
    ])

    assert %{"results" => [cancelled]} =
             post_batch(conn, [
               %{
                 "operation_id" => "credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "credit-reporting",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert cancelled["credit_issued_cents"] == 110

    report = json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-03"), 200)["data"]

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
                 "converted_to_credit_cents" => 100,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert report["credit"] == %{
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

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2027-10-04"), 200)["data"][
             "credit"
           ] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 110,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end

  test "includes already committed future-dated credit in the opening position", %{conn: conn} do
    post_batch(conn, [
      open_operation("future-credit", "2026-10-01"),
      cash_payment("future-payment", "future-credit", 100, "2026-10-02"),
      %{
        "operation_id" => "future-credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "future-credit",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      }
    ])

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-01"), 200)["data"][
             "credit"
           ] == %{
             "opening_liability_cents" => 110,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 110
           }
  end

  test "rejects a second reporting start and preserves the first result", %{conn: conn} do
    first = %{
      "operation_id" => "first-start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-01"
    }

    assert post_batch(conn, [first]) == %{
             "results" => [
               %{
                 "operation_id" => "first-start",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               }
             ]
           }

    second = Map.put(first, "operation_id", "second-start")

    assert post_batch(conn, [second]) == %{
             "results" => [
               %{
                 "operation_id" => "second-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    assert post_batch(conn, [second]) == %{
             "results" => [
               %{
                 "operation_id" => "second-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }
  end

  test "follows transferred cash and later corrections by settlement property", %{conn: conn} do
    post_batch(conn, [
      open_operation("source", "2026-10-01", "ams-canal"),
      open_operation("destination", "2026-10-01", "rotterdam")
    ])

    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      cash_payment("transferred-payment", "source", 100, "2026-10-02")
    ])

    post_batch(conn, [
      %{
        "operation_id" => "transfer-reporting",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-03",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 40,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      },
      %{
        "operation_id" => "destination-refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "destination"
      },
      %{
        "operation_id" => "source-reduction",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "transferred-payment",
        "amount_cents" => 20,
        "expected_revision" => 3
      },
      %{
        "operation_id" => "payment-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "transferred-payment",
        "expected_revision" => 4
      }
    ])

    assert %{"data" => report} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-06"), 200)

    assert Enum.map(report["cash"], &{&1["property_id"], &1["closing_held_cents"]}) ==
             [{"ams-canal", 0}, {"rotterdam", 0}]

    by_property = Map.new(report["cash"], &{&1["property_id"], &1})

    assert by_property["ams-canal"]["movements"] == %{
             "received_cents" => 0,
             "transferred_in_cents" => 0,
             "transferred_out_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 40
           }

    assert by_property["rotterdam"]["movements"] == %{
             "received_cents" => 0,
             "transferred_in_cents" => 0,
             "transferred_out_cents" => 0,
             "refunded_cents" => -40,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 40
           }
  end

  test "reports credit consumption, revocation, and shortfall absorption", %{conn: conn} do
    post_batch(conn, [
      open_operation("credit-source", "2026-10-01"),
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      cash_payment("credit-payment", "credit-source", 100, "2026-10-02"),
      %{
        "operation_id" => "credit-source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-consumer", "2026-10-04"),
      %{
        "operation_id" => "credit-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-consumer",
        "amount_cents" => 50
      }
    ])

    post_batch(conn, [
      %{
        "operation_id" => "credit-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "credit-payment"
      }
    ])

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-05"), 200)["data"][
             "credit"
           ] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 60,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 50
           }

    post_batch(conn, [
      %{
        "operation_id" => "credit-consumer-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-06",
        "group_id" => "credit-consumer"
      }
    ])

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-06"), 200)["data"][
             "credit"
           ] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 50
             },
             "closing_liability_cents" => 0
           }
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_operation(group_id, occurred_on, property_id \\ "ams-canal") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
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
