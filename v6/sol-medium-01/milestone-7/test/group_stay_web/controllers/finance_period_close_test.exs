defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "close validates its cutoff and follows durable replay rules", %{conn: conn} do
    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_operation("before-reporting", "2026-10-03")])

    start_reporting(conn, "2026-10-02")
    close = close_operation("close-first", "2026-10-03")

    for {operation_id, period_end_on} <- [
          {"bad-close", "not-a-date"},
          {"missing-close", nil},
          {"before-start", "2026-10-01"}
        ] do
      operation = close_operation(operation_id, period_end_on)
      assert %{"results" => [%{"code" => "invalid_period"}]} = submit(conn, [operation])
    end

    expected = %{
      "operation_id" => "close-first",
      "status" => "applied",
      "period_end_on" => "2026-10-03"
    }

    assert %{"results" => [^expected]} = submit(conn, [close])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_operation("same-cutoff", "2026-10-03")])

    assert %{"results" => [%{"code" => "invalid_period"}]} =
             submit(conn, [close_operation("earlier-cutoff", "2026-10-02")])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [close_operation("close-later", "2026-10-04")])

    assert %{"results" => [^expected]} = submit(conn, [close])

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [Map.put(close, "period_end_on", "2026-10-05")])

    assert %{"data" => ^expected} = get_json(conn, "/api/v1/operations/close-first")
  end

  test "same-batch close freezes prior days and moves old-dated work to the first open day", %{
    conn: conn
  } do
    start_reporting(conn, "2026-10-01")
    submit(conn, [open("open-group", "group", "property-z")])

    response =
      submit(conn, [
        cash("before-close", "group", 500, "2026-10-02"),
        close_operation("close-through-two", "2026-10-02"),
        cash("after-close", "group", 400, "2026-09-01"),
        cash("future-dated", "group", 300, "2026-10-05")
      ])

    assert Enum.at(response["results"], 1) == %{
             "operation_id" => "close-through-two",
             "status" => "applied",
             "period_end_on" => "2026-10-02"
           }

    frozen = report(conn, "2026-10-02")
    assert frozen["status"] == "closed"
    assert [closed_cash] = frozen["cash"]
    assert closed_cash["movements"] == cash_movements(%{"received_cents" => 500})
    assert frozen["late_adjustments"] == empty_late_adjustments()

    first_open = report(conn, "2026-10-03")
    assert first_open["status"] == "open"
    assert [cash_entry] = first_open["cash"]
    assert cash_entry["opening_held_cents"] == 500
    assert cash_entry["movements"] == cash_movements(%{})
    assert cash_entry["closing_held_cents"] == 900

    assert first_open["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "property-z",
                 "movements" => cash_movements(%{"received_cents" => 400})
               }
             ],
             "credit" => credit_movements(%{})
           }

    assert [future_cash] = report(conn, "2026-10-05")["cash"]
    assert future_cash["movements"] == cash_movements(%{"received_cents" => 300})
    assert report(conn, "2026-10-05")["late_adjustments"] == empty_late_adjustments()

    submit(conn, [cash("another-late", "group", 200, "2026-10-02")])
    assert report(conn, "2026-10-02") == frozen

    before_second_close = report(conn, "2026-10-03")
    submit(conn, [close_operation("close-through-three", "2026-10-03")])
    after_second_close = report(conn, "2026-10-03")

    assert after_second_close == Map.put(before_second_close, "status", "closed")
    assert report(conn, "2026-10-02") == frozen

    submit(conn, [cash("post-second-close", "group", 100, "2026-09-01")])
    assert report(conn, "2026-10-03") == after_second_close
  end

  test "late chargebacks preserve signed zero-net classifications", %{conn: conn} do
    start_reporting(conn, "2026-10-01")

    submit(conn, [
      open("open-refund", "refund-group", "refund-property"),
      cash("refunded-payment", "refund-group", 1_000, "2026-10-01"),
      cancel("refund-payment", "refund-group", "2026-10-02"),
      close_operation("close-refund", "2026-10-03"),
      chargeback("late-chargeback", "refunded-payment", "2026-10-02")
    ])

    report = report(conn, "2026-10-04")
    assert [cash_entry] = report["cash"]
    assert cash_entry["opening_held_cents"] == 0
    assert cash_entry["closing_held_cents"] == 0
    assert cash_entry["movements"] == cash_movements(%{})

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "refund-property",
               "movements" =>
                 cash_movements(%{
                   "refunded_cents" => -1_000,
                   "charged_back_cents" => 1_000
                 })
             }
           ]
  end

  test "late credit effects stay out of ordinary movements and expire on the posting day", %{
    conn: conn
  } do
    start_reporting(conn, "2026-10-01")

    submit(conn, [
      open("open-credit", "credit-group", "credit-property"),
      cash("credit-payment", "credit-group", 1_000, "2026-10-01"),
      close_operation("close-before-credit", "2026-10-03"),
      cancel("late-credit", "credit-group", "2025-01-01", "hotel_credit")
    ])

    report = report(conn, "2026-10-04")
    assert report["credit"]["movements"] == credit_movements(%{})
    assert report["credit"]["opening_liability_cents"] == 0
    assert report["credit"]["closing_liability_cents"] == 0

    assert report["late_adjustments"]["credit"] ==
             credit_movements(%{"issued_cents" => 1_100, "expired_cents" => 1_100})

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "credit-property",
               "movements" => cash_movements(%{"converted_to_credit_cents" => 1_000})
             }
           ]
  end

  defp start_reporting(conn, starts_on) do
    submit(conn, [
      %{
        "operation_id" => "start-#{starts_on}",
        "type" => "start_finance_reporting",
        "starts_on" => starts_on
      }
    ])
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open(operation_id, group_id, property_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest-period-close",
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
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

  defp chargeback(operation_id, payment_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }
  end

  defp report(conn, date) do
    get_json(conn, "/api/v1/finance/daily-report?date=#{date}") |> Map.fetch!("data")
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_json(conn, path) do
    conn |> get(path) |> json_response(200)
  end

  defp empty_late_adjustments,
    do: %{"cash" => [], "credit" => credit_movements(%{})}

  defp cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit_movements(overrides) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end
end
