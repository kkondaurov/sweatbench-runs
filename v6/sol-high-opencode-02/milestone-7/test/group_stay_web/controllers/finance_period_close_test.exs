defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates closes and durably replays their exact results", %{conn: conn} do
    rejected = close_period("before-start", "2027-01-01")

    assert %{"results" => [%{"code" => "invalid_period"} = result]} = submit(conn, [rejected])
    assert result["operation_id"] == "before-start"

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(build_conn(), [start_reporting("start", "2027-01-05")])

    assert submit(build_conn(), [rejected]) == %{"results" => [result]}

    for operation <- [
          %{"operation_id" => "missing", "type" => "close_finance_period"},
          close_period("malformed", "not-a-date"),
          close_period("before-inception", "2027-01-04")
        ] do
      assert %{"results" => [%{"code" => "invalid_period"}]} =
               submit(build_conn(), [operation])
    end

    first_close = close_period("close-first", "2027-01-05")

    assert submit(build_conn(), [first_close]) == %{
             "results" => [
               %{
                 "operation_id" => "close-first",
                 "status" => "applied",
                 "period_end_on" => "2027-01-05"
               }
             ]
           }

    assert %{"data" => %{"status" => "closed"}} = report("2027-01-05")
    assert %{"data" => %{"status" => "open"}} = report("2027-01-06")

    for operation <- [
          close_period("same-cutoff", "2027-01-05"),
          close_period("earlier-cutoff", "2027-01-04")
        ] do
      assert %{"results" => [%{"code" => "invalid_period"}]} =
               submit(build_conn(), [operation])
    end

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(build_conn(), [close_period("close-later", "2027-01-10")])

    assert submit(build_conn(), [first_close]) == %{
             "results" => [
               %{
                 "operation_id" => "close-first",
                 "status" => "applied",
                 "period_end_on" => "2027-01-05"
               }
             ]
           }

    assert json_response(get(build_conn(), "/api/v1/operations/close-first"), 200) == %{
             "data" => %{
               "operation_id" => "close-first",
               "status" => "applied",
               "period_end_on" => "2027-01-05"
             }
           }

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(build_conn(), [close_period("close-first", "2027-01-11")])
  end

  test "keeps closed reports stable and posts old operations as late adjustments", %{conn: conn} do
    assert %{"results" => results} =
             submit(conn, [
               start_reporting("start", "2027-01-01"),
               open_group("group-1", "open-1"),
               payment("group-1", "before-close", 40, "2027-01-01"),
               close_period("close", "2027-01-01")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    closed_report = report("2027-01-01")

    assert %{
             "data" => %{
               "status" => "closed",
               "cash" => [
                 %{
                   "movements" => %{"received_cents" => 40},
                   "closing_held_cents" => 40
                 }
               ],
               "late_adjustments" => %{"cash" => []}
             }
           } = closed_report

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             submit(build_conn(), [
               payment("group-1", "late-payment", 20, "2026-12-20"),
               payment("group-1", "open-payment", 20, "2027-01-03")
             ])

    assert report("2027-01-01") == closed_report

    assert %{"data" => first_open} = report("2027-01-02")
    assert first_open["status"] == "open"

    assert first_open["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 40,
               "movements" => cash_movements(),
               "closing_held_cents" => 60
             }
           ]

    assert first_open["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" => cash_movements(%{"received_cents" => 20})
             }
           ]

    assert %{"data" => third_day} = report("2027-01-03")
    assert hd(third_day["cash"])["movements"] == cash_movements(%{"received_cents" => 20})
    assert third_day["late_adjustments"]["cash"] == []

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(build_conn(), [close_period("second-close", "2027-01-02")])

    assert report("2027-01-01") == closed_report
    assert get_in(report("2027-01-02"), ["data", "status"]) == "closed"
  end

  test "keeps signed zero-net late cash classifications visible", %{conn: conn} do
    assert %{"results" => results} =
             submit(conn, [
               start_reporting("start", "2027-01-01"),
               open_group("group-1", "open-1"),
               payment("group-1", "payment", 100, "2027-01-02"),
               cancel("group-1", "refund", "2027-01-03"),
               close_period("close", "2027-01-03"),
               chargeback("chargeback", "payment", "2027-01-03")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert %{"data" => report} = report("2027-01-04")

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(),
               "closing_held_cents" => 0
             }
           ]

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams-canal",
               "movements" =>
                 cash_movements(%{"refunded_cents" => -100, "charged_back_cents" => 100})
             }
           ]
  end

  test "classifies forced credit expiry as late but later natural expiry as ordinary", %{
    conn: conn
  } do
    assert %{"results" => results} =
             submit(conn, [
               start_reporting("start", "2027-01-01"),
               open_group("forced", "open-forced"),
               payment("forced", "pay-forced", 100, "2027-01-01"),
               close_period("long-close", "2028-02-01"),
               cancel("forced", "forced-issue", "2027-01-01", "hotel_credit")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert %{"data" => forced} = report("2028-02-02")
    assert forced["credit"]["movements"] == credit_movements()

    assert forced["late_adjustments"]["credit"] ==
             credit_movements(%{"issued_cents" => 110, "expired_cents" => 110})

    assert forced["credit"]["closing_liability_cents"] == 0

    assert %{"results" => results} =
             submit(build_conn(), [
               open_group("natural", "open-natural"),
               payment("natural", "pay-natural", 100, "2028-02-03"),
               close_period("natural-close", "2028-02-03"),
               cancel("natural", "natural-issue", "2028-02-03", "hotel_credit")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert %{"data" => natural_issue} = report("2028-02-04")
    assert natural_issue["credit"]["movements"] == credit_movements()

    assert natural_issue["late_adjustments"]["credit"] ==
             credit_movements(%{"issued_cents" => 110})

    assert %{"data" => natural_expiry} = report("2029-02-03")
    assert natural_expiry["credit"]["movements"] == credit_movements(%{"expired_cents" => 110})
    assert natural_expiry["late_adjustments"]["credit"] == credit_movements()
  end

  test "reconciles credit consumed before its later reporting issue date", %{conn: conn} do
    assert %{"results" => results} =
             submit(conn, [
               start_reporting("start", "2027-01-01"),
               open_group("origin", "open-origin"),
               payment("origin", "payment", 100, "2027-01-02"),
               close_period("close", "2027-01-01"),
               cancel("origin", "issue", "2027-01-10", "hotel_credit"),
               open_group("spend", "open-spend"),
               apply_credit("spend", "apply", 80, "2027-01-01")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert %{"data" => expiry} = report("2028-01-11")
    assert expiry["credit"]["movements"] == credit_movements(%{"expired_cents" => 30})
    assert expiry["credit"]["closing_liability_cents"] == 80

    assert json_response(get(build_conn(), "/api/v1/ledger?on=2028-01-11"), 200)["data"][
             "credit_liability_cents"
           ] == 80
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end

  defp report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}") |> json_response(200)
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

  defp open_group(group_id, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 1_000}]
    }
  end

  defp payment(group_id, operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, operation_id, occurred_on, refund_method \\ "cash") do
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

  defp apply_credit(group_id, operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cash_movements(overrides \\ %{}) do
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
end
