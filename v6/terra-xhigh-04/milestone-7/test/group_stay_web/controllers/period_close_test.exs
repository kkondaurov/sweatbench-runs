defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: true

  import Phoenix.ConnTest

  test "closes strictly increasing reporting periods with durable replay", %{conn: conn} do
    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             post_operations(conn, [close_period("close-before-start", "2027-01-01")])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_operations(build_conn(), [start_reporting("start-reporting", "2027-01-02")])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             post_operations(build_conn(), [close_period("close-before-inception", "2027-01-01")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "close-first",
                 "status" => "applied",
                 "period_end_on" => "2027-01-02"
               }
             ]
           } = post_operations(build_conn(), [close_period("close-first", "2027-01-02")])

    assert %{"data" => %{"status" => "closed", "late_adjustments" => _}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "close-first",
                 "status" => "applied",
                 "period_end_on" => "2027-01-02"
               }
             ]
           } = post_operations(build_conn(), [close_period("close-first", "2027-01-02")])

    assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
             post_operations(build_conn(), [close_period("close-first", "2027-01-03")])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             post_operations(build_conn(), [close_period("close-again", "2027-01-02")])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             post_operations(build_conn(), [close_period("close-invalid-date", "not-a-date")])
  end

  test "publishes reports and posts old-dated effects to the first open day as late adjustments",
       %{
         conn: conn
       } do
    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "period_end_on" => "2027-01-02"}
             ]
           } =
             post_operations(conn, [
               start_reporting("start-reporting", "2027-01-01"),
               open_group("open-closed", "closed", "2027-01-01"),
               cash_payment("pay-closed", "closed", "2027-01-02", 1_000),
               close_period("close-first", "2027-01-02")
             ])

    closed_before =
      get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
      |> response(200)

    assert %{
             "data" => %{
               "date" => "2027-01-02",
               "status" => "closed",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{"received_cents" => 1_000},
                   "closing_held_cents" => 1_000
                 }
               ],
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
           } = Jason.decode!(closed_before)

    assert %{"results" => [%{"status" => "applied", "refunded_cents" => 1_000}]} =
             post_operations(build_conn(), [cancel_group("cancel-late", "closed", "2027-01-02")])

    assert closed_before ==
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
             |> response(200)

    assert %{
             "data" => %{
               "date" => "2027-01-03",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "movements" => %{"refunded_cents" => 0},
                   "closing_held_cents" => 0
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"refunded_cents" => 1_000}
                   }
                 ]
               }
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-03")
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_operations(build_conn(), [
               open_group("open-current", "current", "2027-01-04"),
               cash_payment("pay-current", "current", "2027-01-04", 1_000)
             ])

    assert %{
             "data" => %{
               "date" => "2027-01-04",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"received_cents" => 1_000},
                   "closing_held_cents" => 1_000
                 }
               ],
               "late_adjustments" => %{"cash" => []}
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200)
  end

  test "keeps late cash and credit effects separate when another period is closed", %{conn: conn} do
    post_operations(conn, [
      start_reporting("start-reporting", "2027-01-01"),
      close_period("close-first", "2027-01-01"),
      open_group("open-late-credit", "late-credit", "2027-01-01"),
      cash_payment("pay-late-credit", "late-credit", "2027-01-01", 1_000),
      cancel_group("convert-late-credit", "late-credit", "2027-01-01", "hotel_credit")
    ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 0,
                     "converted_to_credit_cents" => 0
                   },
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "movements" => %{"issued_cents" => 0},
                 "closing_liability_cents" => 1_100
               },
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{
                       "received_cents" => 1_000,
                       "converted_to_credit_cents" => 1_000
                     }
                   }
                 ],
                 "credit" => %{"issued_cents" => 1_100}
               }
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "period_end_on" => "2027-01-02"}]} =
             post_operations(build_conn(), [close_period("close-second", "2027-01-02")])

    closed =
      get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
      |> response(200)

    assert %{"data" => %{"status" => "closed", "late_adjustments" => %{"cash" => [_]}}} =
             Jason.decode!(closed)

    assert closed ==
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
             |> response(200)
  end

  test "retains signed late reclassification movements even when their cash balance nets to zero",
       %{
         conn: conn
       } do
    post_operations(conn, [
      start_reporting("start-reporting", "2027-01-01"),
      open_group("open-reclassified", "reclassified", "2027-01-01"),
      cash_payment("pay-reclassified", "reclassified", "2027-01-01", 1_000),
      cancel_group("cancel-reclassified", "reclassified", "2027-01-02"),
      close_period("close-first", "2027-01-02")
    ])

    assert %{"results" => [%{"status" => "applied", "charged_back_cents" => 1_000}]} =
             post_operations(build_conn(), [
               charge_back("charge-reclassified", "pay-reclassified", "2027-01-02")
             ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "refunded_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 0
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{
                       "refunded_cents" => -1_000,
                       "charged_back_cents" => 1_000
                     }
                   }
                 ]
               }
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-03")
             |> json_response(200)
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

  defp open_group(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-04-10",
      "departure_on" => "2027-04-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 5_000}]
    }
  end

  defp cash_payment(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_group(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp charge_back(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id,
      "occurred_on" => occurred_on
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
