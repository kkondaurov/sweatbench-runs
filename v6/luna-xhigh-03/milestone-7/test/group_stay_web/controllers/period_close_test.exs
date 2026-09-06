defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-group",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-15",
        "departure_on" => "2027-04-16",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  test "closes reports and moves old-dated effects into late adjustments", %{conn: conn} do
    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      operation(),
      operation(%{
        "operation_id" => "pay-before-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "amount_cents" => 1_000
      }),
      %{
        "operation_id" => "close-through-jan-2",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-02"
      }
    ])

    assert %{"data" => closed_report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert closed_report["status"] == "closed"

    assert closed_report["late_adjustments"] == %{
             "cash" => [],
             "credit" => zero_credit_movements()
           }

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-after-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "amount_cents" => 500
      })
    ])

    assert %{"data" => ^closed_report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert %{"data" => report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)

    assert report["status"] == "open"

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 1_500
             }
           ]

    assert report["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "movements" => Map.put(zero_cash_movements(), "received_cents", 500)
               }
             ],
             "credit" => zero_credit_movements()
           }

    post_batch(conn, [
      %{
        "operation_id" => "close-through-jan-3",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-03"
      }
    ])

    assert %{"data" => closed_late_report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)

    assert closed_late_report == Map.put(report, "status", "closed")

    post_batch(conn, [
      operation(%{
        "operation_id" => "pay-after-second-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-04",
        "amount_cents" => 100
      }),
      %{
        "operation_id" => "close-through-jan-4",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-04"
      }
    ])

    assert %{"data" => ^closed_late_report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)
  end

  test "requires a started reporting period and strictly advances the cutoff", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_period"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "close-before-start",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-01"
               }
             ])

    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-02"
      }
    ])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "before-start",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-01"
               }
             ])

    assert %{"results" => [%{"period_end_on" => "2027-01-03"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "close-through-jan-3",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-03"
               }
             ])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "close-again",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-03"
               }
             ])
  end

  test "an operation immediately before a close stays on its natural date", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}, payment, close]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reporting-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-01-01"
               },
               operation(),
               operation(%{
                 "operation_id" => "pay-before-close",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "amount_cents" => 1_000
               }),
               %{
                 "operation_id" => "close-through-jan-2",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-02"
               }
             ])

    assert payment["revision"] == 2
    assert close["period_end_on"] == "2027-01-02"

    assert %{"data" => %{"cash" => [%{"movements" => movements}], "late_adjustments" => late}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-02") |> json_response(200)

    assert movements["received_cents"] == 1_000
    assert late == %{"cash" => [], "credit" => zero_credit_movements()}
  end

  test "late credit effects are separated from ordinary movements", %{conn: conn} do
    post_batch(conn, [
      %{
        "operation_id" => "reporting-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      operation(),
      operation(%{
        "operation_id" => "pay-before-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "amount_cents" => 1_000
      }),
      %{
        "operation_id" => "close-through-jan-2",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-02"
      }
    ])

    assert %{"results" => [%{"credit_issued_cents" => 1_100}]} =
             post_batch(conn, [
               operation(%{
                 "operation_id" => "late-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert %{"data" => report} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-03") |> json_response(200)

    assert report["credit"]["movements"] == zero_credit_movements()
    assert report["credit"]["closing_liability_cents"] == 1_100

    assert report["late_adjustments"]["credit"] ==
             Map.put(zero_credit_movements(), "issued_cents", 1_100)

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => Map.put(zero_cash_movements(), "converted_to_credit_cents", 1_000)
             }
           ]
  end

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end
end
