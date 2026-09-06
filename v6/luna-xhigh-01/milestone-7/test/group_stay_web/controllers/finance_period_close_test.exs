defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "publishes reports through a cutoff and posts old-dated movements after it", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [open_group(), cash_payment("payment", "2027-01-01", 100, 1)])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start_reporting()])

    assert %{
             "results" => [
               %{"revision" => 3},
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2027-01-01"
               }
             ]
           } =
             post_batch(conn, [
               cash_payment("before-close", "2027-01-01", 25, 2),
               close_period("close-1", "2027-01-01")
             ])

    closed_before = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-01"), 200)
    assert closed_before["data"]["status"] == "closed"
    assert closed_before["data"]["cash"] |> hd() |> Map.get("closing_held_cents") == 125

    assert %{"results" => [%{"revision" => 4}]} =
             post_batch(conn, [cash_payment("late-payment", "2026-12-31", 50, 3)])

    assert closed_before ==
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-01"), 200)

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{
                   "opening_held_cents" => 100,
                   "closing_held_cents" => 175,
                   "movements" => %{"received_cents" => 25}
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [%{"movements" => %{"received_cents" => 50}}]
               }
             }
           } = json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-02"), 200)

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [close_period("close-2", "2027-01-02")])

    assert %{"data" => %{"status" => "closed"}} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-02"), 200)

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             post_batch(conn, [close_period("close-too-early", "2027-01-02")])
  end

  test "requires reporting and uses durable replay and conflict rules", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_period"}]} =
             post_batch(conn, [close_period("close-before-start", "2027-01-01")])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [start_reporting()])

    close = close_period("close-replay", "2027-01-01")
    assert %{"results" => [applied]} = post_batch(conn, [close])
    assert %{"results" => [^applied]} = post_batch(conn, [close])

    conflict = Map.put(close, "period_end_on", "2027-01-02")

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             post_batch(conn, [conflict])
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open_group do
    %{
      "operation_id" => "open-close-group",
      "type" => "open_group",
      "occurred_on" => "2026-12-01",
      "group_id" => "close-group",
      "guest_id" => "close-guest",
      "property_id" => "close-property",
      "arrival_on" => "2027-02-01",
      "departure_on" => "2027-02-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1_000}]
    }
  end

  defp cash_payment(operation_id, occurred_on, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => "close-group",
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp start_reporting do
    %{
      "operation_id" => "start-close-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-01"
    }
  end

  defp close_period(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end
end
