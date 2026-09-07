defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  describe "closing finance periods" do
    test "validates the cutoff and durably replays successful and rejected closes", %{conn: conn} do
      before_start = close_period("close-before-start", "2026-10-01")

      assert %{"results" => [%{"code" => "invalid_period"} = rejected]} =
               submit(conn, [before_start])

      assert %{"results" => [^rejected]} = submit(conn, [before_start])

      submit(conn, [start_reporting("start", "2026-10-02")])

      assert_close_rejected(conn, close_period("before-inception", "2026-10-01"))
      assert_close_rejected(conn, close_period("invalid-date", "2026-02-30"))

      assert_close_rejected(conn, %{
        "operation_id" => "missing-date",
        "type" => "close_finance_period"
      })

      close = close_period("close", "2026-10-03")

      assert %{
               "results" => [
                 %{
                   "operation_id" => "close",
                   "status" => "applied",
                   "period_end_on" => "2026-10-03"
                 }
               ]
             } = submit(conn, [close])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "close",
                   "status" => "applied",
                   "period_end_on" => "2026-10-03"
                 }
               ]
             } = submit(conn, [close])

      assert_close_rejected(conn, close_period("same-cutoff", "2026-10-03"))
      assert_close_rejected(conn, close_period("earlier-cutoff", "2026-10-02"))

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               submit(conn, [close_period("close", "2026-10-04")])
    end

    test "publishes immutable reports and floors later old-dated operations", %{conn: conn} do
      submit(conn, [
        open_group("open", "group", "ams", 5_000),
        start_reporting("start", "2026-10-01")
      ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "period_end_on" => "2026-10-02"},
                 %{"status" => "applied"}
               ]
             } =
               submit(conn, [
                 cash_payment("before-close", "group", 100, "2026-09-20"),
                 close_period("close", "2026-10-02"),
                 cash_payment("after-close", "group", 200, "2026-09-21")
               ])

      closed_start = report(conn, "2026-10-01")

      assert closed_start["status"] == "closed"
      assert closed_start["cash"] |> only_cash_entry() |> movement("received_cents") == 100
      assert closed_start["late_adjustments"] == empty_late_adjustments()

      assert report(conn, "2026-10-02")["status"] == "closed"

      first_open = report(conn, "2026-10-03")
      cash = only_cash_entry(first_open["cash"])
      late_cash = only_cash_entry(first_open["late_adjustments"]["cash"])

      assert first_open["status"] == "open"
      assert cash["opening_held_cents"] == 100
      assert cash["closing_held_cents"] == 300
      assert movement(cash, "received_cents") == 0
      assert movement(late_cash, "received_cents") == 200
      assert first_open["late_adjustments"]["credit"] == empty_credit_movements()

      submit(conn, [cash_payment("another-late", "group", 50, "2026-10-01")])

      assert report(conn, "2026-10-01") == closed_start

      assert report(conn, "2026-10-03")["late_adjustments"]["cash"]
             |> only_cash_entry()
             |> movement("received_cents") == 250

      submit(conn, [close_period("second-close", "2026-10-03")])
      assert report(conn, "2026-10-01") == closed_start
      assert report(conn, "2026-10-03")["status"] == "closed"

      submit(conn, [cash_payment("after-second-close", "group", 25, "2026-09-01")])

      second_open = report(conn, "2026-10-04")
      assert second_open["status"] == "open"

      assert second_open["late_adjustments"]["cash"]
             |> only_cash_entry()
             |> movement("received_cents") == 25
    end
  end

  describe "late adjustments" do
    test "keeps signed settlement reversals even when their net cash effect is zero", %{
      conn: conn
    } do
      submit(conn, [
        open_group("open", "group", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "group", 100, "2026-10-01"),
        cancel("cancel", "group", "2026-10-02"),
        close_period("close", "2026-10-02"),
        chargeback("chargeback", "payment", "2026-10-01")
      ])

      report = report(conn, "2026-10-03")
      cash = only_cash_entry(report["cash"])
      late_cash = only_cash_entry(report["late_adjustments"]["cash"])

      assert cash["opening_held_cents"] == 0
      assert cash["closing_held_cents"] == 0
      assert movement(cash, "refunded_cents") == 0
      assert movement(cash, "charged_back_cents") == 0
      assert movement(late_cash, "refunded_cents") == -100
      assert movement(late_cash, "charged_back_cents") == 100
    end

    test "reverses a published expiry when old-dated credit is applied after close", %{conn: conn} do
      submit(conn, [
        open_group("open-source", "source", "ams", 5_000),
        start_reporting("start", "2026-10-01"),
        cash_payment("payment", "source", 1_000, "2026-10-01"),
        cancel("issue", "source", "2026-10-02", "hotel_credit"),
        close_period("close", "2027-10-03"),
        open_advance_group("open-use", "use", "bru", 400),
        hotel_credit("use-credit", "use", 400, "2027-10-02")
      ])

      published_expiry = report(conn, "2027-10-03")
      assert published_expiry["status"] == "closed"
      assert published_expiry["credit"]["movements"]["expired_cents"] == 1_100
      assert published_expiry["credit"]["closing_liability_cents"] == 0

      first_open = report(conn, "2027-10-04")

      assert first_open["credit"]["opening_liability_cents"] == 0
      assert first_open["credit"]["movements"]["expired_cents"] == 0
      assert first_open["late_adjustments"]["credit"]["expired_cents"] == -400
      assert first_open["credit"]["closing_liability_cents"] == 400
      assert report(conn, "2027-10-03") == published_expiry
    end
  end

  defp assert_close_rejected(conn, operation) do
    assert %{"results" => [%{"code" => "invalid_period", "status" => "rejected"}]} =
             submit(conn, [operation])
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp only_cash_entry([entry]), do: entry
  defp movement(entry, classification), do: entry["movements"][classification]

  defp empty_late_adjustments do
    %{"cash" => [], "credit" => empty_credit_movements()}
  end

  defp empty_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
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

  defp open_group(operation_id, group_id, property_id, nightly_rate) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }
  end

  defp open_advance_group(operation_id, group_id, property_id, due) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-10-02",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2028-12-20",
      "departure_on" => "2028-12-21",
      "rate_plan" => "advance_purchase",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => due}]
    }
  end

  defp cash_payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp hotel_credit(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp chargeback(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end
end
