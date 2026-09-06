defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp open(id, operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => "hotel",
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 2_000}]
      },
      overrides
    )
  end

  defp operation(type, id, date, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => date}, attrs)
  end

  defp start(id \\ "start", date \\ "2026-10-03") do
    %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => date}
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

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates closes and durably replays their exact results", %{conn: conn} do
    assert [before_start] = submit(conn, [close("too-soon", "2026-10-03")])
    assert before_start["code"] == "invalid_period"

    assert [started, replayed_rejection] =
             submit(conn, [start(), close("too-soon", "2026-10-03")])

    assert started["status"] == "applied"
    assert replayed_rejection == before_start

    assert [invalid_date, before_inception] =
             submit(conn, [
               %{"operation_id" => "bad-date", "type" => "close_finance_period"},
               close("before-inception", "2026-10-02")
             ])

    assert invalid_date["code"] == "invalid_period"
    assert before_inception["code"] == "invalid_period"

    assert [closed] = submit(conn, [close("close-1", "2026-10-03")])

    assert closed == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    assert [same, earlier, later] =
             submit(conn, [
               close("same", "2026-10-03"),
               close("earlier", "2026-10-02"),
               close("close-2", "2026-10-04")
             ])

    assert same["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"
    assert later["status"] == "applied"
    assert submit(conn, [close("close-1", "2026-10-03")]) == [closed]

    assert [conflict] = submit(conn, [close("close-1", "2026-10-05")])
    assert conflict["code"] == "operation_id_conflict"
  end

  test "same-batch order fixes posting dates and later closes never move them", %{conn: conn} do
    assert Enum.all?(
             submit(conn, [
               open("group", "open"),
               start(),
               operation("record_cash_payment", "before-close", "2026-10-01", %{
                 "group_id" => "group",
                 "amount_cents" => 500
               }),
               close("close-1", "2026-10-03"),
               operation("record_cash_payment", "after-close", "2026-10-01", %{
                 "group_id" => "group",
                 "amount_cents" => 500
               })
             ]),
             &(&1["status"] == "applied")
           )

    closed = report(conn, "2026-10-03")
    assert closed["status"] == "closed"
    assert hd(closed["cash"])["movements"]["received_cents"] == 500
    assert closed["late_adjustments"]["cash"] == []

    open = report(conn, "2026-10-04")
    assert open["status"] == "open"
    assert hd(open["cash"])["movements"]["received_cents"] == 0
    assert hd(open["late_adjustments"]["cash"])["movements"]["received_cents"] == 500
    assert hd(open["cash"])["closing_held_cents"] == 1_000

    assert [next_close, paid] =
             submit(conn, [
               close("close-2", "2026-10-04"),
               operation("record_cash_payment", "after-next-close", "2026-10-01", %{
                 "group_id" => "group",
                 "amount_cents" => 500
               })
             ])

    assert next_close["status"] == "applied"
    assert paid["status"] == "applied"
    assert report(conn, "2026-10-03") == closed

    closed_late = report(conn, "2026-10-04")
    assert closed_late["status"] == "closed"
    assert Map.put(open, "status", "closed") == closed_late

    next_open = report(conn, "2026-10-05")
    assert hd(next_open["late_adjustments"]["cash"])["movements"]["received_cents"] == 500
    assert hd(next_open["cash"])["closing_held_cents"] == 1_500
  end

  test "keeps signed zero-net late reclassifications visible", %{conn: conn} do
    flexible =
      open("group", "open", %{
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })

    assert Enum.all?(
             submit(conn, [
               flexible,
               start(),
               operation("record_cash_payment", "pay", "2026-10-03", %{
                 "group_id" => "group",
                 "amount_cents" => 1_000
               }),
               operation("cancel_group", "cancel", "2026-10-04", %{"group_id" => "group"}),
               close("close", "2026-10-04"),
               operation("charge_back_payment", "charge", "2026-10-04", %{
                 "payment_operation_id" => "pay"
               })
             ]),
             &(&1["status"] == "applied")
           )

    daily = report(conn, "2026-10-05")
    [cash] = daily["cash"]
    [late] = daily["late_adjustments"]["cash"]

    assert cash["opening_held_cents"] == 0
    assert cash["closing_held_cents"] == 0
    assert cash["movements"]["refunded_cents"] == 0
    assert cash["movements"]["charged_back_cents"] == 0
    assert late["movements"]["refunded_cents"] == -1_000
    assert late["movements"]["charged_back_cents"] == 1_000
  end

  test "classifies every cash and credit effect of a late operation together", %{conn: conn} do
    flexible =
      open("group", "open", %{
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })

    assert Enum.all?(
             submit(conn, [
               flexible,
               operation("record_cash_payment", "pay", "2026-10-02", %{
                 "group_id" => "group",
                 "amount_cents" => 1_000
               }),
               start(),
               close("close", "2026-10-03"),
               operation("cancel_group", "cancel", "2026-10-03", %{
                 "group_id" => "group",
                 "refund_method" => "hotel_credit"
               })
             ]),
             &(&1["status"] == "applied")
           )

    daily = report(conn, "2026-10-04")
    [late_cash] = daily["late_adjustments"]["cash"]

    assert hd(daily["cash"])["movements"]["converted_to_credit_cents"] == 0
    assert late_cash["movements"]["converted_to_credit_cents"] == 1_000
    assert daily["credit"]["movements"]["issued_cents"] == 0
    assert daily["late_adjustments"]["credit"]["issued_cents"] == 1_100
    assert daily["credit"]["closing_liability_cents"] == 1_100
  end

  test "closed expiry stays fixed and a late historical application reverses expiry openly", %{
    conn: conn
  } do
    source =
      open("source", "open-source", %{
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })

    assert Enum.all?(
             submit(conn, [
               source,
               open("destination", "open-destination"),
               operation("record_cash_payment", "pay", "2026-10-02", %{
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }),
               start(),
               operation("cancel_group", "issue", "2026-10-03", %{
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }),
               close("close", "2027-10-04")
             ]),
             &(&1["status"] == "applied")
           )

    expiry = report(conn, "2027-10-04")
    assert expiry["status"] == "closed"
    assert expiry["credit"]["movements"]["expired_cents"] == 1_100
    assert expiry["credit"]["closing_liability_cents"] == 0

    assert [applied] =
             submit(conn, [
               operation("apply_hotel_credit", "apply", "2027-10-03", %{
                 "group_id" => "destination",
                 "amount_cents" => 400
               })
             ])

    assert applied["status"] == "applied"
    assert report(conn, "2027-10-04") == expiry

    correction = report(conn, "2027-10-05")
    assert correction["credit"]["opening_liability_cents"] == 0
    assert correction["late_adjustments"]["credit"]["expired_cents"] == -400
    assert correction["credit"]["closing_liability_cents"] == 400
  end
end
