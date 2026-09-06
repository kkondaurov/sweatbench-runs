defmodule GroupStayWeb.FinancePeriodCloseControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates period closes and durably replays an applied close", %{conn: conn} do
    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             post_batch(conn, [close("before-start", "2027-01-10")]) |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(build_conn(), [start_reporting("start", "2027-01-10")])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "invalid-date",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "before-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           } =
             post_batch(build_conn(), [
               %{"operation_id" => "invalid-date", "type" => "close_finance_period"},
               close("before-period", "2027-01-09")
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "close-period",
                 "status" => "applied",
                 "period_end_on" => "2027-01-10"
               }
             ]
           } =
             post_batch(build_conn(), [close("close-period", "2027-01-10")])
             |> json_response(200)

    assert %{"data" => close_result} =
             get(build_conn(), "/api/v1/operations/close-period") |> json_response(200)

    assert %{"results" => [^close_result]} =
             post_batch(build_conn(), [close("close-period", "2027-01-10")])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "close-period",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               },
               %{
                 "operation_id" => "same-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           } =
             post_batch(build_conn(), [
               close("close-period", "2027-01-11"),
               close("same-period", "2027-01-10")
             ])
             |> json_response(200)
  end

  test "freezes closed reports and posts later old-dated operations to the first open day", %{
    conn: conn
  } do
    assert %{"results" => results} =
             post_batch(conn, [
               start_reporting("start", "2027-01-10"),
               group("open-first", "first", "ams-canal"),
               payment("paid-in-period", "first", 10, "2027-01-10"),
               close("close-first", "2027-01-10"),
               payment("paid-late", "first", 10, "2027-01-01")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => closed_report} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(200)

    assert closed_report["status"] == "closed"

    assert closed_report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"received_cents" => 10}),
               "closing_held_cents" => 10
             }
           ]

    assert closed_report["late_adjustments"] == %{
             "cash" => [],
             "credit" => credit_movements()
           }

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 10,
                   "movements" => ordinary_cash,
                   "closing_held_cents" => 20
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => late_cash
                   }
                 ],
                 "credit" => late_credit
               }
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-11")
             |> json_response(200)

    assert ordinary_cash == cash_movements()
    assert late_cash == cash_movements(%{"received_cents" => 10})
    assert late_credit == credit_movements()

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(build_conn(), [close("close-second", "2027-01-11")])
             |> json_response(200)

    assert %{"results" => results} =
             post_batch(build_conn(), [
               group("open-second", "second", "berlin-mitte"),
               payment("paid-after-second-close", "second", 20, "2027-01-01")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => ^closed_report} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(200)

    assert %{"data" => %{"status" => "closed"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-11")
             |> json_response(200)

    assert %{
             "data" => %{
               "status" => "open",
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "berlin-mitte",
                     "movements" => late_cash
                   }
                 ]
               }
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-12")
             |> json_response(200)

    assert late_cash == cash_movements(%{"received_cents" => 20})
  end

  test "keeps signed late cash movements and reports late credit issuance", %{conn: conn} do
    assert %{"results" => results} =
             post_batch(conn, [
               start_reporting("start", "2027-01-10"),
               group("open-refund", "refund", "london-city"),
               payment("refund-payment", "refund", 20, "2027-01-11"),
               %{
                 "operation_id" => "refund",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-11",
                 "group_id" => "refund"
               },
               close("close-refund", "2027-01-11"),
               chargeback("refund-chargeback", "refund-payment", "2027-01-11"),
               group("open-credit", "credit", "ams-canal"),
               payment("credit-payment", "credit", 20, "2027-01-11"),
               %{
                 "operation_id" => "issue-late-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-11",
                 "group_id" => "credit",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "data" => %{
               "cash" => cash,
               "credit" => %{"movements" => ordinary_credit, "closing_liability_cents" => 22},
               "late_adjustments" => %{
                 "cash" => late_cash,
                 "credit" => late_credit
               }
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-12")
             |> json_response(200)

    assert ordinary_credit == credit_movements()
    assert late_credit == credit_movements(%{"issued_cents" => 22})

    assert Enum.find(cash, &(&1["property_id"] == "london-city"))["movements"] ==
             cash_movements()

    assert Enum.find(late_cash, &(&1["property_id"] == "london-city"))["movements"] ==
             cash_movements(%{"refunded_cents" => -20, "charged_back_cents" => 20})

    assert Enum.find(late_cash, &(&1["property_id"] == "ams-canal"))["movements"] ==
             cash_movements(%{"received_cents" => 20, "converted_to_credit_cents" => 20})
  end

  test "moves a backdated credit expiry into the first open report", %{conn: conn} do
    assert %{"results" => results} =
             post_batch(conn, [
               start_reporting("start", "2027-01-10"),
               close("close", "2027-01-20"),
               group("open-source", "source", "ams-canal"),
               payment("payment", "source", 20, "2027-01-11"),
               %{
                 "operation_id" => "backdated-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-01-03",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => ordinary_credit,
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{"credit" => late_credit}
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-21")
             |> json_response(200)

    assert ordinary_credit == credit_movements()

    assert late_credit ==
             credit_movements(%{"issued_cents" => 22, "expired_cents" => 22})
  end

  test "adjusts an already published expiry without changing the next open balance twice", %{
    conn: conn
  } do
    assert %{"results" => results} =
             post_batch(conn, [
               start_reporting("start", "2027-01-10"),
               group("open-source", "source", "ams-canal"),
               payment("source-payment", "source", 20, "2027-01-11"),
               %{
                 "operation_id" => "issue-expiring-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-01-11",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               },
               group("open-target", "target", "berlin-mitte"),
               close("close", "2027-01-20"),
               %{
                 "operation_id" => "apply-published-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-11",
                 "group_id" => "target",
                 "amount_cents" => 10
               },
               %{
                 "operation_id" => "apply-more-published-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-11",
                 "group_id" => "target",
                 "amount_cents" => 5
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => ordinary_credit,
                 "closing_liability_cents" => 15
               },
               "late_adjustments" => %{"credit" => late_credit}
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-21")
             |> json_response(200)

    assert ordinary_credit == credit_movements()
    assert late_credit == credit_movements(%{"expired_cents" => -15})
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{operations: operations})

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp group(operation_id, group_id, property_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
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

  defp chargeback(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id,
      "occurred_on" => occurred_on
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
