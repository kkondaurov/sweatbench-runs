defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_operation(group_id) do
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
    }
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "publishes reports and posts old-dated operations into the open period", %{conn: conn} do
    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "reporting-start",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        open_operation("period-close"),
        %{
          operation_id: "payment-before-close",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "period-close",
          amount_cents: 1_000
        },
        %{
          operation_id: "close-october-2",
          type: "close_finance_period",
          period_end_on: "2026-10-02"
        }
      ]
    })
    |> json_response(200)

    closed_before_late_payment = report(conn, "2026-10-02")

    assert closed_before_late_payment["status"] == "closed"
    assert closed_before_late_payment["cash"] |> hd() |> Map.fetch!("closing_held_cents") == 1_000

    late_result =
      conn
      |> json_post(%{
        operations: [
          %{
            operation_id: "payment-after-close",
            type: "record_cash_payment",
            occurred_on: "2026-10-02",
            group_id: "period-close",
            amount_cents: 500
          }
        ]
      })
      |> json_response(200)
      |> Map.fetch!("results")
      |> hd()

    assert late_result["status"] == "applied"

    open_report = report(conn, "2026-10-03")

    assert open_report["status"] == "open"
    assert open_report["cash"] |> hd() |> Map.fetch!("closing_held_cents") == 1_500

    assert open_report["cash"] |> hd() |> Map.fetch!("movements") |> Map.fetch!("received_cents") ==
             1_000

    assert open_report["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "property-period-close",
                 "movements" => %{
                   "received_cents" => 500,
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

    assert conn
           |> json_post(%{
             operations: [
               %{
                 operation_id: "close-october-3",
                 type: "close_finance_period",
                 period_end_on: "2026-10-03"
               }
             ]
           })
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "close-october-3",
                 "status" => "applied",
                 "period_end_on" => "2026-10-03"
               }
             ]
           }

    closed_after_late_payment = report(conn, "2026-10-02")
    assert closed_after_late_payment == closed_before_late_payment
    assert report(conn, "2026-10-03")["status"] == "closed"

    retry =
      conn
      |> json_post(%{
        operations: [
          %{
            operation_id: "close-october-3",
            type: "close_finance_period",
            period_end_on: "2026-10-03"
          }
        ]
      })
      |> json_response(200)

    assert retry["results"] == [
             %{
               "operation_id" => "close-october-3",
               "status" => "applied",
               "period_end_on" => "2026-10-03"
             }
           ]

    assert conn
           |> json_post(%{
             operations: [
               %{
                 operation_id: "close-too-early",
                 type: "close_finance_period",
                 period_end_on: "2026-10-02"
               },
               %{
                 operation_id: "close-conflict",
                 type: "close_finance_period",
                 period_end_on: "2026-10-03"
               }
             ]
           })
           |> json_response(200)
           |> Map.fetch!("results")
           |> Enum.map(& &1["code"]) == ["invalid_period", "invalid_period"]
  end

  test "rejects a close before reporting starts and remembers the rejection", %{conn: conn} do
    operation = %{
      operation_id: "close-without-reporting",
      type: "close_finance_period",
      period_end_on: "2026-10-01"
    }

    assert conn
           |> json_post(%{operations: [operation]})
           |> json_response(200)
           |> Map.fetch!("results")
           |> hd() == %{
             "operation_id" => "close-without-reporting",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    assert conn
           |> json_post(%{operations: [operation]})
           |> json_response(200)
           |> Map.fetch!("results")
           |> hd() == %{
             "operation_id" => "close-without-reporting",
             "status" => "rejected",
             "code" => "invalid_period"
           }
  end

  test "keeps late credit movements separate from ordinary movements", %{conn: conn} do
    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "reporting-start",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        open_operation("late-credit"),
        %{
          operation_id: "late-credit-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "late-credit",
          amount_cents: 1_000
        },
        %{
          operation_id: "close-october-2",
          type: "close_finance_period",
          period_end_on: "2026-10-02"
        }
      ]
    })
    |> json_response(200)

    conn
    |> json_post(%{
      operations: [
        %{
          operation_id: "late-credit-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-02",
          group_id: "late-credit",
          refund_method: "hotel_credit"
        }
      ]
    })
    |> json_response(200)

    report = report(conn, "2026-10-03")

    assert report["credit"]["movements"]["issued_cents"] == 0
    assert report["credit"]["closing_liability_cents"] == 1_100

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 1_100,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end
end
