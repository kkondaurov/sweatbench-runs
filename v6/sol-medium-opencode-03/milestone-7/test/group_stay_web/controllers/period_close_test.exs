defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp open(id, property \\ "alpha") do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => id,
      "guest_id" => "guest-1",
      "property_id" => property,
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-#{id}", "nightly_rate_cents" => 10_000}]
    }
  end

  defp op(type, id, date, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => date}, attrs)
  end

  defp start(date \\ "2027-01-01") do
    %{"operation_id" => "start", "type" => "start_finance_reporting", "starts_on" => date}
  end

  defp close(id, date) do
    %{"operation_id" => id, "type" => "close_finance_period", "period_end_on" => date}
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates closes and durably replays an applied close", %{conn: conn} do
    [before_start] = submit(conn, [close("before-start", "2027-01-01")])
    assert before_start["code"] == "invalid_period"

    close_operation = close("close-1", "2027-01-02")

    [_, invalid_date, before_inception, applied, replay, duplicate, earlier] =
      submit(conn, [
        start("2027-01-02"),
        close("invalid-date", "bad"),
        close("before-inception", "2027-01-01"),
        close_operation,
        close_operation,
        close("duplicate", "2027-01-02"),
        close("earlier", "2027-01-01")
      ])

    assert invalid_date["code"] == "invalid_period"
    assert before_inception["code"] == "invalid_period"

    assert applied == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2027-01-02"
           }

    assert replay == applied
    assert duplicate["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"

    [conflict] = submit(conn, [Map.put(close_operation, "period_end_on", "2027-01-03")])
    assert conflict["code"] == "operation_id_conflict"
  end

  test "freezes closed reports and moves old-dated same-batch operations to the first open day",
       %{
         conn: conn
       } do
    [_, _, _, _, closed, late_payment] =
      submit(conn, [
        start(),
        open("before"),
        open("after", "beta"),
        op("record_cash_payment", "before-pay", "2027-01-02", %{
          "group_id" => "before",
          "amount_cents" => 1_000
        }),
        close("close-2", "2027-01-02"),
        op("record_cash_payment", "after-pay", "2027-01-01", %{
          "group_id" => "after",
          "amount_cents" => 500
        })
      ])

    assert closed["status"] == "applied"
    assert late_payment["status"] == "applied"
    published = report("2027-01-02")
    assert published["status"] == "closed"
    assert report("2027-01-02") == published

    day_three = report("2027-01-03")
    beta = Enum.find(day_three["cash"], &(&1["property_id"] == "beta"))
    late_beta = Enum.find(day_three["late_adjustments"]["cash"], &(&1["property_id"] == "beta"))

    assert beta["movements"]["received_cents"] == 0
    assert beta["closing_held_cents"] == 500
    assert late_beta["movements"]["received_cents"] == 500

    submit(conn, [close("close-3", "2027-01-03")])
    assert report("2027-01-02") == published
    assert report("2027-01-03")["status"] == "closed"
  end

  test "retains signed late classifications whose net balance effect is zero", %{conn: conn} do
    submit(conn, [
      start(),
      open("group"),
      op("record_cash_payment", "pay", "2027-01-01", %{
        "group_id" => "group",
        "amount_cents" => 1_000
      }),
      op("cancel_group", "cancel", "2027-01-02", %{"group_id" => "group"}),
      close("close", "2027-01-02"),
      op("charge_back_payment", "chargeback", "2027-01-01", %{
        "payment_operation_id" => "pay"
      })
    ])

    day_three = report("2027-01-03")
    ordinary = Enum.find(day_three["cash"], &(&1["property_id"] == "alpha"))
    late = Enum.find(day_three["late_adjustments"]["cash"], &(&1["property_id"] == "alpha"))

    assert ordinary["opening_held_cents"] == 0
    assert ordinary["closing_held_cents"] == 0
    assert late["movements"]["refunded_cents"] == -1_000
    assert late["movements"]["charged_back_cents"] == 1_000
  end

  test "reports credit resurrected by a historical application as a late expiry reversal", %{
    conn: conn
  } do
    submit(conn, [
      start(),
      open("source"),
      open("destination"),
      op("record_cash_payment", "pay", "2027-01-01", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      op("cancel_group", "issue", "2027-01-01", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      close("close-expiry", "2028-01-03"),
      op("apply_hotel_credit", "late-credit", "2027-01-02", %{
        "group_id" => "destination",
        "amount_cents" => 1_000
      })
    ])

    assert report("2028-01-03")["credit"]["closing_liability_cents"] == 0

    day_after = report("2028-01-04")
    assert day_after["credit"]["closing_liability_cents"] == 1_000
    assert day_after["credit"]["movements"]["expired_cents"] == 0
    assert day_after["late_adjustments"]["credit"]["expired_cents"] == -1_000
  end
end
