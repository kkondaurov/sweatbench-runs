defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "validates reporting dates and makes reports available only after inception", %{conn: conn} do
    assert daily_report(conn, nil, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert daily_report(conn, "not-a-date", 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert daily_report(conn, "2026-10-03", 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert post_batch(conn, [start_reporting("bad-start", "not-a-date")]) == %{
             "results" => [
               %{
                 "operation_id" => "bad-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }

    assert post_batch(conn, [
             %{"operation_id" => "missing-start-date", "type" => "start_finance_reporting"}
           ]) ==
             %{
               "results" => [
                 %{
                   "operation_id" => "missing-start-date",
                   "status" => "rejected",
                   "code" => "invalid_reporting_date"
                 }
               ]
             }

    start = start_reporting("start-reporting", "2026-10-03")

    assert post_batch(conn, [start]) == %{
             "results" => [
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2026-10-03"
               }
             ]
           }

    assert daily_report(conn, "2026-10-02", 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert post_batch(conn, [start]) == %{
             "results" => [
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2026-10-03"
               }
             ]
           }

    assert post_batch(conn, [start_reporting("other-start", "2026-10-04")]) == %{
             "results" => [
               %{
                 "operation_id" => "other-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    assert post_batch(conn, [Map.put(start, "starts_on", "2026-10-04")]) == %{
             "results" => [
               %{
                 "operation_id" => "start-reporting",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }
  end

  test "uses the pre-start financial state as opening and posts later movements no earlier than inception",
       %{conn: conn} do
    response =
      post_batch(conn, [
        open_group("open-before-start", "group-1", "ams-canal"),
        cash_payment("payment-before-start", "group-1", 1_000, 1, "2026-10-10"),
        start_reporting("start-reporting", "2026-10-05"),
        cash_payment("backdated-payment", "group-1", 500, 2, "2026-10-03")
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-10-05"
           }

    report = daily_report(conn, "2026-10-05") |> Map.fetch!("data")

    assert report == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(received_cents: 500),
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             }
           }

    assert daily_report(conn, "2026-10-05") |> Map.fetch!("data") == report

    assert post_batch(conn, [
             cash_payment("backdated-payment", "group-1", 500, 2, "2026-10-03")
           ]) == %{"results" => [Enum.at(response["results"], 3)]}

    assert daily_report(conn, "2026-10-05") |> Map.fetch!("data") == report
  end

  test "reports transfers, reductions, and chargebacks at the property holding or settling cash",
       %{
         conn: conn
       } do
    post_batch(conn, [
      start_reporting("start-reporting", "2026-10-01"),
      open_group("open-source", "source", "ams-canal"),
      cash_payment("source-payment", "source", 1_000, 1, "2026-10-02"),
      open_group("open-destination", "destination", "ber-mitte"),
      transfer("transfer", "source", "destination", 500, 2, 1, "2026-10-03"),
      reduction("reduce", "source-payment", 200, 3, "2026-10-04"),
      chargeback("chargeback", "source-payment", 4, "2026-10-05")
    ])

    assert daily_report(conn, "2026-10-03") |> Map.fetch!("data") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(transferred_out_cents: 500),
                 "closing_held_cents" => 500
               },
               %{
                 "property_id" => "ber-mitte",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(transferred_in_cents: 500),
                 "closing_held_cents" => 500
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             }
           }

    assert daily_report(conn, "2026-10-05") |> Map.fetch!("data") == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 500,
                 "movements" => cash_movements(charged_back_cents: 500),
                 "closing_held_cents" => 0
               },
               %{
                 "property_id" => "ber-mitte",
                 "opening_held_cents" => 300,
                 "movements" => cash_movements(charged_back_cents: 300),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             }
           }
  end

  test "reports issued credit, ignores application and ordinary restoration, and expires unused credit",
       %{conn: conn} do
    post_batch(conn, [
      start_reporting("start-reporting", "2026-10-01"),
      open_group("open-source", "source", "ams-canal"),
      cash_payment("source-payment", "source", 1_000, 1, "2026-10-02"),
      cancel("source-cancel", "source", 2, "2026-10-03", "hotel_credit"),
      open_group("open-target", "target", "ams-canal"),
      credit_payment("apply-credit", "target", 1_000, 1, "2026-10-04"),
      cancel("target-cancel", "target", 2, "2026-10-05", "cash")
    ])

    assert daily_report(conn, "2026-10-03") |> Map.fetch!("data") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(converted_to_credit_cents: 1_000),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(issued_cents: 1_100),
               "closing_liability_cents" => 1_100
             }
           }

    assert daily_report(conn, "2026-10-05") |> Map.fetch!("data") == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [],
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => credit_movements(),
               "closing_liability_cents" => 1_100
             }
           }

    assert daily_report(conn, "2027-10-04") |> Map.fetch!("data") == %{
             "date" => "2027-10-04",
             "status" => "open",
             "cash" => [],
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => credit_movements(expired_cents: 1_100),
               "closing_liability_cents" => 0
             }
           }
  end

  test "reclassifies settled cash as a negative settlement and a chargeback", %{conn: conn} do
    post_batch(conn, [
      start_reporting("start-reporting", "2026-10-01"),
      open_group("open-group", "group-1", "ams-canal"),
      cash_payment("payment", "group-1", 1_000, 1, "2026-10-02"),
      cancel("cancel", "group-1", 2, "2026-10-03", "cash"),
      chargeback("chargeback", "payment", 3, "2026-10-04")
    ])

    assert daily_report(conn, "2026-10-04") |> Map.fetch!("data") == %{
             "date" => "2026-10-04",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(refunded_cents: -1_000, charged_back_cents: 1_000),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             }
           }
  end

  test "reports credit consumed by a non-refundable settlement", %{conn: conn} do
    post_batch(conn, [
      start_reporting("start-reporting", "2026-10-01"),
      open_group("open-source", "source", "ams-canal"),
      cash_payment("source-payment", "source", 1_000, 1, "2026-10-02"),
      cancel("source-cancel", "source", 2, "2026-10-03", "hotel_credit"),
      Map.put(open_group("open-target", "target", "ams-canal"), "rate_plan", "advance_purchase"),
      credit_payment("apply-credit", "target", 1_000, 1, "2026-10-04"),
      cancel("target-cancel", "target", 2, "2026-10-05", "cash")
    ])

    assert daily_report(conn, "2026-10-05") |> Map.fetch!("data") == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [],
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => credit_movements(consumed_cents: 1_000),
               "closing_liability_cents" => 100
             }
           }
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_group(operation_id, group_id, property_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => group_id <> "-room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision,
      "occurred_on" => occurred_on
    }
  end

  defp credit_payment(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision,
      "occurred_on" => occurred_on
    }
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         source_revision,
         destination_revision,
         occurred_on
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision,
      "occurred_on" => occurred_on
    }
  end

  defp reduction(operation_id, payment_operation_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision,
      "occurred_on" => occurred_on
    }
  end

  defp chargeback(operation_id, payment_operation_id, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision,
      "occurred_on" => occurred_on
    }
  end

  defp cancel(operation_id, group_id, expected_revision, occurred_on, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "occurred_on" => occurred_on,
      "refund_method" => refund_method
    }
  end

  defp daily_report(conn, date, status \\ 200)

  defp daily_report(conn, nil, status),
    do: get(conn, "/api/v1/finance/daily-report") |> json_response(status)

  defp daily_report(conn, date, status),
    do: get(conn, "/api/v1/finance/daily-report?date=#{date}") |> json_response(status)

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
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
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp credit_movements, do: credit_movements([])

  defp credit_movements(overrides) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end
end
