defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, property_id \\ "hotel-b") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-12-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2027-12-10",
      "departure_on" => "2027-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
    }
  end

  defp pay(group_id, operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp start do
    %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-01"
    }
  end

  defp close(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp submit(conn, operations) do
    post(conn, ~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp report(conn, date) do
    get(recycle(conn), ~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates closes and durably replays their exact results", %{conn: conn} do
    assert %{"results" => [before_start, malformed]} =
             submit(conn, [close("before-start", "2027-01-01"), close("malformed", "bad")])

    assert before_start == %{
             "operation_id" => "before-start",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    assert malformed["code"] == "invalid_period"

    assert %{"results" => [_start, applied, replayed, same, earlier, later]} =
             submit(conn, [
               start(),
               close("close-1", "2027-01-01"),
               close("close-1", "2027-01-01"),
               close("same", "2027-01-01"),
               close("earlier", "2026-12-31"),
               close("close-2", "2027-01-02")
             ])

    assert applied == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2027-01-01"
           }

    assert replayed == applied
    assert same["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"
    assert later["status"] == "applied"

    assert %{"results" => [conflict]} = submit(conn, [close("close-1", "2027-01-03")])
    assert conflict["code"] == "operation_id_conflict"

    assert %{"results" => [remembered_rejection]} =
             submit(conn, [close("before-start", "2027-01-01")])

    assert remembered_rejection == before_start
  end

  test "freezes closed reports and posts old operations as late adjustments", %{conn: conn} do
    assert %{"results" => [_open, _start, _first, _close, _late]} =
             submit(conn, [
               open("group"),
               start(),
               pay("group", "first", 400, "2027-01-01"),
               close("close", "2027-01-01"),
               pay("group", "late", 600, "2026-12-01")
             ])

    closed = report(conn, "2027-01-01")
    assert closed["status"] == "closed"
    assert hd(closed["cash"])["movements"]["received_cents"] == 400
    assert closed["late_adjustments"]["cash"] == []

    open = report(conn, "2027-01-02")
    assert open["status"] == "open"
    assert hd(open["cash"])["movements"]["received_cents"] == 0

    assert open["late_adjustments"]["cash"] == [
             %{
               "property_id" => "hotel-b",
               "movements" => cash_movements(received_cents: 600)
             }
           ]

    assert hd(open["cash"])["opening_held_cents"] == 400
    assert hd(open["cash"])["closing_held_cents"] == 1_000

    submit(conn, [close("close-2", "2027-01-02"), pay("group", "later", 100, "2027-01-01")])

    assert report(conn, "2027-01-01") == closed
    assert report(conn, "2027-01-02") == Map.put(open, "status", "closed")

    day_three = report(conn, "2027-01-03")
    assert hd(day_three["late_adjustments"]["cash"])["movements"]["received_cents"] == 100
  end

  test "keeps signed zero-net cash corrections in late adjustments", %{conn: conn} do
    cancel = %{
      "operation_id" => "refund",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "group"
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-01",
      "payment_operation_id" => "payment"
    }

    submit(conn, [
      open("group"),
      pay("group", "payment", 1_000, "2027-01-01"),
      start(),
      cancel,
      close("close", "2027-01-01"),
      chargeback
    ])

    day = report(conn, "2027-01-02")
    late = hd(day["late_adjustments"]["cash"])["movements"]
    assert late["refunded_cents"] == -1_000
    assert late["charged_back_cents"] == 1_000
  end

  test "a later close does not move an already committed future posting", %{conn: conn} do
    submit(conn, [
      open("group"),
      start(),
      pay("group", "future", 500, "2027-01-03"),
      close("close", "2027-01-05")
    ])

    day = report(conn, "2027-01-03")
    assert day["status"] == "closed"
    assert hd(day["cash"])["movements"]["received_cents"] == 500
    assert day["late_adjustments"]["cash"] == []
  end

  test "moves corrections to closed credit expirations into the open period", %{conn: conn} do
    convert = %{
      "operation_id" => "convert",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "origin",
      "refund_method" => "hotel_credit"
    }

    apply_credit = %{
      "operation_id" => "apply",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-02",
      "group_id" => "target",
      "amount_cents" => 1_100
    }

    submit(conn, [
      open("origin"),
      pay("origin", "payment", 1_000, "2027-01-01"),
      open("target", "hotel-a"),
      start(),
      convert,
      close("close", "2028-01-02"),
      apply_credit
    ])

    expiry = report(conn, "2028-01-02")
    assert expiry["credit"]["movements"]["expired_cents"] == 1_100
    assert expiry["credit"]["closing_liability_cents"] == 0

    adjustment = report(conn, "2028-01-03")
    late_credit = adjustment["late_adjustments"]["credit"]
    assert late_credit["expired_cents"] == -1_100
    assert adjustment["credit"]["closing_liability_cents"] == 1_100
    assert report(conn, "2028-01-02") == expiry
  end

  defp cash_movements(overrides) do
    defaults = %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }

    Enum.reduce(overrides, defaults, fn {key, value}, result ->
      Map.put(result, Atom.to_string(key), value)
    end)
  end
end
