defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2028-01-01",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2028-06-10",
        "departure_on" => "2028-06-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp report(conn, date), do: get(conn, "/api/v1/finance/daily-report?date=#{date}")

  test "closes only valid increasing periods and durably replays the result", %{conn: conn} do
    close = %{
      "operation_id" => "close-before-start",
      "type" => "close_finance_period",
      "period_end_on" => "2028-01-01"
    }

    assert json_response(post_batch(conn, [close]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    start = %{
      "operation_id" => "start-1",
      "type" => "start_finance_reporting",
      "starts_on" => "2028-01-01"
    }

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start]) |> json_response(200)

    close = %{close | "operation_id" => "close-1"}

    assert json_response(post_batch(conn, [close]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2028-01-01"
               }
             ]
           }

    assert json_response(post_batch(conn, [close]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2028-01-01"
               }
             ]
           }

    assert json_response(
             post_batch(conn, [%{close | "period_end_on" => "2028-01-02"}]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "close-1",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert json_response(
             post_batch(conn, [
               %{
                 "operation_id" => "close-same",
                 "type" => "close_finance_period",
                 "period_end_on" => "2028-01-01"
               },
               %{
                 "operation_id" => "close-earlier",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-12-31"
               },
               %{
                 "operation_id" => "close-next",
                 "type" => "close_finance_period",
                 "period_end_on" => "2028-01-03"
               }
             ]),
             200
           )["results"] == [
             %{
               "operation_id" => "close-same",
               "status" => "rejected",
               "code" => "invalid_period"
             },
             %{
               "operation_id" => "close-earlier",
               "status" => "rejected",
               "code" => "invalid_period"
             },
             %{
               "operation_id" => "close-next",
               "status" => "applied",
               "period_end_on" => "2028-01-03"
             }
           ]

    assert json_response(report(conn, "2028-01-01"), 200)["data"]["status"] == "closed"
    assert json_response(report(conn, "2028-01-02"), 200)["data"]["status"] == "closed"
    assert json_response(report(conn, "2028-01-03"), 200)["data"]["status"] == "closed"
    assert json_response(report(conn, "2028-01-04"), 200)["data"]["status"] == "open"
  end

  test "freezes closed reports and moves old-dated effects to the first open day", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2028-01-01"
      },
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2028-01-02",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2028-01-02"
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"status" => "applied"}
             ]
           } =
             post_batch(conn, operations) |> json_response(200)

    closed_before = json_response(report(conn, "2028-01-02"), 200)["data"]
    assert closed_before["status"] == "closed"

    assert closed_before["cash"]
           |> hd()
           |> Map.fetch!("movements")
           |> Map.fetch!("received_cents") == 1_000

    assert closed_before["late_adjustments"] == %{
             "cash" => [],
             "credit" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
           }

    assert %{"results" => [%{"revision" => 3}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "pay-late",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2028-01-01",
                 "group_id" => "group-1",
                 "amount_cents" => 500
               }
             ])
             |> json_response(200)

    assert json_response(report(conn, "2028-01-02"), 200)["data"] == closed_before

    late_report = json_response(report(conn, "2028-01-03"), 200)["data"]
    assert late_report["status"] == "open"

    assert late_report["cash"] |> hd() |> Map.fetch!("movements") |> Map.fetch!("received_cents") ==
             0

    assert late_report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
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
           ]

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "close-2",
                 "type" => "close_finance_period",
                 "period_end_on" => "2028-01-03"
               }
             ])
             |> json_response(200)

    assert json_response(report(conn, "2028-01-02"), 200)["data"] == closed_before
    assert json_response(report(conn, "2028-01-03"), 200)["data"]["status"] == "closed"
    assert json_response(report(conn, "2028-01-04"), 200)["data"]["status"] == "open"
  end

  test "late credit application corrects an expiry already published in a closed period", %{
    conn: conn
  } do
    operations = [
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "starts_on" => "2028-01-01"
      },
      open_operation(%{"operation_id" => "source-open", "group_id" => "source-group"}),
      open_operation(%{"operation_id" => "destination-open", "group_id" => "destination-group"}),
      %{
        "operation_id" => "source-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2028-01-01",
        "group_id" => "source-group",
        "amount_cents" => 600
      },
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2028-01-01",
        "group_id" => "source-group",
        "refund_method" => "hotel_credit"
      },
      %{
        "operation_id" => "close-1",
        "type" => "close_finance_period",
        "period_end_on" => "2029-01-02"
      }
    ]

    assert %{"results" => [%{"status" => "applied"} | _]} =
             post_batch(conn, operations) |> json_response(200)

    closed_before = json_response(report(conn, "2029-01-02"), 200)["data"]
    assert closed_before["status"] == "closed"
    assert closed_before["credit"]["closing_liability_cents"] == 0
    assert closed_before["credit"]["movements"]["expired_cents"] == 660

    assert %{"results" => [%{"revision" => 2, "status" => "applied"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "late-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2028-12-31",
                 "group_id" => "destination-group",
                 "amount_cents" => 600
               }
             ])
             |> json_response(200)

    assert json_response(report(conn, "2029-01-02"), 200)["data"] == closed_before

    late_report = json_response(report(conn, "2029-01-03"), 200)["data"]
    assert late_report["credit"]["closing_liability_cents"] == 600
    assert late_report["late_adjustments"]["credit"]["expired_cents"] == -600
  end
end
