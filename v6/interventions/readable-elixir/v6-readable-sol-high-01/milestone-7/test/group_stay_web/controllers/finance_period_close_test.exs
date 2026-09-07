defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "validates, durably replays, and strictly advances finance closes", %{conn: conn} do
    assert submit(conn, close_period("before-start", "2026-10-01")) == %{
             "operation_id" => "before-start",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    submit(conn, start_reporting("start", "2026-10-03"))

    for {operation_id, cutoff} <- [
          {"missing-date", nil},
          {"invalid-date", "not-a-date"},
          {"before-inception", "2026-10-02"}
        ] do
      operation =
        close_period(operation_id, cutoff)
        |> maybe_delete("period_end_on", is_nil(cutoff))

      assert submit(conn, operation) == %{
               "operation_id" => operation_id,
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    close = close_period("close-one", "2026-10-03")

    assert submit(conn, close) == %{
             "operation_id" => "close-one",
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    assert submit(conn, close) == submit(conn, close)

    assert submit(conn, close_period("same-cutoff", "2026-10-03"))["code"] ==
             "invalid_period"

    assert submit(conn, close_period("earlier-cutoff", "2026-10-02"))["code"] ==
             "invalid_period"

    assert submit(conn, close_period("close-one", "2026-10-04")) == %{
             "operation_id" => "close-one",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert submit(conn, close_period("close-two", "2026-10-05"))["status"] == "applied"
  end

  test "same-batch operations observe the close and published reports stay stable", %{conn: conn} do
    submit(conn, start_reporting("start", "2026-10-01"))
    submit(conn, open_group("group", "ams-canal"))

    assert [before_close, close, late, future] =
             submit_batch(conn, [
               cash_payment("before-close", "group", 500, "2026-10-02"),
               close_period("close", "2026-10-02"),
               cash_payment("late", "group", 300, "2026-09-01"),
               cash_payment("future", "group", 200, "2026-10-05")
             ])

    assert before_close["status"] == "applied"

    assert close == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2026-10-02"
           }

    assert late["status"] == "applied"
    assert future["status"] == "applied"

    closed_report = report(conn, "2026-10-02")
    assert closed_report["status"] == "closed"

    assert closed_report["cash"] == [
             cash_entry("ams-canal", 0, %{"received_cents" => 500}, 500)
           ]

    assert closed_report["late_adjustments"] == empty_late_adjustments()

    assert report(conn, "2026-10-03") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [cash_entry("ams-canal", 500, %{}, 800)],
             "credit" => credit_entry(0, %{}, 0),
             "late_adjustments" => %{
               "cash" => [late_cash_entry("ams-canal", %{"received_cents" => 300})],
               "credit" => credit_movements(%{})
             }
           }

    assert report(conn, "2026-10-05")["cash"] == [
             cash_entry("ams-canal", 800, %{"received_cents" => 200}, 1_000)
           ]

    assert submit(conn, close_period("later-close", "2026-10-04"))["status"] == "applied"
    assert report(conn, "2026-10-02") == closed_report
    assert report(conn, "2026-10-03")["status"] == "closed"
    assert report(conn, "2026-10-05")["status"] == "open"
  end

  test "keeps late cash classifications even when their balance effect nets to zero", %{
    conn: conn
  } do
    submit(conn, start_reporting("start", "2026-10-01"))
    submit(conn, open_group("refunded", "ams-canal"))
    submit(conn, cash_payment("payment", "refunded", 1_000, "2026-10-02"))
    submit(conn, cancel_group("refund", "refunded", "2026-10-03"))
    submit(conn, close_period("close", "2026-10-05"))

    assert submit(conn, charge_back("chargeback", "payment", "2026-10-03"))["status"] ==
             "applied"

    daily = report(conn, "2026-10-06")

    assert daily["cash"] == [cash_entry("ams-canal", 0, %{}, 0)]

    assert daily["late_adjustments"]["cash"] == [
             late_cash_entry("ams-canal", %{
               "refunded_cents" => -1_000,
               "charged_back_cents" => 1_000
             })
           ]
  end

  test "separates late credit issuance while using it in closing balances", %{conn: conn} do
    submit(conn, start_reporting("start", "2026-10-01"))
    submit(conn, open_group("group", "ams-canal"))
    submit(conn, cash_payment("payment", "group", 1_000, "2026-10-02"))
    submit(conn, close_period("close", "2026-10-05"))

    assert submit(
             conn,
             cancel_group("convert", "group", "2026-10-03", refund_method: "hotel_credit")
           )["status"] == "applied"

    daily = report(conn, "2026-10-06")

    assert daily["cash"] == [cash_entry("ams-canal", 1_000, %{}, 0)]
    assert daily["credit"] == credit_entry(0, %{}, 1_100)

    assert daily["late_adjustments"] == %{
             "cash" => [
               late_cash_entry("ams-canal", %{"converted_to_credit_cents" => 1_000})
             ],
             "credit" => credit_movements(%{"issued_cents" => 1_100})
           }
  end

  test "posts a backdated allocation of published-expired credit as an expiry reversal", %{
    conn: conn
  } do
    submit(conn, start_reporting("start", "2026-01-01"))
    submit(conn, open_group("original", "ams-canal"))
    submit(conn, cash_payment("payment", "original", 1_000, "2026-01-01"))

    submit(
      conn,
      cancel_group("issue", "original", "2026-01-02", refund_method: "hotel_credit")
    )

    submit(conn, open_group("funded", "ams-canal"))
    submit(conn, close_period("close", "2027-01-03"))

    assert report(conn, "2027-01-03")["credit"] ==
             credit_entry(1_100, %{"expired_cents" => 1_100}, 0)

    assert submit(conn, credit_payment("late-apply", "funded", 600, "2027-01-02"))[
             "status"
           ] == "applied"

    daily = report(conn, "2027-01-04")
    assert daily["credit"] == credit_entry(0, %{}, 600)

    assert daily["late_adjustments"]["credit"] ==
             credit_movements(%{"expired_cents" => -600})
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp submit(conn, operation), do: submit_batch(conn, [operation]) |> hd()

  defp submit_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
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

  defp open_group(group_id, property_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
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

  defp credit_payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_group(operation_id, group_id, occurred_on, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put("refund_method", opts[:refund_method])
  end

  defp charge_back(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => cash_movements(movements),
      "closing_held_cents" => closing
    }
  end

  defp late_cash_entry(property_id, movements) do
    %{
      "property_id" => property_id,
      "movements" => cash_movements(movements)
    }
  end

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

  defp credit_entry(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movements),
      "closing_liability_cents" => closing
    }
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

  defp empty_late_adjustments do
    %{"cash" => [], "credit" => credit_movements(%{})}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_delete(map, key, true), do: Map.delete(map, key)
  defp maybe_delete(map, _key, false), do: map
end
