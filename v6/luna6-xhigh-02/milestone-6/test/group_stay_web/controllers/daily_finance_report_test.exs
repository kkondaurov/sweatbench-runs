defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_group(operation_id, group_id, property_id, arrival_on \\ "2027-06-01", rate \\ 10_000) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "report-guest",
      "property_id" => property_id,
      "arrival_on" => arrival_on,
      "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 1) |> Date.to_iso8601(),
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => rate}]
    }
  end

  defp cash_payment(operation_id, group_id, amount, date \\ "2027-01-02") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => date,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp start_reporting(operation_id, date) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => date
    }
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "captures the processed position and posts later operations no earlier than starts_on", %{
    conn: conn
  } do
    opening = open_group("open-opening", "opening", "z-property")
    before_start_payment = cash_payment("opening-payment", "opening", 1_000, "2027-02-01")
    after_start_payment = cash_payment("later-payment", "opening", 500, "2027-01-05")

    operations = [
      opening,
      before_start_payment,
      start_reporting("start-reporting", "2027-01-10"),
      after_start_payment,
      cash_payment("rejected-payment", "opening", 0)
    ]

    results = submit(conn, operations)

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "applied",
             "applied",
             "applied",
             "rejected"
           ]

    assert Enum.at(results, 4)["code"] == "invalid_amount"

    assert Enum.at(results, 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2027-01-10"
           }

    start_result = Enum.at(results, 2)
    assert [^start_result] = submit(conn, [Enum.at(operations, 2)])

    assert report(conn, "2027-01-10") == %{
             "date" => "2027-01-10",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "z-property",
                 "opening_held_cents" => 1_000,
                 "movements" => %{
                   "received_cents" => 500,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 1_500
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

    assert report(conn, "2027-01-11")["cash"] == [
             %{
               "property_id" => "z-property",
               "opening_held_cents" => 1_500,
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
               "closing_held_cents" => 1_500
             }
           ]
  end

  test "reports transfer, refund reversal, and chargeback at the properties affected", %{
    conn: conn
  } do
    source = open_group("open-source", "source", "ams")
    destination = open_group("open-destination", "destination", "lhr")

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             submit(conn, [source, destination, start_reporting("report-start", "2027-01-01")])

    assert [%{"status" => "applied"}] = submit(conn, [cash_payment("payment", "source", 1_000)])

    transfer = %{
      "operation_id" => "transfer",
      "type" => "transfer_deposit",
      "source_group_id" => "source",
      "destination_group_id" => "destination",
      "occurred_on" => "2027-01-03",
      "amount_cents" => 600
    }

    cancel_destination = %{
      "operation_id" => "cancel-destination",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-04",
      "group_id" => "destination"
    }

    assert [%{"status" => "applied"}] = submit(conn, [transfer])

    assert [%{"status" => "applied", "refunded_cents" => 600}] =
             submit(conn, [cancel_destination])

    assert [%{"status" => "applied", "charged_back_cents" => 1_000}] =
             submit(conn, [
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "payment",
                 "occurred_on" => "2027-01-05"
               }
             ])

    destination_day =
      report(conn, "2027-01-05")["cash"] |> Enum.find(&(&1["property_id"] == "lhr"))

    source_day = report(conn, "2027-01-05")["cash"] |> Enum.find(&(&1["property_id"] == "ams"))

    assert destination_day["opening_held_cents"] == 0
    assert destination_day["movements"]["refunded_cents"] == -600
    assert destination_day["movements"]["charged_back_cents"] == 600
    assert destination_day["closing_held_cents"] == 0

    assert source_day["opening_held_cents"] == 400
    assert source_day["movements"]["charged_back_cents"] == 400
    assert source_day["closing_held_cents"] == 0

    transfer_day = report(conn, "2027-01-03")["cash"]
    assert Enum.map(transfer_day, & &1["property_id"]) == ["ams", "lhr"]
    assert Enum.reduce(transfer_day, 0, &(&1["movements"]["transferred_in_cents"] + &2)) == 600
    assert Enum.reduce(transfer_day, 0, &(&1["movements"]["transferred_out_cents"] + &2)) == 600
  end

  test "tracks credit issue, paused application, consumption, and automatic expiry", %{conn: conn} do
    source = open_group("open-credit-source", "credit-source", "ams")
    target = open_group("open-credit-target", "credit-target", "lhr", "2027-01-20", 5_000)

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             submit(conn, [
               start_reporting("credit-report-start", "2027-01-01"),
               source,
               target
             ])

    assert [%{"status" => "applied"}] =
             submit(conn, [cash_payment("credit-payment", "credit-source", 1_000)])

    assert [%{"status" => "applied", "credit_issued_cents" => 1_100}] =
             submit(conn, [
               %{
                 "operation_id" => "issue-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert [%{"status" => "applied"}] =
             submit(conn, [
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-04",
                 "group_id" => "credit-target",
                 "amount_cents" => 100
               }
             ])

    assert report(conn, "2027-01-04")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 1_100
           }

    assert [%{"status" => "applied"}] =
             submit(conn, [
               %{
                 "operation_id" => "consume-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-07",
                 "group_id" => "credit-target"
               }
             ])

    assert report(conn, "2027-01-07")["credit"]["movements"]["consumed_cents"] == 100

    assert report(conn, "2028-01-04")["credit"] == %{
             "opening_liability_cents" => 1_000,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 1_000,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }

    assert report(conn, "2028-01-04")["credit"]["movements"]["expired_cents"] == 1_000
  end

  test "reports a cash reduction at the property holding the transferred payment", %{conn: conn} do
    source = open_group("reduce-source-open", "reduce-source", "ams")
    destination = open_group("reduce-destination-open", "reduce-destination", "lhr")

    assert Enum.all?(
             submit(conn, [source, destination, start_reporting("reduce-start", "2027-01-01")]),
             &(&1["status"] == "applied")
           )

    assert [%{"status" => "applied"}] =
             submit(conn, [cash_payment("reduce-payment", "reduce-source", 1_000)])

    assert [%{"status" => "applied"}] =
             submit(conn, [
               %{
                 "operation_id" => "reduce-transfer",
                 "type" => "transfer_deposit",
                 "source_group_id" => "reduce-source",
                 "destination_group_id" => "reduce-destination",
                 "occurred_on" => "2027-01-03",
                 "amount_cents" => 600
               }
             ])

    assert [%{"status" => "applied", "amount_cents" => 300}] =
             submit(conn, [
               %{
                 "operation_id" => "reduce-operation",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "reduce-payment",
                 "occurred_on" => "2027-01-04",
                 "amount_cents" => 300
               }
             ])

    [source_report, destination_report] = report(conn, "2027-01-04")["cash"]
    assert source_report["property_id"] == "ams"
    assert source_report["opening_held_cents"] == 400
    assert source_report["closing_held_cents"] == 400
    assert destination_report["property_id"] == "lhr"
    assert destination_report["opening_held_cents"] == 600
    assert destination_report["movements"]["reduced_cents"] == 300
    assert destination_report["closing_held_cents"] == 300
  end

  test "uses all committed credit state when reporting starts", %{conn: conn} do
    source = open_group("snapshot-source-open", "snapshot-source", "ams")
    target = open_group("snapshot-target-open", "snapshot-target", "lhr")

    operations = [
      source,
      cash_payment("snapshot-payment", "snapshot-source", 1_000),
      %{
        "operation_id" => "snapshot-issue",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-03",
        "group_id" => "snapshot-source",
        "refund_method" => "hotel_credit"
      },
      target,
      %{
        "operation_id" => "snapshot-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-04",
        "group_id" => "snapshot-target",
        "amount_cents" => 100
      },
      start_reporting("snapshot-start", "2027-01-01")
    ]

    assert Enum.all?(submit(conn, operations), &(&1["status"] == "applied"))

    assert report(conn, "2027-01-01") == %{
             "date" => "2027-01-01",
             "status" => "open",
             "cash" => [],
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 1_100
             }
           }
  end

  test "reports credit revocation and shortfall absorption", %{conn: conn} do
    source = open_group("clawback-source-open", "clawback-source", "ams")
    target = open_group("clawback-target-open", "clawback-target", "lhr")

    assert Enum.all?(
             submit(conn, [source, target, start_reporting("clawback-start", "2027-01-01")]),
             &(&1["status"] == "applied")
           )

    assert [%{"status" => "applied"}] =
             submit(conn, [cash_payment("clawback-payment", "clawback-source", 1_000)])

    assert [%{"status" => "applied"}] =
             submit(conn, [
               %{
                 "operation_id" => "clawback-issue",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "clawback-source",
                 "refund_method" => "hotel_credit"
               }
             ])

    assert [%{"status" => "applied"}] =
             submit(conn, [
               %{
                 "operation_id" => "clawback-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-04",
                 "group_id" => "clawback-target",
                 "amount_cents" => 500
               }
             ])

    assert [%{"status" => "applied", "charged_back_cents" => 1_000}] =
             submit(conn, [
               %{
                 "operation_id" => "clawback-cash",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "clawback-payment",
                 "occurred_on" => "2027-01-05"
               }
             ])

    assert report(conn, "2027-01-05")["credit"]["movements"]["revoked_cents"] == 600

    assert [%{"status" => "applied"}] =
             submit(conn, [
               %{
                 "operation_id" => "clawback-cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-06",
                 "group_id" => "clawback-target"
               }
             ])

    assert report(conn, "2027-01-06")["credit"] == %{
             "opening_liability_cents" => 500,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 500
             },
             "closing_liability_cents" => 0
           }
  end

  test "validates report dates, availability, and one-time start", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             conn |> get("/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             conn
             |> get("/api/v1/finance/daily-report?date=not-a-date")
             |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             conn
             |> get("/api/v1/finance/daily-report?date=2027-01-01")
             |> json_response(404)

    assert [%{"code" => "invalid_reporting_date", "status" => "rejected"}] =
             submit(conn, [start_reporting("invalid-start", "bad-date")])

    assert [%{"status" => "applied"}] =
             submit(conn, [start_reporting("valid-start", "2027-01-10")])

    assert [%{"code" => "reporting_already_started", "status" => "rejected"}] =
             submit(conn, [start_reporting("second-start", "2027-01-11")])

    assert %{"error" => %{"code" => "report_not_available"}} =
             conn
             |> get("/api/v1/finance/daily-report?date=2027-01-09")
             |> json_response(404)
  end
end
