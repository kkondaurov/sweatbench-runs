defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "closes reports, keeps snapshots stable, and posts old-dated work as late", %{conn: conn} do
    submit(conn, [open_group("group-1")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
             submit(conn, [payment("pay-1", "group-1", 1_000, "2026-01-02")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-01-03"
               }
             ]
           } = submit(conn, [close_period("close-1", "2026-01-03")])

    assert %{
             "data" => %{
               "date" => "2026-01-02",
               "status" => "closed",
               "cash" => [%{"movements" => %{"received_cents" => 1_000}}],
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = get_report(conn, "2026-01-02")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 1_000,
                   "closing_held_cents" => 1_000
                 }
               ]
             }
           } = get_report(conn, "2026-01-03")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [payment("pay-late", "group-1", 500, "2026-01-02")])

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{"movements" => %{"received_cents" => 0}, "closing_held_cents" => 1_500}
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "property-1",
                     "movements" => %{"received_cents" => 500}
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
             }
           } = get_report(conn, "2026-01-04")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [close_period("close-2", "2026-01-04")])

    assert %{"data" => closed_report} = get_report(conn, "2026-01-04")
    assert closed_report["status"] == "closed"
    assert closed_report["late_adjustments"]["cash"] != []

    assert %{"data" => ^closed_report} = get_report(conn, "2026-01-04")
  end

  test "validates close order and replays both successful and rejected closes", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_period"} = rejected_result]} =
             submit(conn, [close_period("close-before-start", "2026-01-01")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [start_reporting("start-1", "2026-01-03")])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_period("close-before-start-date", "2026-01-02")])

    assert %{"results" => [%{"period_end_on" => "2026-01-05"}]} =
             submit(conn, [close_period("close-1", "2026-01-05")])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_period("close-same", "2026-01-05")])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_period("close-earlier", "2026-01-04")])

    assert %{"results" => [%{"period_end_on" => "2026-01-05"}]} =
             submit(conn, [close_period("close-1", "2026-01-05")])

    assert %{"results" => [^rejected_result]} =
             submit(conn, [close_period("close-before-start", "2026-01-01")])
  end

  test "posts operations after a close on the first open day in the same batch", %{conn: conn} do
    submit(conn, [open_group("group-1")])

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ]
           } =
             submit(conn, [
               start_reporting("start-1", "2026-01-01"),
               payment("pay-before-close", "group-1", 1_000, "2026-01-02"),
               close_period("close-1", "2026-01-02")
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [payment("pay-after-close", "group-1", 500, "2026-01-01")])

    assert %{
             "data" => %{
               "date" => "2026-01-03",
               "cash" => [%{"movements" => %{"received_cents" => 0}}],
               "late_adjustments" => %{
                 "cash" => [%{"movements" => %{"received_cents" => 500}}]
               }
             }
           } = get_report(conn, "2026-01-03")
  end

  test "carries daily credit opening liability from the prior closing balance", %{conn: conn} do
    submit(conn, [open_group("group-1")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-1", "group-1", 1_000, "2026-01-01")])

    assert %{"results" => [%{"credit_issued_cents" => 1_100}]} =
             submit(conn, [cancel("cancel-1", "group-1", "2026-01-02") |> hotel_credit()])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "closing_liability_cents" => 1_100
               }
             }
           } = get_report(conn, "2026-01-02")

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 1_100,
                 "closing_liability_cents" => 1_100
               }
             }
           } = get_report(conn, "2026-01-03")
  end

  test "preserves signed classifications in a late chargeback adjustment", %{conn: conn} do
    submit(conn, [open_group("group-1")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-1", "group-1", 1_000, "2026-01-01")])
    submit(conn, [cancel("cancel-1", "group-1", "2026-01-02")])
    submit(conn, [close_period("close-1", "2026-01-02")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [chargeback("chargeback-1", "pay-1")])

    assert %{
             "data" => %{
               "cash" => [],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "movements" => %{
                       "refunded_cents" => -1_000,
                       "charged_back_cents" => 1_000
                     }
                   }
                 ]
               }
             }
           } = get_report(conn, "2026-01-03")
  end

  test "posts restored credit as expired when a late cancellation crosses its expiry", %{
    conn: conn
  } do
    submit(conn, [open_group("source")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-source", "source", 1_000, "2026-01-01")])

    submit(conn, [cancel("cancel-source", "source", "2026-01-01") |> hotel_credit()])
    submit(conn, [open_group("target", "2027-02-01")])
    submit(conn, [credit_payment("apply-1", "target", 1_000, "2026-02-01")])
    submit(conn, [close_period("close-1", "2027-01-01")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [cancel("cancel-target", "target", "2026-12-31")])

    assert %{
             "data" => %{
               "late_adjustments" => %{
                 "credit" => %{"expired_cents" => 1_000}
               }
             }
           } = get_report(conn, "2027-01-02")
  end

  test "does not expire credit applied before its expiry when application posts late", %{
    conn: conn
  } do
    submit(conn, [open_group("source")])
    submit(conn, [start_reporting("start-1", "2026-01-01")])
    submit(conn, [payment("pay-source", "source", 1_000, "2026-01-01")])
    submit(conn, [cancel("cancel-source", "source", "2026-01-01") |> hotel_credit()])
    submit(conn, [open_group("target", "2027-02-01")])
    submit(conn, [close_period("close-1", "2027-01-01")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [credit_payment("apply-1", "target", 1_000, "2026-12-31")])

    assert %{
             "data" => %{
               "credit" => %{
                 "closing_liability_cents" => 1_000,
                 "movements" => %{"expired_cents" => 100}
               },
               "late_adjustments" => %{
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = get_report(conn, "2027-01-02")
  end

  defp open_group(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2025-12-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "property-1",
      "arrival_on" => "2026-02-01",
      "departure_on" => "2026-02-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    }
  end

  defp open_group(group_id, arrival_on) do
    open_group(group_id)
    |> Map.put("arrival_on", arrival_on)
    |> Map.put("departure_on", Date.add(Date.from_iso8601!(arrival_on), 1) |> Date.to_iso8601())
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_period(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp credit_payment(operation_id, group_id, amount_cents, occurred_on) do
    payment(operation_id, group_id, amount_cents, occurred_on)
    |> Map.put("type", "apply_hotel_credit")
  end

  defp cancel(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp hotel_credit(operation), do: Map.put(operation, "refund_method", "hotel_credit")

  defp chargeback(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
  end
end
