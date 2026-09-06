defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(operation_id, group_id, property_id \\ "ams-canal") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
      "arrival_on" => "2027-03-10",
      "departure_on" => "2027-03-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment(operation_id, group_id, amount, occurred_on \\ "2026-12-01") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp start(operation_id \\ "start", starts_on \\ "2026-12-01") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp report(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates reporting inception and report dates", %{conn: conn} do
    assert conn
           |> get(~p"/api/v1/finance/daily-report")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert conn
           |> get(~p"/api/v1/finance/daily-report?date=not-a-date")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert conn
           |> get(~p"/api/v1/finance/daily-report?date=2026-12-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert post_operations(conn, [Map.delete(start(), "starts_on")]) == [
             %{
               "operation_id" => "start",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }
           ]

    assert post_operations(conn, [start("start-valid")]) == [
             %{
               "operation_id" => "start-valid",
               "status" => "applied",
               "starts_on" => "2026-12-01"
             }
           ]

    assert post_operations(conn, [start("start-other", "2026-12-02")]) == [
             %{
               "operation_id" => "start-other",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
           ]

    assert conn
           |> get(~p"/api/v1/finance/daily-report?date=2026-11-30")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "captures same-batch opening positions and reports later movements by property", %{
    conn: conn
  } do
    operations = [
      open("open-ams", "ams", "ams-canal"),
      open("open-ber", "ber", "ber-mitte"),
      payment("pay-opening", "ams", 1_000, "2027-01-10"),
      start(),
      payment("pay-ams", "ams", 500, "2026-11-01"),
      payment("pay-ber", "ber", 700, "2026-12-02")
    ]

    results = post_operations(conn, operations)

    assert Enum.at(results, 3) == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-12-01"
           }

    day_one = report(conn, "2026-12-01")

    assert day_one == %{
             "date" => "2026-12-01",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(%{"received_cents" => 500}),
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             },
             "late_adjustments" => %{
               "cash" => [],
               "credit" => credit_movements()
             }
           }

    day_two = report(conn, "2026-12-02")
    assert Enum.map(day_two["cash"], & &1["property_id"]) == ["ams-canal", "ber-mitte"]
    assert Enum.at(day_two["cash"], 1)["movements"]["received_cents"] == 700
    assert report(conn, "2026-12-01") == day_one
  end

  test "reports conversion, credit issuance, and automatic expiry without a write", %{conn: conn} do
    post_operations(conn, [
      open("open", "group"),
      payment("pay", "group", 1_000),
      start(),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group",
        "refund_method" => "hotel_credit"
      }
    ])

    inception = report(conn, "2026-12-01")
    [cash] = inception["cash"]
    assert cash["opening_held_cents"] == 1_000
    assert cash["movements"]["converted_to_credit_cents"] == 1_000
    assert cash["closing_held_cents"] == 0
    assert inception["credit"]["movements"]["issued_cents"] == 1_100
    assert inception["credit"]["closing_liability_cents"] == 1_100

    expiry = report(conn, "2027-12-02")

    assert expiry["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(%{"expired_cents" => 1_100}),
             "closing_liability_cents" => 0
           }
  end

  test "classifies transfers, reductions, refunds, and chargebacks at the affected property", %{
    conn: conn
  } do
    post_operations(conn, [
      open("open-ams", "ams", "ams-canal"),
      open("open-ber", "ber", "ber-mitte"),
      start(),
      payment("pay", "ams", 2_000),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-12-01",
        "source_group_id" => "ams",
        "destination_group_id" => "ber",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-12-01",
        "payment_operation_id" => "pay",
        "amount_cents" => 300
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "ber"
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-01",
        "payment_operation_id" => "pay"
      }
    ])

    report = report(conn, "2026-12-01")
    [ams, ber] = report["cash"]

    assert ams["movements"] ==
             cash_movements(%{
               "received_cents" => 2_000,
               "transferred_out_cents" => 500,
               "charged_back_cents" => 1_500
             })

    assert ber["movements"] ==
             cash_movements(%{
               "transferred_in_cents" => 500,
               "refunded_cents" => 0,
               "reduced_cents" => 300,
               "charged_back_cents" => 200
             })

    assert ams["closing_held_cents"] == 0
    assert ber["closing_held_cents"] == 0
  end

  test "reports non-refundable consumption of applied credit", %{conn: conn} do
    post_operations(conn, [
      open("open-issuer", "issuer"),
      payment("issuer-pay", "issuer", 1_000),
      %{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "issuer",
        "refund_method" => "hotel_credit"
      },
      open("open-target", "target"),
      start(),
      %{
        "operation_id" => "apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "target",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "reschedule",
        "type" => "reschedule_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "target",
        "new_arrival_on" => "2026-12-02"
      },
      %{
        "operation_id" => "consume",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "target"
      }
    ])

    credit = report(conn, "2026-12-01")["credit"]
    assert credit["opening_liability_cents"] == 1_100
    assert credit["movements"] == credit_movements(%{"consumed_cents" => 500})
    assert credit["closing_liability_cents"] == 600
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
