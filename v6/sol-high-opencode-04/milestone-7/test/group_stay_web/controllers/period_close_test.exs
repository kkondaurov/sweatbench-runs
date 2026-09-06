defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "validates closes and applies durable replay rules", %{conn: conn} do
    close = close_operation("close-first", "2026-10-03")

    assert %{"results" => [before_start]} = submit(conn, [close])
    assert before_start == rejected("close-first", "invalid_period")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(build_conn(), [start_operation()])

    invalid = [
      close_operation("close-missing", "2026-10-03") |> Map.delete("period_end_on"),
      close_operation("close-bad", "2026-02-30"),
      close_operation("close-early", "2026-10-02")
    ]

    assert %{"results" => invalid_results} = submit(build_conn(), invalid)
    assert Enum.all?(invalid_results, &(&1["code"] == "invalid_period"))

    applied = close_operation("close-applied", "2026-10-03")

    assert %{"results" => [result]} = submit(build_conn(), [applied])

    assert result == %{
             "operation_id" => "close-applied",
             "period_end_on" => "2026-10-03",
             "status" => "applied"
           }

    assert %{"results" => [^result]} = submit(build_conn(), [applied])

    changed_payload = Map.put(applied, "period_end_on", "2026-10-04")

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(build_conn(), [changed_payload])

    assert %{"results" => [same, earlier]} =
             submit(build_conn(), [
               close_operation("close-same", "2026-10-03"),
               close_operation("close-earlier", "2026-10-02")
             ])

    assert same["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"

    assert %{"data" => ^result} =
             get(build_conn(), "/api/v1/operations/close-applied") |> json_response(200)

    assert %{"results" => [^before_start]} = submit(build_conn(), [close])
  end

  test "freezes closed reports and chooses posting dates at each batch position", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(),
      payment("pay-before", 1_000, "2026-10-03"),
      close_operation("close-3", "2026-10-03"),
      payment("pay-late", 500, "2026-09-01"),
      payment("pay-open", 250, "2026-10-05")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    closed_report = daily_report("2026-10-03")

    assert %{
             "status" => "closed",
             "cash" => [
               %{
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
           } = closed_report

    assert %{
             "status" => "open",
             "cash" => [
               %{
                 "opening_held_cents" => 1_000,
                 "movements" => %{"received_cents" => 0},
                 "closing_held_cents" => 1_500
               }
             ],
             "late_adjustments" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"received_cents" => 500}
                 }
               ]
             }
           } = daily_report("2026-10-04")

    assert %{
             "cash" => [
               %{
                 "opening_held_cents" => 1_500,
                 "movements" => %{"received_cents" => 250},
                 "closing_held_cents" => 1_750
               }
             ],
             "late_adjustments" => %{"cash" => []}
           } = daily_report("2026-10-05")

    assert %{"results" => results} =
             submit(build_conn(), [
               close_operation("close-5", "2026-10-05"),
               payment("pay-after-second-close", 100, "2026-09-01"),
               close_operation("close-10", "2026-10-10")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert daily_report("2026-10-03") == closed_report

    assert %{
             "status" => "closed",
             "late_adjustments" => %{
               "cash" => [%{"movements" => %{"received_cents" => 100}}]
             }
           } = daily_report("2026-10-06")

    assert %{"late_adjustments" => %{"cash" => []}} = daily_report("2026-10-11")
  end

  test "keeps signed late chargeback classifications even when held cash does not move", %{
    conn: conn
  } do
    operations = [
      start_operation(),
      open_operation(),
      payment("pay", 1_000, "2026-10-03"),
      operation("cancel", "cancel_group", %{"group_id" => "group-1"}),
      close_operation("close", "2026-10-03"),
      operation("chargeback", "charge_back_payment", %{"payment_operation_id" => "pay"})
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "cash" => [
               %{
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
           } = daily_report("2026-10-04")
  end

  test "classifies late credit issuance and its immediate synthetic expiry", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(),
      payment("pay", 1_000, "2026-10-03"),
      close_operation("close", "2027-10-04"),
      operation("issue-late", "cancel_group", %{
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      })
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "status" => "open",
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => %{"issued_cents" => 0, "expired_cents" => 0},
               "closing_liability_cents" => 0
             },
             "late_adjustments" => %{
               "cash" => [
                 %{"movements" => %{"converted_to_credit_cents" => 1_000}}
               ],
               "credit" => %{"issued_cents" => 1_100, "expired_cents" => 1_100}
             }
           } = daily_report("2027-10-05")
  end

  test "preserves a late revocation after the closed expiry date", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(),
      payment("pay", 1_000, "2026-10-03"),
      operation("issue", "cancel_group", %{
        "group_id" => "group-1",
        "refund_method" => "hotel_credit"
      }),
      close_operation("close", "2027-10-04"),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "pay",
        "occurred_on" => "2027-10-03"
      })
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "credit" => %{
               "opening_liability_cents" => 0,
               "closing_liability_cents" => 0
             },
             "late_adjustments" => %{
               "credit" => %{
                 "expired_cents" => -1_100,
                 "revoked_cents" => 1_100
               }
             }
           } = daily_report("2027-10-05")
  end

  test "stores and reads the first open day after the maximum cutoff", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(),
      close_operation("close", "9999-12-31"),
      payment("pay-late", 100, "2026-10-03")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "status" => "closed",
             "cash" => [],
             "late_adjustments" => %{"cash" => []}
           } = daily_report("2026-10-03")

    assert %{
             "date" => "10000-01-01",
             "status" => "open",
             "late_adjustments" => %{
               "cash" => [%{"movements" => %{"received_cents" => 100}}]
             }
           } = daily_report("10000-01-01")
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations}) |> json_response(200)
  end

  defp daily_report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp rejected(operation_id, code) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
  end

  defp start_operation do
    %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-03"
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_operation do
    operation("open", "open_group", %{
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    })
  end

  defp payment(operation_id, amount_cents, occurred_on) do
    operation(operation_id, "record_cash_payment", %{
      "group_id" => "group-1",
      "amount_cents" => amount_cents,
      "occurred_on" => occurred_on
    })
  end

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => "2026-10-03"
      },
      fields
    )
  end
end
