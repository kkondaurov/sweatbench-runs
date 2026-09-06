defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts reporting durably and validates report dates" do
    assert report_response(nil, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert report_response("not-a-date", 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert report_response("2026-10-01", 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    invalid = %{
      "operation_id" => "invalid-reporting-start",
      "type" => "start_finance_reporting",
      "starts_on" => "tomorrow"
    }

    assert [%{"code" => "invalid_reporting_date", "status" => "rejected"}] = submit([invalid])

    start = start_reporting("reporting-start", "2026-10-02")

    assert [result] = submit([start])

    assert result == %{
             "operation_id" => "reporting-start",
             "status" => "applied",
             "starts_on" => "2026-10-02"
           }

    assert submit([start]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit([Map.put(start, "starts_on", "2026-10-03")])

    assert [%{"code" => "reporting_already_started"}] =
             submit([start_reporting("another-start", "2026-10-02")])

    assert report_response("2026-10-01", 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert report("2026-10-02") == %{
             "date" => "2026-10-02",
             "status" => "open",
             "cash" => [],
             "credit" => empty_credit()
           }
  end

  test "captures the exact inception position and clamps later operations to the start date" do
    opening_payment = payment("opening-payment", "opening-group", 1_000, "2026-12-01")
    first_movement = payment("first-movement", "opening-group", 500, "2026-09-01")

    assert [_, _, %{"status" => "applied"}, %{"status" => "applied"}] =
             submit([
               open_group("opening-group", "ams-canal"),
               opening_payment,
               start_reporting("start-with-position", "2026-10-01"),
               first_movement
             ])

    assert report("2026-10-01") == %{
             "date" => "2026-10-01",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(%{"received_cents" => 500}),
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => empty_credit()
           }

    assert report("2026-10-02")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_500,
               "movements" => cash_movements(),
               "closing_held_cents" => 1_500
             }
           ]
  end

  test "captures existing credit as opening liability and schedules its future expiry" do
    submit([
      open_group("opening-credit-origin", "ams-canal", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      }),
      payment("opening-credit-principal", "opening-credit-origin", 1_000, "2026-09-30"),
      cancellation(
        "opening-credit-lot",
        "opening-credit-origin",
        "2026-10-01",
        "hotel_credit"
      ),
      start_reporting("start-after-credit", "2026-10-02")
    ])

    assert report("2026-10-02")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(),
             "closing_liability_cents" => 1_100
           }

    assert report("2027-10-02")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(%{"expired_cents" => 1_100}),
             "closing_liability_cents" => 0
           }
  end

  test "reports cash receipt, transfer, settlement, reduction, and chargeback by affected property" do
    submit([start_reporting("cash-report-start", "2026-10-01")])

    submit([
      open_group("cash-source", "ams-canal"),
      payment("traveling-cash", "cash-source", 6_000, "2026-10-02"),
      open_group("cash-destination", "rotterdam", %{"rate_plan" => "advance_purchase"}),
      transfer("cash-transfer", "cash-source", "cash-destination", 2_000, "2026-10-03"),
      cancellation("retain-transferred", "cash-destination", "2026-10-04"),
      reduce("reduce-held", "traveling-cash", 1_000, "2026-10-05"),
      cancellation("refund-source", "cash-source", "2026-10-06"),
      chargeback("chargeback-cash", "traveling-cash", "2026-10-07")
    ])

    assert cash_entry("2026-10-02", "ams-canal") == %{
             "property_id" => "ams-canal",
             "opening_held_cents" => 0,
             "movements" => cash_movements(%{"received_cents" => 6_000}),
             "closing_held_cents" => 6_000
           }

    assert cash_entry("2026-10-03", "ams-canal")["movements"] ==
             cash_movements(%{"transferred_out_cents" => 2_000})

    assert cash_entry("2026-10-03", "rotterdam") == %{
             "property_id" => "rotterdam",
             "opening_held_cents" => 0,
             "movements" => cash_movements(%{"transferred_in_cents" => 2_000}),
             "closing_held_cents" => 2_000
           }

    assert cash_entry("2026-10-04", "rotterdam")["movements"] ==
             cash_movements(%{"retained_cents" => 2_000})

    assert cash_entry("2026-10-05", "ams-canal")["movements"] ==
             cash_movements(%{"reduced_cents" => 1_000})

    assert cash_entry("2026-10-06", "ams-canal")["movements"] ==
             cash_movements(%{"refunded_cents" => 3_000})

    assert cash_entry("2026-10-07", "ams-canal") == %{
             "property_id" => "ams-canal",
             "opening_held_cents" => 0,
             "movements" =>
               cash_movements(%{
                 "refunded_cents" => -3_000,
                 "charged_back_cents" => 3_000
               }),
             "closing_held_cents" => 0
           }

    assert cash_entry("2026-10-07", "rotterdam")["movements"] ==
             cash_movements(%{
               "retained_cents" => -2_000,
               "charged_back_cents" => 2_000
             })
  end

  test "reports credit issuance, consumption, revocation, absorption, and read-only expiry" do
    submit([start_reporting("credit-report-start", "2026-10-01")])

    submit([
      open_group("credit-origin", "ams-canal", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      }),
      payment("credit-principal", "credit-origin", 1_000, "2026-10-01"),
      cancellation("credit-lot", "credit-origin", "2026-10-02", "hotel_credit")
    ])

    assert report("2026-10-02")["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(%{"issued_cents" => 1_100}),
             "closing_liability_cents" => 1_100
           }

    submit([
      open_group("credit-consumer", "rotterdam", %{
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02"
      }),
      apply_credit("consume-credit", "credit-consumer", 400, "2026-10-03"),
      cancellation("consume-settlement", "credit-consumer", "2026-10-04")
    ])

    assert report("2026-10-03")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(),
             "closing_liability_cents" => 1_100
           }

    assert report("2026-10-04")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(%{"consumed_cents" => 400}),
             "closing_liability_cents" => 700
           }

    submit([chargeback("revoke-credit", "credit-principal", "2026-10-05")])

    assert report("2026-10-05")["credit"] == %{
             "opening_liability_cents" => 700,
             "movements" => credit_movements(%{"revoked_cents" => 700}),
             "closing_liability_cents" => 0
           }

    issue_applied_shortfall()

    assert report("2026-10-09")["credit"]["movements"] ==
             credit_movements(%{"absorbed_cents" => 1_100})

    submit([
      open_group("expiring-origin", "ams-canal", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      }),
      payment("expiring-principal", "expiring-origin", 1_000, "2026-10-10"),
      cancellation("expiring-lot", "expiring-origin", "2026-10-10", "hotel_credit")
    ])

    first = report("2027-10-11")
    second = report("2027-10-11")

    assert first == second
    assert first["credit"]["movements"] == credit_movements(%{"expired_cents" => 1_100})
    assert first["credit"]["closing_liability_cents"] == 0

    assert get(build_conn(), "/api/v1/ledger?on=2027-10-11")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "late operations revise an open report while replays and rejections add nothing" do
    submit([
      start_reporting("late-report-start", "2026-10-01"),
      open_group("late-group", "ams-canal")
    ])

    original = payment("late-payment", "late-group", 500, "2026-10-02")
    assert [%{"status" => "applied"}] = submit([original])
    assert cash_entry("2026-10-02", "ams-canal")["closing_held_cents"] == 500

    late = payment("later-submission", "late-group", 300, "2026-10-02")
    assert [%{"status" => "applied"}] = submit([late])
    assert cash_entry("2026-10-02", "ams-canal")["closing_held_cents"] == 800

    assert [%{"status" => "applied"}] = submit([late])

    rejected = payment("rejected-payment", "missing-group", 900, "2026-10-02")
    assert [%{"status" => "rejected"}] = submit([rejected])

    assert cash_entry("2026-10-02", "ams-canal")["movements"] ==
             cash_movements(%{"received_cents" => 800})
  end

  defp issue_applied_shortfall do
    submit([
      open_group("shortfall-origin", "ams-canal", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      }),
      payment("shortfall-principal", "shortfall-origin", 1_000, "2026-10-05"),
      cancellation("shortfall-lot", "shortfall-origin", "2026-10-06", "hotel_credit"),
      open_group("shortfall-group", "utrecht", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-23"
      }),
      apply_credit("apply-shortfall", "shortfall-group", 1_100, "2026-10-07"),
      chargeback("create-shortfall", "shortfall-principal", "2026-10-08"),
      cancellation("absorb-shortfall", "shortfall-group", "2026-10-09")
    ])
  end

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date), do: report_response(date, 200)["data"]

  defp report_response(nil, status) do
    get(build_conn(), "/api/v1/finance/daily-report") |> json_response(status)
  end

  defp report_response(date, status) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}") |> json_response(status)
  end

  defp cash_entry(date, property_id) do
    report(date)["cash"] |> Enum.find(&(&1["property_id"] == property_id))
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_group(group_id, property_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group_id,
        "guest_id" => "finance-guest",
        "property_id" => property_id,
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 50_000}]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp cancellation(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp reduce(operation_id, payment_operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
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

  defp apply_credit(operation_id, group_id, amount, occurred_on) do
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

  defp empty_credit do
    %{
      "opening_liability_cents" => 0,
      "movements" => credit_movements(),
      "closing_liability_cents" => 0
    }
  end
end
