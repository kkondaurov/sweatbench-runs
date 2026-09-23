defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-01",
        group_id: group_id,
        guest_id: "period-close-guest",
        property_id: "hotel-a",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-#{group_id}", nightly_rate_cents: 1000}]
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

  test "close operations validate, publish reports, and route later corrections to open days", %{
    conn: conn
  } do
    assert post_batch(conn, [
             %{
               operation_id: "close-before-start",
               type: "close_finance_period",
               period_end_on: "2026-10-01"
             }
           ]) == [
             %{
               "operation_id" => "close-before-start",
               "status" => "rejected",
               "code" => "invalid_period"
             }
           ]

    assert post_batch(conn, [
             %{operation_id: "close-missing-date", type: "close_finance_period"}
           ])
           |> hd() == %{
             "operation_id" => "close-missing-date",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    close_first = %{
      operation_id: "close-first-period",
      type: "close_finance_period",
      period_end_on: "2026-10-03"
    }

    close_later = %{
      operation_id: "close-second-period",
      type: "close_finance_period",
      period_end_on: "2026-10-05"
    }

    results =
      post_batch(conn, [
        open_operation("close-group"),
        %{
          operation_id: "start-close-report",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        %{
          operation_id: "payment-before-close",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "close-group",
          amount_cents: 50
        },
        close_first,
        %{
          operation_id: "payment-after-close",
          type: "record_cash_payment",
          occurred_on: "2026-10-02",
          group_id: "close-group",
          amount_cents: 25
        },
        close_later,
        %{close_later | operation_id: "duplicate-cutoff"},
        %{close_first | operation_id: "earlier-cutoff"}
      ])

    assert Enum.at(results, 3) == %{
             "operation_id" => "close-first-period",
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    assert Enum.at(results, 5) == %{
             "operation_id" => "close-second-period",
             "status" => "applied",
             "period_end_on" => "2026-10-05"
           }

    assert Enum.at(results, 6)["code"] == "invalid_period"
    assert Enum.at(results, 7)["code"] == "invalid_period"

    assert post_batch(conn, [close_first]) |> hd() == Enum.at(results, 3)

    closed_through_first_cutoff = report(conn, "2026-10-03")
    assert closed_through_first_cutoff["status"] == "closed"

    assert get_in(closed_through_first_cutoff, [
             "cash",
             Access.at(0),
             "movements",
             "received_cents"
           ]) == 50

    assert get_in(closed_through_first_cutoff, ["late_adjustments", "cash"]) == []

    closed_open_day = report(conn, "2026-10-04")
    assert closed_open_day["status"] == "closed"
    assert get_in(closed_open_day, ["cash", Access.at(0), "movements", "received_cents"]) == 50

    assert get_in(closed_open_day, [
             "late_adjustments",
             "cash",
             Access.at(0),
             "movements",
             "received_cents"
           ]) == 25

    post_batch(conn, [
      %{
        operation_id: "payment-after-second-close",
        type: "record_cash_payment",
        occurred_on: "2026-10-02",
        group_id: "close-group",
        amount_cents: 25
      }
    ])

    assert report(conn, "2026-10-03") == closed_through_first_cutoff
    assert report(conn, "2026-10-04") == closed_open_day

    open_day = report(conn, "2026-10-06")
    assert open_day["status"] == "open"
    assert get_in(open_day, ["cash", Access.at(0), "movements", "received_cents"]) == 50

    assert get_in(open_day, [
             "late_adjustments",
             "cash",
             Access.at(0),
             "movements",
             "received_cents"
           ]) == 50

    assert get_in(open_day, ["cash", Access.at(0), "closing_held_cents"]) == 100
  end

  test "late cancellations report their cash and credit effects separately", %{conn: conn} do
    post_batch(conn, [
      open_operation("late-credit-group"),
      %{
        operation_id: "start-late-credit",
        type: "start_finance_reporting",
        starts_on: "2026-10-01"
      },
      %{
        operation_id: "late-credit-payment",
        type: "record_cash_payment",
        occurred_on: "2026-10-02",
        group_id: "late-credit-group",
        amount_cents: 100
      },
      %{
        operation_id: "close-before-late-cancel",
        type: "close_finance_period",
        period_end_on: "2026-10-10"
      },
      %{
        operation_id: "late-credit-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "late-credit-group",
        refund_method: "hotel_credit"
      }
    ])

    report = report(conn, "2026-10-11")

    assert report["cash"] == [
             %{
               "property_id" => "hotel-a",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 100,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }
           ]

    assert get_in(report, ["late_adjustments", "cash"]) == [
             %{
               "property_id" => "hotel-a",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 100,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
           ]

    assert report["credit"]["movements"]["issued_cents"] == 0
    assert report["credit"]["closing_liability_cents"] == 110

    assert report["late_adjustments"]["credit"] == %{
             "issued_cents" => 110,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end

  test "a late credit application reverses expiry for credit valid on its occurred date", %{
    conn: conn
  } do
    post_batch(conn, [
      open_operation("expiry-credit-source"),
      %{
        operation_id: "start-expiry-credit-report",
        type: "start_finance_reporting",
        starts_on: "2026-10-01"
      },
      %{
        operation_id: "expiry-credit-payment",
        type: "record_cash_payment",
        occurred_on: "2026-10-02",
        group_id: "expiry-credit-source",
        amount_cents: 100
      },
      %{
        operation_id: "expiry-credit-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "expiry-credit-source",
        refund_method: "hotel_credit"
      },
      open_operation("expiry-credit-target", %{
        arrival_on: "2028-12-10",
        departure_on: "2028-12-11"
      }),
      %{
        operation_id: "close-through-credit-expiry",
        type: "close_finance_period",
        period_end_on: "2027-10-06"
      },
      %{
        operation_id: "late-apply-expiring-credit",
        type: "apply_hotel_credit",
        occurred_on: "2027-10-05",
        group_id: "expiry-credit-target",
        amount_cents: 40
      }
    ])

    report = report(conn, "2027-10-07")

    assert report["credit"]["movements"]["expired_cents"] == 110
    assert report["late_adjustments"]["credit"]["expired_cents"] == -40
    assert report["credit"]["closing_liability_cents"] == 40

    assert conn
           |> get("/api/v1/ledger?on=2027-10-07")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 40
  end
end
