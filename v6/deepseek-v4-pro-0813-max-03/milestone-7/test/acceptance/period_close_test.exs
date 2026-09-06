defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp start_reporting(operation_id, starts_on, occurred_on \\ "2026-10-01") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "occurred_on" => occurred_on,
      "starts_on" => starts_on
    }
  end

  defp close_period(operation_id, period_end_on, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "occurred_on" => occurred_on,
      "period_end_on" => period_end_on
    }
  end

  defp open(group_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{group_id}-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-02",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 10_000},
          %{"room_id" => "r2", "nightly_rate_cents" => 10_000}
        ]
      },
      extra
    )
  end

  defp pay(group_id, amount_cents, operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(group_id, occurred_on, operation_id, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extra
    )
  end

  defp charge_back(payment_operation_id, operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp report_ok(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cash_entry(conn, date, property_id) do
    %{"cash" => cash} = report_ok(conn, date)
    Enum.find(cash, &(&1["property_id"] == property_id))
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
  end

  defp cash_kinds do
    [
      "received_cents",
      "transferred_in_cents",
      "transferred_out_cents",
      "refunded_cents",
      "retained_cents",
      "converted_to_credit_cents",
      "reduced_cents",
      "charged_back_cents"
    ]
  end

  defp credit_kinds do
    ["issued_cents", "expired_cents", "consumed_cents", "revoked_cents", "absorbed_cents"]
  end

  defp zero_movements(kinds) do
    Map.new(kinds, &{&1, 0})
  end

  describe "close_finance_period" do
    test "applies only after reporting has started and returns exactly the required fields", %{
      conn: conn
    } do
      # Before reporting has started every close is invalid. This rejection is
      # remembered durably, so the post-start close below uses a fresh id.
      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               submit_batch(conn, [close_period("close-pre", "2026-10-05")])

      # Retrying the rejected close replays the original rejection.
      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               submit_batch(conn, [close_period("close-pre", "2026-10-05")])

      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      # A cutoff before starts_on is invalid.
      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               submit_batch(conn, [close_period("close-before", "2026-09-30")])

      close_op = close_period("close-1", "2026-10-05")

      %{"results" => [applied]} = submit_batch(conn, [close_op])

      assert applied == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2026-10-05"
             }

      # The retry replays the exact stored result.
      assert %{"results" => [again]} = submit_batch(conn, [close_op])
      assert again == applied

      assert %{"data" => stored} =
               conn
               |> get("/api/v1/operations/close-1")
               |> json_response(200)

      assert stored == applied

      # A different operation for the same or an earlier cutoff is rejected.
      for {id, cutoff} <- [{"close-same", "2026-10-05"}, {"close-earlier", "2026-10-04"}] do
        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
                 submit_batch(conn, [close_period(id, cutoff)])
      end

      # A strictly later close still applies.
      assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-10-06"}]} =
               submit_batch(conn, [close_period("close-later", "2026-10-06")])
    end

    test "rejects a missing or invalid period_end_on as invalid_period", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      missing = %{
        "operation_id" => "close-x",
        "type" => "close_finance_period",
        "occurred_on" => "2026-10-05"
      }

      invalid = close_period("close-y", "2026-13-99")
      bad_shape = close_period("close-z", "2026-10-05") |> Map.put("period_end_on", 12)

      for op <- [missing, invalid, bad_shape] do
        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
                 submit_batch(conn, [op])
      end

      # None of those closed anything; a valid close still works.
      assert %{"results" => [%{"status" => "applied"}]} =
               submit_batch(conn, [close_period("close-ok", "2026-10-05")])
    end

    test "a different payload with an applied close identifier conflicts", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])
      submit_batch(conn, [close_period("close-1", "2026-10-03")])

      assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
               submit_batch(conn, [close_period("close-1", "2026-10-01")])
    end
  end

  describe "closing freezes reports" do
    test "reports through the cutoff become closed and stay stable", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        open("g-1"),
        pay("g-1", 2_000, "p-1", "2026-10-02")
      ])

      open_report = report_ok(conn, "2026-10-02")
      assert open_report["status"] == "open"

      assert open_report["late_adjustments"] == %{
               "cash" => [],
               "credit" => zero_movements(credit_kinds())
             }

      submit_batch(conn, [close_period("close-1", "2026-10-05")])

      closed = report_ok(conn, "2026-10-02")
      assert closed["status"] == "closed"
      assert Map.has_key?(closed, "late_adjustments")

      for date <- ["2026-10-03", "2026-10-04", "2026-10-05"] do
        assert report_ok(conn, date)["status"] == "closed"
      end

      # An old-dated operation processed after the close cannot rewrite the
      # frozen reports; it posts on the first open day with a late adjustment.
      submit_batch(conn, [pay("g-1", 500, "p-2", "2026-10-03")])

      first_open_day = report_ok(conn, "2026-10-06")
      assert first_open_day["status"] == "open"

      assert first_open_day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "prop-1",
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

      first_entry = cash_entry(conn, "2026-10-06", "prop-1")
      assert first_entry["opening_held_cents"] == 2_000
      assert first_entry["movements"]["received_cents"] == 0
      assert first_entry["closing_held_cents"] == 2_500

      # A later close freezes that late adjustment too, unchanged except for
      # the published status.
      submit_batch(conn, [close_period("close-2", "2026-10-07")])

      frozen = report_ok(conn, "2026-10-06")
      assert frozen["status"] == "closed"
      assert frozen["cash"] == first_open_day["cash"]
      assert frozen["credit"] == first_open_day["credit"]
      assert frozen["late_adjustments"] == first_open_day["late_adjustments"]
      assert report_ok(conn, "2026-10-02") == closed

      # A still later operation again posts on the new first open day.
      submit_batch(conn, [pay("g-1", 700, "p-3", "2026-10-05")])

      moved = report_ok(conn, "2026-10-08")
      assert moved["status"] == "open"

      assert moved["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "prop-1",
                 "movements" => %{
                   "received_cents" => 700,
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

      entry = cash_entry(conn, "2026-10-08", "prop-1")
      assert entry["opening_held_cents"] == 2_500
      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 3_200

      # The frozen reports are untouched by the newest operation.
      assert report_ok(conn, "2026-10-02") == closed
      assert report_ok(conn, "2026-10-06") == frozen
    end

    test "operations in the open period keep their own posting date", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        open("g-1"),
        pay("g-1", 1_000, "p-1", "2026-10-02"),
        close_period("close-1", "2026-10-05")
      ])

      submit_batch(conn, [pay("g-1", 300, "p-2", "2026-10-07")])

      moved = report_ok(conn, "2026-10-07")
      assert moved["status"] == "open"
      assert moved["late_adjustments"]["cash"] == []

      entry = cash_entry(conn, "2026-10-07", "prop-1")
      assert entry["opening_held_cents"] == 1_000
      assert entry["movements"]["received_cents"] == 300
      assert entry["closing_held_cents"] == 1_300
    end

    test "batch ordering around a close decides whether a movement is late", %{conn: conn} do
      submit_batch(conn, [start_reporting("start-1", "2026-10-01")])

      assert %{"results" => [_, _, %{"status" => "applied"}, %{"status" => "applied"}]} =
               submit_batch(conn, [
                 open("g-1"),
                 pay("g-1", 1_000, "p-1", "2026-10-02"),
                 close_period("close-1", "2026-10-03"),
                 pay("g-1", 400, "p-2", "2026-10-02")
               ])

      # The payment before the close posted inside the closed period.
      closed = report_ok(conn, "2026-10-02")
      assert closed["status"] == "closed"
      assert cash_entry(conn, "2026-10-02", "prop-1")["movements"]["received_cents"] == 1_000

      # The payment after the close posted on the first open day.
      moved = report_ok(conn, "2026-10-04")
      assert moved["status"] == "open"

      assert moved["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "prop-1",
                 "movements" =>
                   %{"received_cents" => 400}
                   |> Map.merge(zero_movements(cash_kinds() -- ["received_cents"]))
               }
             ]

      entry = cash_entry(conn, "2026-10-04", "prop-1")
      assert entry["opening_held_cents"] == 1_000
      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 1_400
    end
  end

  describe "late adjustments" do
    test "a late chargeback keeps signed classifications", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        open("g-1"),
        pay("g-1", 100, "p-1", "2026-10-02"),
        cancel("g-1", "2026-11-20", "c-1")
      ])

      submit_batch(conn, [close_period("close-1", "2026-11-25")])

      submit_batch(conn, [charge_back("p-1", "cb-1", "2026-11-21")])

      moved = report_ok(conn, "2026-11-26")

      assert moved["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "prop-1",
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => -100,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 100
                 }
               }
             ]

      assert moved["late_adjustments"]["credit"] == zero_movements(credit_kinds())

      # The net held effect is zero, so the ordinary cash entry is omitted,
      # while the signed late adjustments remain visible.
      assert cash_entry(conn, "2026-11-26", "prop-1") == nil

      # The closed refund report is untouched.
      closed = report_ok(conn, "2026-11-20")
      assert closed["status"] == "closed"
      assert cash_entry(conn, "2026-11-20", "prop-1")["movements"]["refunded_cents"] == 100
    end

    test "late credit issuance appears in the credit block and balances use it", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        close_period("close-1", "2026-11-26")
      ])

      submit_batch(conn, [
        open("g-2"),
        pay("g-2", 6_000, "p-1", "2026-10-10"),
        cancel("g-2", "2026-11-26", "c-1", %{"refund_method" => "hotel_credit"})
      ])

      moved = report_ok(conn, "2026-11-27")

      assert moved["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "prop-1",
                 "movements" =>
                   %{
                     "received_cents" => 6_000,
                     "converted_to_credit_cents" => 6_000
                   }
                   |> Map.merge(
                     zero_movements(
                       cash_kinds() -- ["received_cents", "converted_to_credit_cents"]
                     )
                   )
               }
             ]

      assert moved["late_adjustments"]["credit"] == %{
               "issued_cents" => 6_600,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      # Ordinary movements are empty; opening and closing balances use both.
      assert moved["credit"]["movements"] == zero_movements(credit_kinds())
      assert moved["credit"]["opening_liability_cents"] == 0
      assert moved["credit"]["closing_liability_cents"] == 6_600

      entry = cash_entry(conn, "2026-11-27", "prop-1")

      # Held cash nets to zero through the late received/converted pair, so
      # the ordinary cash list omits the property entirely.
      assert entry == nil

      # Reports reconcile with the current views.
      assert moved["credit"]["closing_liability_cents"] ==
               ledger(conn)["data"]["credit_liability_cents"]
    end

    test "late adjustments are ordered by property and omit all-zero properties", %{conn: conn} do
      submit_batch(conn, [
        start_reporting("start-1", "2026-10-01"),
        close_period("close-1", "2026-10-05")
      ])

      submit_batch(conn, [
        open("g-1", %{"property_id" => "prop-z", "operation_id" => "g-1-open"}),
        open("g-2", %{"property_id" => "prop-a", "operation_id" => "g-2-open"}),
        pay("g-1", 700, "p-1", "2026-10-02"),
        pay("g-2", 900, "p-2", "2026-10-03")
      ])

      moved = report_ok(conn, "2026-10-06")

      assert Enum.map(moved["late_adjustments"]["cash"], & &1["property_id"]) == [
               "prop-a",
               "prop-z"
             ]

      # A later day has nothing late and therefore an empty cash list.
      assert report_ok(conn, "2026-10-07")["late_adjustments"]["cash"] == []
    end
  end
end
