defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "daily-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 100}]
      },
      overrides
    )
  end

  defp report(conn, date), do: get(conn, "/api/v1/finance/daily-report?date=#{date}")

  test "starts once, captures the current position, and validates report dates", %{conn: conn} do
    assert get_in(
             submit(conn, [
               open_operation("opening", %{"operation_id" => "open-opening"}),
               %{
                 "operation_id" => "opening-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-02-01",
                 "group_id" => "opening",
                 "amount_cents" => 40
               }
             ])
             |> json_response(200),
             ["results", Access.at(1), "status"]
           ) == "applied"

    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "bad-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "not-a-date"
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "bad-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }

    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "start-reporting",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-01-01"
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2027-01-01"
               }
             ]
           }

    assert json_response(report(conn, "2026-12-31"), 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert json_response(get(conn, "/api/v1/finance/daily-report"), 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert json_response(report(conn, "2027-01-01"), 200) == %{
             "data" => %{
               "date" => "2027-01-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 40,
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

    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "different-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-02-01"
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "different-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }
  end

  test "posts cash corrections at their affected properties", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("source", %{
        "property_id" => "property-z",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 100}]
      }),
      open_operation("destination", %{
        "property_id" => "property-a",
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 100}]
      }),
      %{
        "operation_id" => "payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-12-31",
        "group_id" => "source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 40
      },
      %{
        "operation_id" => "reduction",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "payment",
        "amount_cents" => 10,
        "expected_revision" => 3
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "payment",
        "expected_revision" => 4
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-01"), 200), ["data", "cash"]) == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 40,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 10,
                 "charged_back_cents" => 30
               },
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "property-z",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 100,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 40,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 60
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports credit issuance, consumption, and expiry without a write", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("source", %{
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open_operation("target", %{
        "operation_id" => "open-target",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "target-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => "target",
        "amount_cents" => 50
      },
      %{
        "operation_id" => "target-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "target"
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    jan_2 = report(conn, "2027-01-02") |> json_response(200)

    assert get_in(jan_2, ["data", "credit"]) == %{
             "opening_liability_cents" => 110,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 50,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 60
           }

    assert json_response(report(conn, "2028-01-02"), 200)
           |> get_in(["data", "credit"]) == %{
             "opening_liability_cents" => 60,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 60,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }

    assert report(conn, "2028-01-02") |> json_response(200) ==
             report(conn, "2028-01-02") |> json_response(200)
  end

  test "uses same-batch order for the inception position and posting date", %{conn: conn} do
    operations = [
      open_operation("same-batch", %{"operation_id" => "open-same-batch"}),
      %{
        "operation_id" => "before-report",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-03-01",
        "group_id" => "same-batch",
        "amount_cents" => 40
      },
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      %{
        "operation_id" => "after-report",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-12-31",
        "group_id" => "same-batch",
        "amount_cents" => 40
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-01"), 200), ["data", "cash"]) == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 40,
               "movements" => %{
                 "received_cents" => 40,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 80
             }
           ]
  end

  test "reports a chargeback as a signed reversal of an earlier refund", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("refunded", %{
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "refunded-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "refunded-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "refunded",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "refunded-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "refunded"
      },
      %{
        "operation_id" => "refunded-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "refunded-payment",
        "occurred_on" => "2027-01-02",
        "expected_revision" => 3
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-02"), 200), ["data", "cash"]) == [
             %{
               "property_id" => "ams-canal",
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

  test "reports credit restored after expiry as an immediate expiry", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("source", %{
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "source-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open_operation("target", %{
        "operation_id" => "open-target",
        "rate_plan" => "flexible",
        "arrival_on" => "2028-02-01",
        "departure_on" => "2028-02-02",
        "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "target-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => "target",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "target-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2028-01-02",
        "group_id" => "target"
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2028-01-02"), 200), ["data", "credit"]) == %{
             "opening_liability_cents" => 110,
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

  test "does not leave backdated credit issuance in the opening liability", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("backdated", %{
        "occurred_on" => "2025-01-01",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "backdated-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "backdated-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2025-01-01",
        "group_id" => "backdated",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "backdated-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2025-01-01",
        "group_id" => "backdated",
        "refund_method" => "hotel_credit"
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-01"), 200), ["data", "credit"]) == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 110,
               "expired_cents" => 110,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end
end
