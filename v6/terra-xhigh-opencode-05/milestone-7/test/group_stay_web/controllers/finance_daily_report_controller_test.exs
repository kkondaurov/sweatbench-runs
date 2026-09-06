defmodule GroupStayWeb.FinanceDailyReportControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts reporting from an in-batch opening position and preserves the start result", %{
    conn: conn
  } do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date[]=2027-01-10")
             |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(404)

    assert %{
             "results" => [
               %{
                 "operation_id" => "invalid-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           } =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "invalid-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "not-a-date"
               }
             ])
             |> json_response(200)

    no_cash_movements = cash_movements()
    no_credit_movements = credit_report(0)

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2027-01-10"
               },
               %{"status" => "applied"}
             ]
           } =
             post_batch(conn, [
               group("open-before", "before", "ams-canal"),
               payment("paid-before", "before", 10, "2027-02-01"),
               start_reporting("start-reporting", "2027-01-10"),
               payment("paid-after", "before", 5, "2027-01-11")
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "date" => "2027-01-10",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 10,
                   "movements" => ^no_cash_movements,
                   "closing_held_cents" => 10
                 }
               ],
               "credit" => ^no_credit_movements
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(200)

    received_five = cash_movements(%{"received_cents" => 5})

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 10,
                   "movements" => ^received_five,
                   "closing_held_cents" => 15
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-11")
             |> json_response(200)

    assert %{"data" => payment_result} =
             get(build_conn(), "/api/v1/operations/paid-after") |> json_response(200)

    assert %{"results" => [^payment_result]} =
             post_batch(build_conn(), [payment("paid-after", "before", 5, "2027-01-11")])
             |> json_response(200)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "opening_held_cents" => 10,
                   "movements" => ^received_five,
                   "closing_held_cents" => 15
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-11")
             |> json_response(200)

    assert %{"data" => original_start} =
             get(build_conn(), "/api/v1/operations/start-reporting") |> json_response(200)

    assert %{"results" => [^original_start]} =
             post_batch(build_conn(), [start_reporting("start-reporting", "2027-01-10")])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "second-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           } =
             post_batch(build_conn(), [start_reporting("second-start", "2027-01-12")])
             |> json_response(200)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-09")
             |> json_response(404)
  end

  test "clamps cash posting dates and reports transfers and corrections at their holding property",
       %{
         conn: conn
       } do
    post_batch(conn, [start_reporting("start", "2027-01-10")])

    assert %{"results" => results} =
             post_batch(build_conn(), [
               group("open-source", "source", "ams-canal"),
               group("open-destination", "destination", "berlin-mitte"),
               payment("payment", "source", 20, "2027-01-01"),
               transfer("transfer", "source", "destination", 20, "2027-01-10"),
               reduction("reduction", "payment", 5, "2027-01-11"),
               chargeback("chargeback", "payment", "2027-01-12")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    source_cash = cash_movements(%{"received_cents" => 20, "transferred_out_cents" => 20})
    destination_cash = cash_movements(%{"transferred_in_cents" => 20})

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => ^source_cash,
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 0,
                   "movements" => ^destination_cash,
                   "closing_held_cents" => 20
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(200)

    reduced_cash = cash_movements(%{"reduced_cents" => 5})

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 20,
                   "movements" => ^reduced_cash,
                   "closing_held_cents" => 15
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-11")
             |> json_response(200)

    charged_back_cash = cash_movements(%{"charged_back_cents" => 15})

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 15,
                   "movements" => ^charged_back_cash,
                   "closing_held_cents" => 0
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-12")
             |> json_response(200)
  end

  test "reports settlement reversals, credit liability movements, and passive expiry", %{
    conn: conn
  } do
    post_batch(conn, [start_reporting("start", "2027-01-10")])

    assert %{"results" => results} =
             post_batch(build_conn(), [
               group("open-source", "source", "ams-canal"),
               payment("payment", "source", 20, "2027-01-11"),
               %{
                 "operation_id" => "issue-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-12",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               },
               group("open-target", "target", "berlin-mitte", "advance_purchase", 22),
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-13",
                 "group_id" => "target",
                 "amount_cents" => 22
               },
               %{
                 "operation_id" => "consume-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-14",
                 "group_id" => "target"
               },
               group("open-refund", "refund", "london-city"),
               payment("refund-payment", "refund", 20, "2027-01-15"),
               %{
                 "operation_id" => "refund",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-16",
                 "group_id" => "refund"
               },
               chargeback("refund-chargeback", "refund-payment", "2027-01-17")
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    converted_cash = cash_movements(%{"converted_to_credit_cents" => 20})
    issued_credit = credit_report(0, %{"issued_cents" => 22}, 22)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => ^converted_cash
                 }
               ],
               "credit" => ^issued_credit
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-12")
             |> json_response(200)

    consumed_credit = credit_report(22, %{"consumed_cents" => 22}, 0)

    assert %{
             "data" => %{
               "credit" => ^consumed_credit
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-14")
             |> json_response(200)

    reversed_refund_cash = cash_movements(%{"refunded_cents" => -20, "charged_back_cents" => 20})

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "london-city",
                   "opening_held_cents" => 0,
                   "movements" => ^reversed_refund_cash,
                   "closing_held_cents" => 0
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-17")
             |> json_response(200)

    # The only issued lot was consumed, so it contributes no expiry on its scheduled date.
    no_credit_liability = credit_report(0)

    assert %{"data" => %{"credit" => ^no_credit_liability}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2028-01-13")
             |> json_response(200)
  end

  test "expires unused credit without mutating a report on read", %{conn: conn} do
    post_batch(conn, [start_reporting("start", "2027-01-10")])

    assert %{"results" => results} =
             post_batch(build_conn(), [
               group("open-source", "source", "ams-canal"),
               payment("payment", "source", 20, "2027-01-11"),
               %{
                 "operation_id" => "issue-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-12",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    report_path = "/api/v1/finance/daily-report?date=2028-01-13"

    assert %{"data" => report} = get(build_conn(), report_path) |> json_response(200)

    assert report["credit"] == credit_report(22, %{"expired_cents" => 22}, 0)

    assert %{"data" => ^report} = get(build_conn(), report_path) |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(build_conn(), [chargeback("expired-chargeback", "payment", "2028-01-14")])
             |> json_response(200)

    assert %{"data" => ^report} = get(build_conn(), report_path) |> json_response(200)

    no_credit_liability = credit_report(0)

    assert %{"data" => %{"credit" => ^no_credit_liability}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2028-01-14")
             |> json_response(200)
  end

  test "backdated credit issuance expires on its reporting posting date", %{conn: conn} do
    post_batch(conn, [start_reporting("start", "2027-01-10")])

    assert %{"results" => results} =
             post_batch(build_conn(), [
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

    issued_and_expired = credit_report(0, %{"issued_cents" => 22, "expired_cents" => 22}, 0)

    assert %{"data" => %{"credit" => ^issued_and_expired}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(200)
  end

  test "expired credit cannot cover a later clawback and is absorbed on restoration", %{
    conn: conn
  } do
    post_batch(conn, [start_reporting("start", "2027-01-10")])

    target =
      group("open-target", "target", "berlin-mitte", "flexible", 55)
      |> Map.put("arrival_on", "2028-12-01")
      |> Map.put("departure_on", "2028-12-02")

    assert %{"results" => results} =
             post_batch(build_conn(), [
               group("open-source", "source", "ams-canal"),
               payment("payment-one", "source", 10, "2027-01-11"),
               payment("payment-two", "source", 10, "2027-01-11"),
               %{
                 "operation_id" => "issue-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-12",
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               },
               target,
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-13",
                 "group_id" => "target",
                 "amount_cents" => 11
               },
               chargeback("expired-chargeback", "payment-one", "2028-01-14"),
               %{
                 "operation_id" => "restore-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2028-01-15",
                 "group_id" => "target"
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    absorbed_credit = credit_report(11, %{"absorbed_cents" => 11}, 0)

    assert %{"data" => %{"credit" => ^absorbed_credit}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2028-01-15")
             |> json_response(200)
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

  defp group(
         operation_id,
         group_id,
         property_id,
         rate_plan \\ "flexible",
         nightly_rate_cents \\ 100
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate_cents}]
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

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduction(operation_id, payment_operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "occurred_on" => occurred_on
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

  defp credit_report(opening_liability_cents, overrides \\ %{}, closing_liability_cents \\ nil) do
    movements =
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

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => movements,
      "closing_liability_cents" =>
        closing_liability_cents ||
          opening_liability_cents + movements["issued_cents"] - movements["expired_cents"] -
            movements["consumed_cents"] - movements["revoked_cents"] - movements["absorbed_cents"]
    }
  end
end
