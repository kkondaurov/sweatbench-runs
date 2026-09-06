defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates, advances, and durably replays finance closes", %{conn: conn} do
    assert submit(conn, [close("before-start", "2026-10-05")]) |> only_result() == %{
             "operation_id" => "before-start",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    submit(conn, [start("start", "2026-10-05")])

    for operation <- [
          close("before-inception", "2026-10-04"),
          %{close("missing-cutoff", "2026-10-05") | "period_end_on" => nil},
          close("bad-cutoff", "not-a-date")
        ] do
      assert submit(conn, [operation]) |> only_result() |> Map.fetch!("code") ==
               "invalid_period"
    end

    result = submit(conn, [close("close-1", "2026-10-05")]) |> only_result()

    assert result == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2026-10-05"
           }

    assert submit(conn, [close("close-1", "2026-10-05")]) |> only_result() == result

    assert conn
           |> get("/api/v1/operations/close-1")
           |> json_response(200) == %{"data" => result}

    assert submit(conn, [close("close-1", "2026-10-06")]) |> only_result() == %{
             "operation_id" => "close-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    for {id, cutoff} <- [{"same-cutoff", "2026-10-05"}, {"earlier-cutoff", "2026-10-04"}] do
      assert submit(conn, [close(id, cutoff)]) |> only_result() |> Map.fetch!("code") ==
               "invalid_period"
    end

    assert report(conn, "2026-10-05")["status"] == "closed"
    assert report(conn, "2026-10-06")["status"] == "open"
  end

  test "same-batch close ordering freezes closed reports and moves old operations forward", %{
    conn: conn
  } do
    results =
      submit(conn, [
        open("group", "hotel-a", 1_000),
        start("start", "2026-10-05"),
        cash("before-close", "group", 40, "2026-10-01"),
        close("close-1", "2026-10-05"),
        cash("late-payment", "group", 50, "2026-10-02"),
        cash("open-payment", "group", 20, "2026-10-08")
      ])

    assert Enum.all?(results["results"], &(&1["status"] == "applied"))

    closed = report(conn, "2026-10-05")

    assert closed["status"] == "closed"

    assert closed["cash"] == [
             cash_entry("hotel-a", 0, %{"received_cents" => 40}, 40)
           ]

    assert closed["late_adjustments"] == empty_late_adjustments()

    first_open = report(conn, "2026-10-06")

    assert first_open["cash"] == [cash_entry("hotel-a", 40, %{}, 90)]

    assert first_open["late_adjustments"] == %{
             "cash" => [late_cash_entry("hotel-a", %{"received_cents" => 50})],
             "credit" => credit_movements()
           }

    assert report(conn, "2026-10-08")["cash"] == [
             cash_entry("hotel-a", 90, %{"received_cents" => 20}, 110)
           ]

    original_closed_body = report_body(conn, "2026-10-05")

    assert submit(conn, [close("close-2", "2026-10-08")])
           |> only_result()
           |> Map.fetch!("status") == "applied"

    submit(conn, [cash("later-late-payment", "group", 10, "2026-10-01")])

    assert report_body(conn, "2026-10-05") == original_closed_body

    second_first_open = report(conn, "2026-10-09")

    assert second_first_open["cash"] == [cash_entry("hotel-a", 110, %{}, 120)]

    assert second_first_open["late_adjustments"]["cash"] == [
             late_cash_entry("hotel-a", %{"received_cents" => 10})
           ]
  end

  test "late chargebacks preserve signed settlement classifications even at zero net", %{
    conn: conn
  } do
    submit(conn, [
      open("group", "hotel-a", 500),
      start("start", "2026-10-01"),
      cash("payment", "group", 100, "2026-10-01"),
      cancel("refund", "group", "2026-10-02"),
      close("close", "2026-10-02"),
      chargeback("chargeback", "payment", "2026-10-01")
    ])

    report = report(conn, "2026-10-03")

    assert report["cash"] == [cash_entry("hotel-a", 0, %{}, 0)]

    assert report["late_adjustments"]["cash"] == [
             late_cash_entry("hotel-a", %{
               "refunded_cents" => -100,
               "charged_back_cents" => 100
             })
           ]
  end

  test "late credit issuance is separated while its liability affects the closing balance", %{
    conn: conn
  } do
    submit(conn, [
      open("group", "hotel-a", 500),
      start("start", "2026-10-01"),
      cash("payment", "group", 100, "2026-10-01"),
      close("close", "2026-10-02"),
      cancel("issue-credit", "group", "2026-10-01", "hotel_credit")
    ])

    report = report(conn, "2026-10-03")

    assert report["credit"] == credit_entry(0, %{}, 110)

    assert report["late_adjustments"]["credit"] ==
             credit_movements(%{"issued_cents" => 110})

    assert report["late_adjustments"]["cash"] == [
             late_cash_entry("hotel-a", %{"converted_to_credit_cents" => 100})
           ]
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)

  defp only_result(%{"results" => [result]}), do: result

  defp report(conn, date),
    do:
      conn
      |> get("/api/v1/finance/daily-report?date=#{date}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp report_body(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> Map.fetch!(:resp_body)
  end

  defp open(group_id, property_id, nightly_rate),
    do: %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2028-12-10",
      "departure_on" => "2028-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }

  defp start(id, starts_on),
    do: %{
      "operation_id" => id,
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-01",
      "starts_on" => starts_on
    }

  defp close(id, period_end_on),
    do: %{
      "operation_id" => id,
      "type" => "close_finance_period",
      "occurred_on" => "2026-10-05",
      "period_end_on" => period_end_on
    }

  defp cash(id, group_id, amount, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }

  defp cancel(id, group_id, occurred_on, refund_method \\ nil) do
    operation = %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if refund_method,
      do: Map.put(operation, "refund_method", refund_method),
      else: operation
  end

  defp chargeback(id, payment_id, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }

  defp cash_entry(property_id, opening, overrides, closing),
    do: %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => cash_movements(overrides),
      "closing_held_cents" => closing
    }

  defp late_cash_entry(property_id, overrides),
    do: %{"property_id" => property_id, "movements" => cash_movements(overrides)}

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

  defp credit_entry(opening, overrides, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(overrides),
      "closing_liability_cents" => closing
    }

  defp credit_movements(overrides \\ %{}) do
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

  defp empty_late_adjustments,
    do: %{"cash" => [], "credit" => credit_movements()}
end
