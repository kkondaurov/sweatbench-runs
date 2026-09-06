defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-01-01",
        group_id: "group-1",
        guest_id: "guest-1",
        property_id: "property-a",
        arrival_on: "2026-03-01",
        departure_on: "2026-03-03",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-1", nightly_rate_cents: 10_000}]
      },
      overrides
    )
  end

  test "uses the state immediately before start as opening and posts later operations by date", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_operation("open"),
        %{
          operation_id: "opening-payment",
          type: "record_cash_payment",
          occurred_on: "2027-02-01",
          group_id: "group-1",
          amount_cents: 1000
        },
        %{operation_id: "start", type: "start_finance_reporting", starts_on: "2027-01-01"},
        %{
          operation_id: "daily-payment",
          type: "record_cash_payment",
          occurred_on: "2027-01-03",
          group_id: "group-1",
          amount_cents: 500
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 2) == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-01"
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-01")
           |> json_response(200) == %{
             "data" => %{
               "date" => "2027-01-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "opening_held_cents" => 1000,
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
                   "closing_held_cents" => 1000
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

    report =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert report["cash"] == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 1000,
               "movements" => %{
                 "received_cents" => 500,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 1500
             }
           ]
  end

  test "records credit issuance and reports automatic expiry without changing state", %{
    conn: conn
  } do
    assert post_batch(conn, [open_operation("open")]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2026-01-02",
               group_id: "group-1",
               amount_cents: 1000
             },
             %{operation_id: "start", type: "start_finance_reporting", starts_on: "2026-01-03"}
           ])
           |> json_response(200)

    cancellation = %{
      operation_id: "cancel",
      type: "cancel_group",
      occurred_on: "2026-01-10",
      group_id: "group-1",
      refund_method: "hotel_credit"
    }

    assert post_batch(conn, [cancellation]) |> json_response(200)

    report =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-10")
      |> json_response(200)
      |> Map.fetch!("data")

    assert report["cash"] == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 1000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 1000,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert report["credit"]["movements"]["issued_cents"] == 1100
    assert report["credit"]["closing_liability_cents"] == 1100

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-11")
           |> json_response(200)
           |> get_in(["data", "credit"]) == %{
             "opening_liability_cents" => 1100,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 1100,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }

    assert get(conn, "/api/v1/guests/guest-1/credit?on=2027-01-11")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 0
  end

  test "rejects unavailable reports and remembers a second start rejection", %{conn: conn} do
    assert get(conn, "/api/v1/finance/daily-report")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert post_batch(conn, [%{operation_id: "bad", type: "start_finance_reporting"}])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "bad",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }

    assert post_batch(conn, [
             %{operation_id: "start", type: "start_finance_reporting", starts_on: "2027-01-01"}
           ])
           |> json_response(200)

    second = %{operation_id: "second", type: "start_finance_reporting", starts_on: "2027-02-01"}

    assert post_batch(conn, [second]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "second",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    assert post_batch(conn, [second]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "second",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }
  end

  test "follows held cash across transfers, reductions, refunds, and chargebacks by property", %{
    conn: conn
  } do
    source =
      open_operation("source-open", %{
        group_id: "source",
        property_id: "property-a",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-03"
      })

    destination =
      open_operation("destination-open", %{
        group_id: "destination",
        property_id: "property-b",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-03"
      })

    assert post_batch(conn, [
             source,
             destination,
             %{operation_id: "start", type: "start_finance_reporting", starts_on: "2027-01-01"}
           ])
           |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2027-01-02",
               group_id: "source",
               amount_cents: 1000
             },
             %{
               operation_id: "transfer",
               type: "transfer_deposit",
               occurred_on: "2027-01-03",
               source_group_id: "source",
               destination_group_id: "destination",
               amount_cents: 600
             },
             %{
               operation_id: "reduction",
               type: "reduce_cash_payment",
               occurred_on: "2027-01-04",
               payment_operation_id: "payment",
               amount_cents: 200
             },
             %{
               operation_id: "cancel-destination",
               type: "cancel_group",
               occurred_on: "2027-01-05",
               group_id: "destination"
             }
           ])
           |> json_response(200)

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-05")
           |> json_response(200)
           |> get_in(["data", "cash"]) == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 400,
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
               "closing_held_cents" => 400
             },
             %{
               "property_id" => "property-b",
               "opening_held_cents" => 400,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 400,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert post_batch(conn, [
             %{
               operation_id: "chargeback",
               type: "charge_back_payment",
               occurred_on: "2027-01-06",
               payment_operation_id: "payment"
             }
           ])
           |> json_response(200)

    cash =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-06")
      |> json_response(200)
      |> get_in(["data", "cash"])

    assert cash == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 400,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 400
               },
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "property-b",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -400,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 400
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports credit consumption, revocation, and shortfall absorption", %{conn: conn} do
    source =
      open_operation("source-open", %{
        group_id: "source",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-03"
      })

    use_group =
      open_operation("use-open", %{
        group_id: "use",
        arrival_on: "2027-04-01",
        departure_on: "2027-04-03"
      })

    assert post_batch(conn, [
             source,
             %{operation_id: "start", type: "start_finance_reporting", starts_on: "2027-01-01"}
           ])
           |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2027-01-02",
               group_id: "source",
               amount_cents: 1000
             },
             %{
               operation_id: "cancel-source",
               type: "cancel_group",
               occurred_on: "2027-01-03",
               group_id: "source",
               refund_method: "hotel_credit"
             },
             use_group,
             %{
               operation_id: "apply",
               type: "apply_hotel_credit",
               occurred_on: "2027-01-04",
               group_id: "use",
               amount_cents: 500
             },
             %{
               operation_id: "chargeback",
               type: "charge_back_payment",
               occurred_on: "2027-01-05",
               payment_operation_id: "payment"
             },
             %{
               operation_id: "cancel-use",
               type: "cancel_group",
               occurred_on: "2027-01-06",
               group_id: "use"
             }
           ])
           |> json_response(200)

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-05")
           |> json_response(200)
           |> get_in(["data", "credit"]) == %{
             "opening_liability_cents" => 1100,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 600,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 500
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-06")
           |> json_response(200)
           |> get_in(["data", "credit"]) == %{
             "opening_liability_cents" => 500,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 500
             },
             "closing_liability_cents" => 0
           }
  end
end
