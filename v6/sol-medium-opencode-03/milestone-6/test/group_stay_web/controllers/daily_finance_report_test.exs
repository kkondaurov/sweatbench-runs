defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp open(id, property, arrival \\ "2027-06-01") do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => id,
      "guest_id" => "guest-1",
      "property_id" => property,
      "arrival_on" => arrival,
      "departure_on" => Date.add(Date.from_iso8601!(arrival), 1) |> Date.to_iso8601(),
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-#{id}", "nightly_rate_cents" => 10_000}]
    }
  end

  defp op(type, id, date, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => date}, attrs)
  end

  defp start(id \\ "start", date \\ "2027-01-05") do
    %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => date}
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date, status \\ 200) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(status)
  end

  test "captures the exact inception point and clamps later postings to starts_on", %{conn: conn} do
    start_operation = start()

    [_, _, started, _, replay, already_started] =
      submit(conn, [
        open("group", "zurich"),
        op("record_cash_payment", "opening-pay", "2027-01-02", %{
          "group_id" => "group",
          "amount_cents" => 1_000
        }),
        start_operation,
        op("record_cash_payment", "later-pay", "2027-01-03", %{
          "group_id" => "group",
          "amount_cents" => 500
        }),
        start_operation,
        start("other-start", "2027-01-06")
      ])

    assert started == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-05"
           }

    assert replay == started
    assert already_started["code"] == "reporting_already_started"

    assert report("2027-01-05") == %{
             "data" => %{
               "date" => "2027-01-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "zurich",
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
           }
  end

  test "reports transfers, settlements, reductions, and chargeback reclassification by property",
       %{
         conn: conn
       } do
    submit(conn, [
      start("start", "2027-01-01"),
      open("source", "alpha"),
      open("destination", "beta"),
      op("record_cash_payment", "pay", "2027-01-02", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      op("transfer_deposit", "transfer", "2027-01-02", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 400
      }),
      op("cancel_group", "cancel", "2027-01-02", %{"group_id" => "destination"}),
      op("reduce_cash_payment", "reduce", "2027-01-02", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 200
      }),
      op("charge_back_payment", "chargeback", "2027-01-02", %{
        "payment_operation_id" => "pay"
      })
    ])

    data = report("2027-01-02")["data"]
    alpha = Enum.find(data["cash"], &(&1["property_id"] == "alpha"))
    beta = Enum.find(data["cash"], &(&1["property_id"] == "beta"))

    assert alpha["movements"] == %{
             "received_cents" => 1_000,
             "transferred_in_cents" => 0,
             "transferred_out_cents" => 400,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 200,
             "charged_back_cents" => 400
           }

    assert alpha["closing_held_cents"] == 0

    assert beta["movements"]["transferred_in_cents"] == 400
    assert beta["movements"]["refunded_cents"] == 0
    assert beta["movements"]["charged_back_cents"] == 400
    assert beta["closing_held_cents"] == 0
  end

  test "reports unused credit expiry on the day after the lot expires", %{conn: conn} do
    submit(conn, [
      start("start", "2027-01-01"),
      open("credit-source", "alpha"),
      op("record_cash_payment", "pay", "2027-01-02", %{
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      }),
      op("cancel_group", "issue", "2027-01-02", %{
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      })
    ])

    assert report("2028-01-04")["data"]["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 1_100,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end

  test "validates report and start dates and availability", %{conn: conn} do
    assert report("bad", 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert build_conn()
           |> get("/api/v1/finance/daily-report")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert report("2027-01-01", 404) == %{"error" => %{"code" => "report_not_available"}}

    [invalid] =
      submit(conn, [%{"operation_id" => "bad-start", "type" => "start_finance_reporting"}])

    assert invalid["code"] == "invalid_reporting_date"

    submit(conn, [start()])
    assert report("2027-01-04", 404) == %{"error" => %{"code" => "report_not_available"}}
  end
end
