defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(operation_id) do
    %{
      operation_id: operation_id,
      type: "open_group",
      occurred_on: "2026-01-01",
      group_id: "group-1",
      guest_id: "guest-1",
      property_id: "property-a",
      arrival_on: "2027-03-01",
      departure_on: "2027-03-03",
      rate_plan: "advance_purchase",
      rooms: [%{room_id: "room-1", nightly_rate_cents: 10_000}]
    }
  end

  defp start_operation do
    %{operation_id: "start", type: "start_finance_reporting", starts_on: "2027-01-01"}
  end

  test "validates and durably applies increasing finance closes", %{conn: conn} do
    assert post_batch(conn, [%{operation_id: "close", type: "close_finance_period"}])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert post_batch(conn, [open_operation("open"), start_operation()]) |> json_response(200)

    invalid = %{
      operation_id: "invalid",
      type: "close_finance_period",
      period_end_on: "2026-12-31"
    }

    assert post_batch(conn, [invalid]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "invalid",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    close = %{
      operation_id: "close-1",
      type: "close_finance_period",
      period_end_on: "2027-01-03"
    }

    expected = %{
      "operation_id" => "close-1",
      "status" => "applied",
      "period_end_on" => "2027-01-03"
    }

    assert post_batch(conn, [close]) |> json_response(200) == %{"results" => [expected]}
    assert post_batch(conn, [close]) |> json_response(200) == %{"results" => [expected]}

    assert post_batch(conn, [
             %{
               operation_id: "same-cutoff",
               type: "close_finance_period",
               period_end_on: "2027-01-03"
             },
             %{operation_id: "earlier", type: "close_finance_period", period_end_on: "2027-01-02"}
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "same-cutoff",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "earlier",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }
  end

  test "freezes closed reports and posts old-dated operations after the close", %{conn: conn} do
    assert post_batch(conn, [open_operation("open"), start_operation()]) |> json_response(200)

    operations = [
      %{
        operation_id: "before-close-payment",
        type: "record_cash_payment",
        occurred_on: "2027-01-02",
        group_id: "group-1",
        amount_cents: 500
      },
      %{
        operation_id: "close-1",
        type: "close_finance_period",
        period_end_on: "2027-01-03"
      },
      %{
        operation_id: "after-close-payment",
        type: "record_cash_payment",
        occurred_on: "2027-01-02",
        group_id: "group-1",
        amount_cents: 600
      },
      %{
        operation_id: "close-2",
        type: "close_finance_period",
        period_end_on: "2027-01-04"
      }
    ]

    assert post_batch(conn, operations) |> json_response(200)

    closed_before =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert closed_before["data"]["status"] == "closed"

    assert closed_before["data"]["cash"] == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 0,
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
               "closing_held_cents" => 500
             }
           ]

    report =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-04")
      |> json_response(200)
      |> Map.fetch!("data")

    assert report["status"] == "closed"

    assert report["cash"] == [
             %{
               "property_id" => "property-a",
               "opening_held_cents" => 500,
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
               "closing_held_cents" => 1100
             }
           ]

    assert report["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "property-a",
                 "movements" => %{
                   "received_cents" => 600,
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

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-03")
           |> json_response(200)
           |> Map.fetch!("data")
           |> Map.fetch!("status") == "closed"

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-02")
           |> json_response(200) == closed_before
  end

  test "keeps signed cash classifications in a late adjustment", %{conn: conn} do
    flexible =
      Map.merge(open_operation("open"), %{
        rate_plan: "flexible",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-03"
      })

    assert post_batch(conn, [flexible, start_operation()]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2027-01-02",
               group_id: "group-1",
               amount_cents: 1000
             },
             %{
               operation_id: "cancel",
               type: "cancel_group",
               occurred_on: "2027-01-02",
               group_id: "group-1"
             },
             %{operation_id: "close", type: "close_finance_period", period_end_on: "2027-01-03"}
           ])
           |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "chargeback",
               type: "charge_back_payment",
               occurred_on: "2027-01-02",
               payment_operation_id: "payment"
             }
           ])
           |> json_response(200)

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-04")
           |> json_response(200)
           |> get_in(["data", "late_adjustments"]) == %{
             "cash" => [
               %{
                 "property_id" => "property-a",
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => -1000,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 1000
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

  test "puts a late hotel-credit issuance in the credit adjustment", %{conn: conn} do
    flexible =
      Map.merge(open_operation("open"), %{
        rate_plan: "flexible",
        arrival_on: "2027-03-01",
        departure_on: "2027-03-03"
      })

    assert post_batch(conn, [flexible, start_operation()]) |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "payment",
               type: "record_cash_payment",
               occurred_on: "2027-01-02",
               group_id: "group-1",
               amount_cents: 1000
             },
             %{operation_id: "close", type: "close_finance_period", period_end_on: "2027-01-03"}
           ])
           |> json_response(200)

    assert post_batch(conn, [
             %{
               operation_id: "cancel",
               type: "cancel_group",
               occurred_on: "2027-01-02",
               group_id: "group-1",
               refund_method: "hotel_credit"
             }
           ])
           |> json_response(200)

    report =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-04")
      |> json_response(200)
      |> Map.fetch!("data")

    assert report["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 1100
           }

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 1100,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end
end
