defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates, durably closes, and rejects overlapping finance periods", %{conn: conn} do
    assert submit(conn, [close_period("before-start", "2027-01-10")]) == %{
             "results" => [
               %{
                 "operation_id" => "before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert submit(conn, [start_reporting("start-reporting", "2027-01-10")]) == %{
             "results" => [
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2027-01-10"
               }
             ]
           }

    assert submit(conn, [close_period("missing-period", nil)]) == %{
             "results" => [
               %{
                 "operation_id" => "missing-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert submit(conn, [close_period("before-reporting", "2027-01-09")]) == %{
             "results" => [
               %{
                 "operation_id" => "before-reporting",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    closed = %{
      "operation_id" => "close-1",
      "status" => "applied",
      "period_end_on" => "2027-01-10"
    }

    assert submit(conn, [close_period("close-1", "2027-01-10")]) == %{"results" => [closed]}
    assert submit(conn, [close_period("close-1", "2027-01-10")]) == %{"results" => [closed]}

    assert submit(conn, [close_period("same-period", "2027-01-10")]) == %{
             "results" => [
               %{
                 "operation_id" => "same-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert submit(conn, [close_period("earlier-period", "2027-01-09")]) == %{
             "results" => [
               %{
                 "operation_id" => "earlier-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert daily_report(conn, "2027-01-10") == %{
             "date" => "2027-01-10",
             "status" => "closed",
             "cash" => [],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" => late_adjustments()
           }
  end

  test "freezes closed reports and posts old-dated cash into late adjustments", %{conn: conn} do
    submit(conn, [
      open_group("open-first", "first", "ams-canal", "2027-01-01"),
      cash_payment("opening-payment", "first", 1_000, 1, "2027-01-01"),
      start_reporting("start-reporting", "2027-01-10"),
      cash_payment("day-ten-payment", "first", 1_000, 2, "2027-01-10"),
      close_period("close-first", "2027-01-10")
    ])

    closed_report = daily_report(conn, "2027-01-10")

    assert closed_report == %{
             "date" => "2027-01-10",
             "status" => "closed",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(received_cents: 1_000),
                 "closing_held_cents" => 2_000
               }
             ],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" => late_adjustments()
           }

    submit(conn, [
      open_group("open-late", "late", "ams-canal", "2027-01-01"),
      cash_payment("late-payment", "late", 1_000, 1, "2027-01-05")
    ])

    assert daily_report(conn, "2027-01-10") == closed_report

    assert daily_report(conn, "2027-01-11") == %{
             "date" => "2027-01-11",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 2_000,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 3_000
               }
             ],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" =>
               late_adjustments(cash: [late_cash("ams-canal", received_cents: 1_000)])
           }

    assert submit(conn, [cash_payment("open-period-payment", "late", 1_000, 2, "2027-01-12")]) ==
             %{
               "results" => [
                 %{
                   "operation_id" => "open-period-payment",
                   "status" => "applied",
                   "group_id" => "late",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

    assert daily_report(conn, "2027-01-12") == %{
             "date" => "2027-01-12",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 3_000,
                 "movements" => cash_movements(received_cents: 1_000),
                 "closing_held_cents" => 4_000
               }
             ],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" => late_adjustments()
           }

    assert submit(conn, [close_period("close-second", "2027-01-11")]) == %{
             "results" => [
               %{
                 "operation_id" => "close-second",
                 "status" => "applied",
                 "period_end_on" => "2027-01-11"
               }
             ]
           }

    assert daily_report(conn, "2027-01-10") == closed_report
    assert daily_report(conn, "2027-01-11")["status"] == "closed"
  end

  test "reports late hotel-credit issuance separately while balances include it", %{conn: conn} do
    submit(conn, [
      open_group("open-source", "source", "ams-canal", "2027-01-01"),
      cash_payment("source-payment", "source", 1_000, 1, "2027-01-01"),
      start_reporting("start-reporting", "2027-01-10"),
      close_period("close-first", "2027-01-10"),
      cancel_group("cancel-source", "source", 2, "2027-01-02", "hotel_credit")
    ])

    assert daily_report(conn, "2027-01-11") == %{
             "date" => "2027-01-11",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 1_100),
             "late_adjustments" =>
               late_adjustments(
                 cash: [late_cash("ams-canal", converted_to_credit_cents: 1_000)],
                 credit: credit_movements(issued_cents: 1_100)
               )
           }
  end

  test "retains signed late cash classifications when their balance effect is zero", %{conn: conn} do
    submit(conn, [
      open_group("open-source", "source", "ams-canal", "2027-01-01"),
      start_reporting("start-reporting", "2027-01-10"),
      cash_payment("source-payment", "source", 1_000, 1, "2027-01-10"),
      cancel_group("cancel-source", "source", 2, "2027-01-10", "cash"),
      close_period("close-first", "2027-01-10"),
      charge_back("chargeback-source", "source-payment", 3, "2027-01-05")
    ])

    assert daily_report(conn, "2027-01-11") == %{
             "date" => "2027-01-11",
             "status" => "open",
             "cash" => [],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" =>
               late_adjustments(
                 cash: [
                   late_cash("ams-canal", refunded_cents: -1_000, charged_back_cents: 1_000)
                 ]
               )
           }
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp daily_report(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_group(operation_id, group_id, property_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "#{group_id}-room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_group(operation_id, group_id, expected_revision, occurred_on, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
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

  defp cash_movements(overrides \\ []) do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end))
  end

  defp credit_report(opening, issued, expired, consumed, revoked, absorbed, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" =>
        credit_movements(
          issued_cents: issued,
          expired_cents: expired,
          consumed_cents: consumed,
          revoked_cents: revoked,
          absorbed_cents: absorbed
        ),
      "closing_liability_cents" => closing
    }
  end

  defp late_adjustments(overrides \\ []) do
    %{
      "cash" => Keyword.get(overrides, :cash, []),
      "credit" => Keyword.get(overrides, :credit, credit_movements())
    }
  end

  defp late_cash(property_id, overrides) do
    %{"property_id" => property_id, "movements" => cash_movements(overrides)}
  end

  defp credit_movements(overrides \\ []) do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end))
  end
end
