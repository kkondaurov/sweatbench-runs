defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-01",
        group_id: group_id,
        guest_id: "guest-22",
        property_id: "property-#{group_id}",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-#{group_id}", nightly_rate_cents: 10_000}]
      },
      overrides
    )
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "takes the opening position at the start operation and posts later batch operations", %{
    conn: conn
  } do
    response =
      conn
      |> json_post(%{
        operations: [
          open_operation("opening-group"),
          %{
            operation_id: "opening-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-20",
            group_id: "opening-group",
            amount_cents: 1_000
          },
          %{
            operation_id: "reporting-start",
            type: "start_finance_reporting",
            starts_on: "2026-10-05"
          },
          open_operation("movement-group", %{
            occurred_on: "2026-10-06",
            property_id: "property-movement-group"
          }),
          %{
            operation_id: "movement-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-06",
            group_id: "movement-group",
            amount_cents: 500
          }
        ]
      })
      |> json_response(200)

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "reporting-start",
             "status" => "applied",
             "starts_on" => "2026-10-05"
           }

    assert report(conn, "2026-10-05") == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "property-opening-group",
                 "opening_held_cents" => 1_000,
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
                 "closing_held_cents" => 1_000
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

    assert report(conn, "2026-10-06")["cash"]
           |> Enum.map(&{&1["property_id"], &1["closing_held_cents"]}) == [
             {"property-movement-group", 500},
             {"property-opening-group", 1_000}
           ]
  end

  test "reports transfers and refunds at the properties where the cash moves", %{conn: conn} do
    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "reporting-start",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        open_operation("transfer-source", %{property_id: "property-a"}),
        open_operation("transfer-destination", %{property_id: "property-b"}),
        %{
          operation_id: "transfer-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "transfer-source",
          amount_cents: 1_000
        },
        %{
          operation_id: "move-funding",
          type: "transfer_deposit",
          occurred_on: "2026-10-03",
          source_group_id: "transfer-source",
          destination_group_id: "transfer-destination",
          amount_cents: 1_000
        },
        %{
          operation_id: "refund-funding",
          type: "cancel_group",
          occurred_on: "2026-10-04",
          group_id: "transfer-destination"
        }
      ]
    })
    |> json_response(200)

    assert report(conn, "2026-10-04")["cash"] == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 1_000,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 1_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "property-b",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 1_000,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 1_000,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "posts issued credit and reports expiry without a partner operation", %{conn: conn} do
    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "reporting-start",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        open_operation("credit-source", %{
          occurred_on: "2026-10-02",
          arrival_on: "2027-01-20",
          departure_on: "2027-01-21",
          property_id: "property-credit"
        }),
        %{
          operation_id: "credit-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-03",
          group_id: "credit-source",
          amount_cents: 1_000
        },
        %{
          operation_id: "credit-cancel",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "credit-source",
          refund_method: "hotel_credit"
        }
      ]
    })
    |> json_response(200)

    assert report(conn, "2026-12-01")["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 1_100,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 1_100
           }

    assert report(conn, "2027-12-03")["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 1_100,
               "expired_cents" => 1_100,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end

  test "posts a chargeback as a reversal of the prior property settlement", %{conn: conn} do
    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "reporting-start",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        open_operation("chargeback-group", %{property_id: "property-chargeback"}),
        %{
          operation_id: "chargeback-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "chargeback-group",
          amount_cents: 1_000
        },
        %{
          operation_id: "chargeback-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-04",
          group_id: "chargeback-group"
        },
        %{
          operation_id: "chargeback-correction",
          type: "charge_back_payment",
          occurred_on: "2026-10-05",
          payment_operation_id: "chargeback-payment",
          expected_revision: 3
        }
      ]
    })
    |> json_response(200)

    assert report(conn, "2026-10-05")["cash"] == [
             %{
               "property_id" => "property-chargeback",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 1_000,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 1_000
               },
               "closing_held_cents" => 0
             }
           ]
  end

  test "classifies credit consumed by a non-refundable cancellation", %{conn: conn} do
    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "reporting-start",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        open_operation("credit-issuer", %{arrival_on: "2027-01-20", departure_on: "2027-01-21"}),
        %{
          operation_id: "credit-issuer-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "credit-issuer",
          amount_cents: 1_000
        },
        %{
          operation_id: "credit-issuer-cancel",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "credit-issuer",
          refund_method: "hotel_credit"
        },
        open_operation("credit-consumer", %{
          rate_plan: "advance_purchase",
          property_id: "property-consumer"
        }),
        %{
          operation_id: "credit-apply",
          type: "apply_hotel_credit",
          occurred_on: "2026-12-02",
          group_id: "credit-consumer",
          amount_cents: 500
        },
        %{
          operation_id: "credit-consumer-cancel",
          type: "cancel_group",
          occurred_on: "2026-12-03",
          group_id: "credit-consumer"
        }
      ]
    })
    |> json_response(200)

    assert report(conn, "2026-12-03")["credit"]["movements"] == %{
             "issued_cents" => 1_100,
             "expired_cents" => 0,
             "consumed_cents" => 500,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end

  test "uses reporting-specific validation and durable replay", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             conn
             |> get("/api/v1/finance/daily-report")
             |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             conn
             |> get("/api/v1/finance/daily-report?date=2026-10-01")
             |> json_response(404)

    start = %{
      operation_id: "reporting-start",
      type: "start_finance_reporting",
      starts_on: "2026-10-05"
    }

    first = conn |> json_post(%{operations: [start]}) |> json_response(200)
    retry = conn |> json_post(%{operations: [start]}) |> json_response(200)

    assert retry == first

    assert %{"code" => "reporting_already_started"} =
             conn
             |> json_post(%{
               operations: [%{start | operation_id: "other-start", starts_on: "2026-10-06"}]
             })
             |> json_response(200)
             |> Map.fetch!("results")
             |> hd()
  end
end
