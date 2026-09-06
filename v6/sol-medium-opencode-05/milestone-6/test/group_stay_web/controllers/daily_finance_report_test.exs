defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "starts reporting at the exact batch boundary and durably replays the start", %{conn: conn} do
    start = %{
      "operation_id" => "start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-10"
    }

    operations = [
      open("opening-group", "ams-canal"),
      payment("opening-payment", "opening-group", 1_000, "2027-01-01"),
      start,
      open("movement-group", "berlin-mitte"),
      payment("movement-payment", "movement-group", 500, "2026-01-01")
    ]

    assert %{"results" => [_, _, started, _, _]} =
             conn
             |> post("/api/v1/partner-batches", %{"operations" => operations})
             |> json_response(200)

    assert started == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-10-10"
           }

    assert %{"results" => [^started]} = submit([start])

    report = report("2026-10-10")

    assert report["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 1_000
             },
             %{
               "property_id" => "berlin-mitte",
               "opening_held_cents" => 0,
               "movements" => %{zero_cash_movements() | "received_cents" => 500},
               "closing_held_cents" => 500
             }
           ]

    assert report == report("2026-10-10")
  end

  test "validates reporting dates and only permits one inception", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             conn |> get("/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-10")
             |> json_response(404)

    assert %{"results" => [invalid]} =
             submit([
               %{
                 "operation_id" => "invalid-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "not-a-date"
               }
             ])

    assert invalid["code"] == "invalid_reporting_date"
    start_reporting("2026-10-10")

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-09")
             |> json_response(404)

    assert %{"results" => [again]} =
             submit([
               %{
                 "operation_id" => "another-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-11"
               }
             ])

    assert again["code"] == "reporting_already_started"
  end

  test "reports cross-property transfers, reductions, settlements, and chargeback reversals" do
    submit([
      open("source", "ams-canal"),
      open("destination", "berlin-mitte", "advance_purchase"),
      start_operation("2026-10-01"),
      payment("pay-1", "source", 2_000, "2026-10-02"),
      %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1_000,
        "occurred_on" => "2026-10-03"
      },
      %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 500,
        "occurred_on" => "2026-10-04"
      },
      %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "group_id" => "destination",
        "occurred_on" => "2026-10-05"
      },
      %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-1",
        "occurred_on" => "2026-10-06"
      }
    ])

    assert cash_entry("2026-10-03", "ams-canal")["movements"]["transferred_out_cents"] ==
             1_000

    assert cash_entry("2026-10-03", "berlin-mitte")["movements"]["transferred_in_cents"] ==
             1_000

    assert cash_entry("2026-10-04", "berlin-mitte")["movements"]["reduced_cents"] == 500
    assert cash_entry("2026-10-05", "berlin-mitte")["movements"]["retained_cents"] == 500

    berlin_chargeback = cash_entry("2026-10-06", "berlin-mitte")["movements"]
    assert berlin_chargeback["retained_cents"] == -500
    assert berlin_chargeback["charged_back_cents"] == 500

    amsterdam_chargeback = cash_entry("2026-10-06", "ams-canal")["movements"]
    assert amsterdam_chargeback["charged_back_cents"] == 1_000
  end

  test "reports credit issuance, revocation, and automatic expiry" do
    submit([
      open("seed", "ams-canal"),
      start_operation("2026-10-01"),
      payment("seed-payment", "seed", 1_000, "2026-10-02"),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2026-10-03",
        "refund_method" => "hotel_credit"
      }
    ])

    credit = report("2026-10-03")["credit"]
    assert credit["movements"]["issued_cents"] == 1_100
    assert credit["closing_liability_cents"] == 1_100

    expiry = report("2027-10-04")["credit"]
    assert expiry["movements"]["expired_cents"] == 1_100
    assert expiry["closing_liability_cents"] == 0

    submit([
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "seed-payment",
        "occurred_on" => "2026-10-04"
      }
    ])

    assert report("2026-10-04")["credit"]["movements"]["revoked_cents"] == 1_100
    assert report("2027-10-04")["credit"]["movements"]["expired_cents"] == 0
  end

  test "reports credit consumption and shortfall absorption without movements for application" do
    submit([
      open("seed", "ams-canal"),
      start_operation("2026-10-01"),
      payment("seed-payment", "seed", 1_000, "2026-10-02"),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2026-10-03",
        "refund_method" => "hotel_credit"
      },
      open("credit-group", "berlin-mitte"),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "group_id" => "credit-group",
        "amount_cents" => 1_100,
        "occurred_on" => "2026-10-04"
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "seed-payment",
        "occurred_on" => "2026-10-05"
      },
      %{
        "operation_id" => "restore-credit",
        "type" => "cancel_group",
        "group_id" => "credit-group",
        "occurred_on" => "2026-10-06"
      }
    ])

    assert report("2026-10-04")["credit"]["movements"] == zero_credit_movements()
    assert report("2026-10-05")["credit"]["movements"]["revoked_cents"] == 0
    assert report("2026-10-06")["credit"]["movements"]["absorbed_cents"] == 1_100
    assert report("2026-10-06")["credit"]["closing_liability_cents"] == 0

    submit([
      open("second-seed", "ams-canal"),
      payment("second-payment", "second-seed", 1_000, "2026-10-07"),
      %{
        "operation_id" => "second-issue",
        "type" => "cancel_group",
        "group_id" => "second-seed",
        "occurred_on" => "2026-10-08",
        "refund_method" => "hotel_credit"
      },
      open("nonrefundable", "berlin-mitte", "advance_purchase"),
      %{
        "operation_id" => "second-apply",
        "type" => "apply_hotel_credit",
        "group_id" => "nonrefundable",
        "amount_cents" => 1_100,
        "occurred_on" => "2026-10-09"
      },
      %{
        "operation_id" => "consume-credit",
        "type" => "cancel_group",
        "group_id" => "nonrefundable",
        "occurred_on" => "2026-10-10"
      }
    ])

    assert report("2026-10-10")["credit"]["movements"]["consumed_cents"] == 1_100
  end

  test "shows both transfer classifications at one property and late operations on open reports" do
    submit([
      open("source", "ams-canal"),
      open("destination", "ams-canal"),
      start_operation("2026-10-01"),
      payment("pay-1", "source", 1_000, "2026-10-02"),
      %{
        "operation_id" => "same-property-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 500,
        "occurred_on" => "2026-10-03"
      }
    ])

    movement = cash_entry("2026-10-03", "ams-canal")["movements"]
    assert movement["transferred_in_cents"] == 500
    assert movement["transferred_out_cents"] == 500

    assert report("2026-10-04")["cash"] |> hd() |> Map.fetch!("closing_held_cents") == 1_000

    submit([payment("late-payment", "source", 500, "2026-10-04")])
    assert cash_entry("2026-10-04", "ams-canal")["movements"]["received_cents"] == 500
  end

  test "posts an already expired backdated credit issue and expiry together at inception" do
    submit([
      open("seed", "ams-canal"),
      payment("seed-payment", "seed", 1_000, "2024-01-01"),
      start_operation("2026-10-01"),
      %{
        "operation_id" => "backdated-issue",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2024-01-02",
        "refund_method" => "hotel_credit"
      }
    ])

    credit = report("2026-10-01")["credit"]
    assert credit["movements"]["issued_cents"] == 1_100
    assert credit["movements"]["expired_cents"] == 1_100
    assert credit["closing_liability_cents"] == 0
  end

  test "backfills a pre-reporting transferred settlement to its destination property" do
    submit([
      open("source", "ams-canal"),
      open("destination", "berlin-mitte", "advance_purchase"),
      payment("pay-1", "source", 1_000, "2026-09-01"),
      %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "settle-destination",
        "type" => "cancel_group",
        "group_id" => "destination",
        "occurred_on" => "2026-09-02"
      }
    ])

    GroupStay.Repo.delete_all(GroupStay.CashDisposition)
    start_reporting("2026-10-01")

    submit([
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-1",
        "occurred_on" => "2026-10-02"
      }
    ])

    movement = cash_entry("2026-10-02", "berlin-mitte")["movements"]
    assert movement["retained_cents"] == -1_000
    assert movement["charged_back_cents"] == 1_000
  end

  test "backfills a transferred payment independently of another same-guest settlement" do
    submit([
      open("source", "ams-canal"),
      open("destination", "berlin-mitte", "advance_purchase"),
      open("unrelated", "copenhagen-centre", "advance_purchase"),
      payment("transferred-payment", "source", 1_000, "2026-09-01"),
      %{
        "operation_id" => "transfer-payment",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "settle-transferred",
        "type" => "cancel_group",
        "group_id" => "destination",
        "occurred_on" => "2026-09-02"
      },
      payment("unrelated-payment", "unrelated", 1_000, "2026-09-03"),
      %{
        "operation_id" => "settle-unrelated",
        "type" => "cancel_group",
        "group_id" => "unrelated",
        "occurred_on" => "2026-09-04"
      }
    ])

    GroupStay.Repo.delete_all(GroupStay.CashDisposition)
    start_reporting("2026-10-01")

    submit([
      %{
        "operation_id" => "chargeback-transferred",
        "type" => "charge_back_payment",
        "payment_operation_id" => "transferred-payment",
        "occurred_on" => "2026-10-02"
      }
    ])

    movement = cash_entry("2026-10-02", "berlin-mitte")["movements"]
    assert movement["retained_cents"] == -1_000
    assert movement["charged_back_cents"] == 1_000
    refute cash_entry("2026-10-02", "copenhagen-centre")
    refute cash_entry("2026-10-02", "ams-canal")
  end

  test "reconciles backdated application and restoration across the reporting floor" do
    submit([
      open("seed", "ams-canal"),
      payment("seed-payment", "seed", 1_000, "2024-01-01"),
      %{
        "operation_id" => "old-credit",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2024-01-02",
        "refund_method" => "hotel_credit"
      },
      open("credit-group", "berlin-mitte"),
      start_operation("2026-10-01"),
      %{
        "operation_id" => "backdated-apply",
        "type" => "apply_hotel_credit",
        "group_id" => "credit-group",
        "amount_cents" => 1_100,
        "occurred_on" => "2024-01-03"
      }
    ])

    credit = report("2026-10-01")["credit"]
    assert credit["movements"]["expired_cents"] == -1_100
    assert credit["closing_liability_cents"] == 1_100

    submit([
      %{
        "operation_id" => "backdated-restore",
        "type" => "cancel_group",
        "group_id" => "credit-group",
        "occurred_on" => "2024-01-04"
      }
    ])

    credit = report("2026-10-01")["credit"]
    assert credit["movements"]["expired_cents"] == 0
    assert credit["closing_liability_cents"] == 0
  end

  defp submit(operations) do
    post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cash_entry(date, property_id) do
    report(date)["cash"] |> Enum.find(&(&1["property_id"] == property_id))
  end

  defp start_reporting(date), do: submit([start_operation(date)])

  defp start_operation(date) do
    %{
      "operation_id" => "start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => date
    }
  end

  defp open(group_id, property_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2027-12-10",
      "departure_on" => "2027-12-11",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 20_000}]
    }
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

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end
end
