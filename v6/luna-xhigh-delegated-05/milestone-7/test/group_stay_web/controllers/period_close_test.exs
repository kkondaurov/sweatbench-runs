defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp start_reporting(operation_id, starts_on) do
    %{operation_id: operation_id, type: "start_finance_reporting", starts_on: starts_on}
  end

  defp open_group(operation_id \\ "open-group") do
    %{
      operation_id: operation_id,
      type: "open_group",
      occurred_on: "2026-01-01",
      group_id: "group-1",
      guest_id: "guest-1",
      property_id: "property-a",
      arrival_on: "2026-12-10",
      departure_on: "2026-12-11",
      rate_plan: "flexible",
      rooms: [%{room_id: "room-a", nightly_rate_cents: 5_000}]
    }
  end

  defp payment(operation_id, occurred_on, amount_cents \\ 500) do
    %{
      operation_id: operation_id,
      type: "record_cash_payment",
      occurred_on: occurred_on,
      group_id: "group-1",
      amount_cents: amount_cents
    }
  end

  test "closes an inclusive period, freezes it, and moves old-dated funding forward", %{
    conn: conn
  } do
    results =
      submit(conn, [
        start_reporting("start", "2026-01-01"),
        open_group(),
        payment("pay-before-close", "2026-01-02"),
        %{
          operation_id: "close-1",
          type: "close_finance_period",
          period_end_on: "2026-01-02"
        },
        payment("pay-late", "2026-01-02", 200)
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 3) == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2026-01-02"
           }

    closed = get(conn, "/api/v1/finance/daily-report?date=2026-01-02") |> json_response(200)
    assert closed["data"]["status"] == "closed"
    assert get_in(closed, ["data", "cash", Access.at(0), "closing_held_cents"]) == 500
    assert get_in(closed, ["data", "late_adjustments", "cash"]) == []

    next_day =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-03")
      |> json_response(200)
      |> get_in(["data"])

    assert next_day["status"] == "open"
    assert get_in(next_day, ["cash", Access.at(0), "movements", "received_cents"]) == 0
    assert get_in(next_day, ["cash", Access.at(0), "closing_held_cents"]) == 700

    assert get_in(next_day, ["late_adjustments", "cash"]) == [
             %{
               "property_id" => "property-a",
               "movements" => %{
                 "received_cents" => 200,
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

    snapshot = Jason.decode!(Jason.encode!(closed))

    submit(conn, [
      payment("pay-open", "2026-01-03", 100),
      %{operation_id: "close-2", type: "close_finance_period", period_end_on: "2026-01-03"}
    ])
    |> json_response(200)

    assert get(conn, "/api/v1/finance/daily-report?date=2026-01-02")
           |> json_response(200) == snapshot

    assert get(conn, "/api/v1/finance/daily-report?date=2026-01-03")
           |> json_response(200)
           |> get_in(["data", "status"]) == "closed"

    assert submit(conn, [
             %{
               operation_id: "close-1",
               type: "close_finance_period",
               period_end_on: "2026-01-02"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == Enum.at(results, 3)

    assert submit(conn, [
             %{
               operation_id: "close-1",
               type: "close_finance_period",
               period_end_on: "2026-01-03"
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "code"]) == "operation_id_conflict"
  end

  test "rejects invalid, repeated, and pre-reporting closes durably", %{conn: conn} do
    rejected =
      submit(conn, [%{operation_id: "close-before-start", type: "close_finance_period"}])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert rejected == %{
             "operation_id" => "close-before-start",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    submit(conn, [start_reporting("start", "2026-01-05")]) |> json_response(200)

    invalid = [
      %{operation_id: "bad-date", type: "close_finance_period", period_end_on: "not-a-date"},
      %{operation_id: "before-start", type: "close_finance_period", period_end_on: "2026-01-04"},
      %{operation_id: "missing-date", type: "close_finance_period"},
      %{operation_id: "good-close", type: "close_finance_period", period_end_on: "2026-01-05"},
      %{operation_id: "same-close", type: "close_finance_period", period_end_on: "2026-01-05"},
      %{operation_id: "earlier-close", type: "close_finance_period", period_end_on: "2026-01-04"}
    ]

    results = submit(conn, invalid) |> json_response(200) |> Map.fetch!("results")

    assert Enum.map(results, &Map.get(&1, "code")) == [
             "invalid_period",
             "invalid_period",
             "invalid_period",
             nil,
             "invalid_period",
             "invalid_period"
           ]

    assert submit(conn, [Enum.at(invalid, 4)]) |> json_response(200) == %{
             "results" => [Enum.at(results, 4)]
           }
  end

  test "keeps signed late refund reversals visible", %{conn: conn} do
    submit(conn, [
      start_reporting("start", "2026-01-01"),
      open_group(),
      payment("pay", "2026-01-01", 500),
      %{
        operation_id: "cancel",
        type: "cancel_group",
        occurred_on: "2026-01-01",
        group_id: "group-1"
      },
      %{operation_id: "close-1", type: "close_finance_period", period_end_on: "2026-01-01"},
      %{
        operation_id: "chargeback",
        type: "charge_back_payment",
        occurred_on: "2026-01-01",
        payment_operation_id: "pay"
      }
    ])
    |> json_response(200)

    report =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-02")
      |> json_response(200)
      |> get_in(["data"])

    assert get_in(report, ["late_adjustments", "cash"]) == [
             %{
               "property_id" => "property-a",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -500,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 500
               }
             }
           ]

    assert get_in(report, ["cash", Access.at(0), "movements", "refunded_cents"]) == 0
    assert get_in(report, ["cash", Access.at(0), "closing_held_cents"]) == 0
  end

  test "puts late cash conversion and credit issuance in late adjustments", %{conn: conn} do
    submit(conn, [
      start_reporting("start", "2026-01-01"),
      open_group(),
      payment("pay", "2026-01-01", 500),
      %{operation_id: "close-1", type: "close_finance_period", period_end_on: "2026-01-01"},
      %{
        operation_id: "cancel-credit",
        type: "cancel_group",
        occurred_on: "2026-01-01",
        group_id: "group-1",
        refund_method: "hotel_credit"
      }
    ])
    |> json_response(200)

    report =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-02")
      |> json_response(200)
      |> get_in(["data"])

    assert get_in(report, [
             "late_adjustments",
             "cash",
             Access.at(0),
             "movements",
             "converted_to_credit_cents"
           ]) == 500

    assert get_in(report, ["late_adjustments", "credit", "issued_cents"]) == 550
    assert get_in(report, ["credit", "closing_liability_cents"]) == 550
    assert get_in(report, ["cash", Access.at(0), "closing_held_cents"]) == 0
  end

  test "expires a late-created credit lot after its fixed expiry", %{conn: conn} do
    submit(conn, [
      start_reporting("start", "2026-01-01"),
      open_group(),
      payment("pay", "2026-01-01", 500),
      %{operation_id: "close-1", type: "close_finance_period", period_end_on: "2027-01-02"},
      %{
        operation_id: "cancel-credit",
        type: "cancel_group",
        occurred_on: "2026-01-01",
        group_id: "group-1",
        refund_method: "hotel_credit"
      }
    ])
    |> json_response(200)

    report =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-03")
      |> json_response(200)
      |> get_in(["data"])

    assert get_in(report, ["late_adjustments", "credit", "issued_cents"]) == 550
    assert get_in(report, ["late_adjustments", "credit", "expired_cents"]) == 550
    assert get_in(report, ["credit", "closing_liability_cents"]) == 0
  end
end
