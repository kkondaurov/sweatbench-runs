defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, property_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "finance-guest",
        "property_id" => property_id,
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp pay(operation_id, group_id, amount, occurred_on \\ "2027-01-02") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp start(operation_id \\ "start-reporting", starts_on \\ "2027-01-01") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp submit(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates availability and starts reporting durably with the exact result shape" do
    assert get(build_conn(), ~p"/api/v1/finance/daily-report") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=nope") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert [%{"code" => "invalid_reporting_date"}] =
             submit([Map.delete(start("bad-start"), "starts_on")])

    operation = start()

    assert [result] = submit([operation])

    assert result == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2027-01-01"
           }

    assert submit([operation]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit([start("start-reporting", "2027-01-02")])

    assert [%{"code" => "reporting_already_started"}] =
             submit([start("another-start", "2027-01-01")])

    assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2026-12-31")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "the inception snapshot respects operation order and clamps later posting dates" do
    results =
      submit([
        open("opening", "ams-canal"),
        pay("opening-payment", "opening", 600, "2027-02-01"),
        start("ordered-start", "2027-01-10"),
        pay("first-movement", "opening", 400, "2027-01-05")
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert report("2027-01-10") == %{
             "date" => "2027-01-10",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 600,
                 "movements" => %{
                   "received_cents" => 400,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 1_000
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }
           }

    assert report("2027-01-11")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 1_000
             }
           ]
  end

  test "cash reports follow transfers, reductions, settlement, and chargeback properties" do
    submit([
      start(),
      open("source", "ams-canal"),
      open("destination", "rtm-center"),
      pay("tracked-payment", "source", 1_000),
      %{
        "operation_id" => "move-cash",
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-03",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 400
      },
      %{
        "operation_id" => "reduce-moved-cash",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2027-01-04",
        "payment_operation_id" => "tracked-payment",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "refund-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-05",
        "group_id" => "destination"
      },
      %{
        "operation_id" => "chargeback-all",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-01-06",
        "payment_operation_id" => "tracked-payment"
      }
    ])

    assert [%{"status" => "applied", "amount_cents" => 1_000}] =
             submit([pay("tracked-payment", "source", 1_000)])

    assert report("2027-01-02")["cash"] == [
             cash_entry("ams-canal", 0, %{"received_cents" => 1_000}, 1_000)
           ]

    assert report("2027-01-03")["cash"] == [
             cash_entry("ams-canal", 1_000, %{"transferred_out_cents" => 400}, 600),
             cash_entry("rtm-center", 0, %{"transferred_in_cents" => 400}, 400)
           ]

    assert report("2027-01-04")["cash"] |> List.last() ==
             cash_entry("rtm-center", 400, %{"reduced_cents" => 100}, 300)

    assert report("2027-01-05")["cash"] |> List.last() ==
             cash_entry("rtm-center", 300, %{"refunded_cents" => 300}, 0)

    assert report("2027-01-06")["cash"] == [
             cash_entry("ams-canal", 600, %{"charged_back_cents" => 600}, 0),
             cash_entry(
               "rtm-center",
               0,
               %{"refunded_cents" => -300, "charged_back_cents" => 300},
               0
             )
           ]
  end

  test "a transfer within one property reports both sides without changing held cash" do
    submit([
      start(),
      open("local-source", "ams-canal"),
      open("local-destination", "ams-canal"),
      pay("local-payment", "local-source", 500),
      %{
        "operation_id" => "local-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-03",
        "source_group_id" => "local-source",
        "destination_group_id" => "local-destination",
        "amount_cents" => 200
      }
    ])

    assert report("2027-01-03")["cash"] == [
             cash_entry(
               "ams-canal",
               500,
               %{"transferred_in_cents" => 200, "transferred_out_cents" => 200},
               500
             )
           ]
  end

  test "credit issuance, consumption, and no-operation expiry reconcile by day" do
    submit([
      start(),
      open("credit-source", "ams-canal"),
      pay("credit-principal", "credit-source", 1_000),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      },
      open("credit-target", "ams-canal", %{
        "operation_id" => "open-credit-target",
        "occurred_on" => "2027-01-03",
        "rate_plan" => "advance_purchase"
      }),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-03",
        "group_id" => "credit-target",
        "amount_cents" => 400
      },
      %{
        "operation_id" => "consume-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-04",
        "group_id" => "credit-target"
      }
    ])

    assert report("2027-01-02")["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 1_100,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 1_100
           }

    assert report("2027-01-03")["credit"]["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert report("2027-01-04")["credit"]["movements"]["consumed_cents"] == 400

    expiry = report("2028-01-03")["credit"]
    assert expiry["opening_liability_cents"] == 700
    assert expiry["movements"]["expired_cents"] == 700
    assert expiry["closing_liability_cents"] == 0
    assert report("2028-01-04")["credit"]["opening_liability_cents"] == 0
  end

  defp cash_entry(property_id, opening, overrides, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), overrides),
      "closing_held_cents" => closing
    }
  end

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end
end
