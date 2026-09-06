defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditLot, Repo}

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp result(conn, operation),
    do: post_batch(conn, [operation]) |> json_response(200) |> Map.fetch!("results") |> hd()

  defp report(conn, date),
    do:
      get(conn, "/api/v1/finance/daily-report?date=#{date}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp credit_lot do
    Repo.insert!(%CreditLot{
      guest_id: "guest-1",
      source_operation_id: "credit-source",
      remaining_cents: 5,
      expires_on: ~D[2028-01-01],
      cash_converted_cents: 0,
      issued_on: ~D[2027-01-01],
      unrecovered_clawback_cents: 0
    })
  end

  test "starts from the committed state and exposes availability errors", %{conn: conn} do
    result(conn, open_operation())

    result(conn, %{
      "operation_id" => "pay-before-start",
      "type" => "record_cash_payment",
      "occurred_on" => "2028-02-01",
      "group_id" => "group-1",
      "amount_cents" => 10
    })

    start = %{
      "operation_id" => "reporting-start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-01"
    }

    assert result(conn, start) == %{
             "operation_id" => "reporting-start",
             "status" => "applied",
             "starts_on" => "2027-01-01"
           }

    assert result(conn, start) == %{
             "operation_id" => "reporting-start",
             "status" => "applied",
             "starts_on" => "2027-01-01"
           }

    assert result(conn, %{
             "operation_id" => "reporting-start-2",
             "type" => "start_finance_reporting",
             "starts_on" => "2027-01-02"
           })["code"] == "reporting_already_started"

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-12-31"), 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert json_response(get(conn, "/api/v1/finance/daily-report"), 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert json_response(get(conn, "/api/v1/finance/daily-report?date=not-a-date"), 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert report(conn, "2027-01-01") == %{
             "date" => "2027-01-01",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10,
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
                 "closing_held_cents" => 10
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
  end

  test "posts transfers by property and follows held cash through chargebacks", %{conn: conn} do
    post_batch(conn, [
      open_operation(),
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "group-2",
        "property_id" => "rotterdam",
        "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 50}]
      }),
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      }
    ])

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "amount_cents" => 10
    })

    result(conn, %{
      "operation_id" => "transfer-1",
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-03",
      "source_group_id" => "group-1",
      "destination_group_id" => "group-2",
      "amount_cents" => 5,
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    })

    result(conn, %{
      "operation_id" => "chargeback-1",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-1",
      "expected_revision" => 3,
      "occurred_on" => "2027-01-05"
    })

    assert report(conn, "2027-01-05")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 5
               },
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "rotterdam",
               "opening_held_cents" => 5,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 5
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports only the cash portion of a mixed transfer", %{conn: conn} do
    post_batch(conn, [
      open_operation(),
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "group-2",
        "property_id" => "rotterdam",
        "rooms" => [%{"room_id" => "room-b", "nightly_rate_cents" => 50}]
      }),
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      }
    ])

    credit_lot()

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "amount_cents" => 5
    })

    result(conn, %{
      "operation_id" => "credit-1",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "amount_cents" => 5
    })

    result(conn, %{
      "operation_id" => "transfer-1",
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-03",
      "source_group_id" => "group-1",
      "destination_group_id" => "group-2",
      "amount_cents" => 8,
      "expected_revision" => 3,
      "destination_expected_revision" => 1
    })

    assert report(conn, "2027-01-03")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 5,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 3,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 2
             },
             %{
               "property_id" => "rotterdam",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 3,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 3
             }
           ]
  end

  test "reports issued credit and an operation-free expiry", %{conn: conn} do
    post_batch(conn, [
      open_operation(%{"arrival_on" => "2027-04-01"}),
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      }
    ])

    result(conn, %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => "group-1",
      "amount_cents" => 10
    })

    result(conn, %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-03",
      "group_id" => "group-1",
      "refund_method" => "hotel_credit"
    })

    expiry_date = Date.add(~D[2027-01-03], 366) |> Date.to_iso8601()
    credit = report(conn, "2027-01-03")["credit"]

    assert credit["movements"] == %{
             "issued_cents" => 11,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert credit["closing_liability_cents"] == 11

    assert report(conn, expiry_date)["credit"] == %{
             "opening_liability_cents" => 11,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 11,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end

  test "reverses a reported refund when the payment is charged back", %{conn: conn} do
    result(conn, open_operation())

    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "amount_cents" => 10
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-03",
        "group_id" => "group-1"
      }
    ])

    result(conn, %{
      "operation_id" => "chargeback-1",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay-1",
      "expected_revision" => 3,
      "occurred_on" => "2027-01-04"
    })

    assert report(conn, "2027-01-04")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -10,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 10
               },
               "closing_held_cents" => 0
             }
           ]
  end
end
