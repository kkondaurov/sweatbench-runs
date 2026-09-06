defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp open(id, operation_id, property, guest \\ "guest", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => id,
        "guest_id" => guest,
        "property_id" => property,
        "arrival_on" => "2028-01-01",
        "departure_on" => "2028-01-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 2_000}]
      },
      overrides
    )
  end

  defp operation(type, id, date, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => date}, attrs)
  end

  defp start(id \\ "start", date \\ "2026-10-03") do
    %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => date}
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "starts from the processing-order position and records later same-batch movements", %{
    conn: conn
  } do
    assert [_, _, started, paid] =
             submit(conn, [
               open("group", "open", "hotel"),
               operation("record_cash_payment", "pay-before", "2026-10-10", %{
                 "group_id" => "group",
                 "amount_cents" => 1_000
               }),
               start(),
               operation("record_cash_payment", "pay-after", "2026-10-01", %{
                 "group_id" => "group",
                 "amount_cents" => 500
               })
             ])

    assert started == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-10-03"
           }

    assert paid["status"] == "applied"
    assert submit(conn, [start()]) == [started]

    assert submit(conn, [
             operation("record_cash_payment", "pay-after", "2026-10-01", %{
               "group_id" => "group",
               "amount_cents" => 500
             })
           ]) == [paid]

    assert [already] = submit(conn, [start("other")])
    assert already["code"] == "reporting_already_started"

    daily = report(conn, "2026-10-03")
    assert daily["date"] == "2026-10-03"
    assert daily["status"] == "open"

    assert daily["cash"] == [
             %{
               "property_id" => "hotel",
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
           ]

    assert daily["credit"] == %{
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

    assert report(conn, "2026-10-04")["cash"]
           |> hd()
           |> Map.take(["opening_held_cents", "closing_held_cents"]) ==
             %{"opening_held_cents" => 1_500, "closing_held_cents" => 1_500}
  end

  test "validates report dates and reporting inception", %{conn: conn} do
    assert conn
           |> get("/api/v1/finance/daily-report")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert conn
           |> get("/api/v1/finance/daily-report?date=nope")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-10-03")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert [invalid] =
             submit(conn, [%{"operation_id" => "bad", "type" => "start_finance_reporting"}])

    assert invalid["code"] == "invalid_reporting_date"

    assert [_, _] = submit(conn, [start(), open("group", "open", "hotel")])

    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-10-02")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "attributes transfers and corrections to the properties where cash moves", %{conn: conn} do
    assert Enum.all?(
             submit(conn, [
               open("source", "open-source", "b-hotel"),
               open("destination", "open-destination", "a-hotel"),
               start(),
               operation("record_cash_payment", "pay", "2026-10-03", %{
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }),
               operation("transfer_deposit", "transfer", "2026-10-04", %{
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 400
               }),
               operation("reduce_cash_payment", "reduce", "2026-10-05", %{
                 "payment_operation_id" => "pay",
                 "amount_cents" => 300
               }),
               operation("charge_back_payment", "charge", "2026-10-06", %{
                 "payment_operation_id" => "pay"
               })
             ]),
             &(&1["status"] == "applied")
           )

    transfer = report(conn, "2026-10-04")["cash"]
    assert Enum.map(transfer, & &1["property_id"]) == ["a-hotel", "b-hotel"]
    assert get_in(Enum.at(transfer, 0), ["movements", "transferred_in_cents"]) == 400
    assert get_in(Enum.at(transfer, 1), ["movements", "transferred_out_cents"]) == 400

    reduced =
      report(conn, "2026-10-05")["cash"]
      |> Enum.find(&(&1["property_id"] == "a-hotel"))

    assert reduced["property_id"] == "a-hotel"
    assert reduced["movements"]["reduced_cents"] == 300

    charged = report(conn, "2026-10-06")["cash"]

    assert Enum.find(charged, &(&1["property_id"] == "a-hotel"))["movements"][
             "charged_back_cents"
           ] == 100

    assert Enum.find(charged, &(&1["property_id"] == "b-hotel"))["movements"][
             "charged_back_cents"
           ] == 600
  end

  test "reports credit issuance, paused expiry, automatic expiry, and consumption", %{conn: conn} do
    refundable =
      open("refundable", "open-refundable", "hotel", "guest", %{
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })

    assert Enum.all?(
             submit(conn, [
               refundable,
               open("use-credit", "open-use", "hotel", "guest"),
               operation("record_cash_payment", "pay", "2026-10-02", %{
                 "group_id" => "refundable",
                 "amount_cents" => 1_000
               }),
               start(),
               operation("cancel_group", "issue", "2026-10-03", %{
                 "group_id" => "refundable",
                 "refund_method" => "hotel_credit"
               }),
               operation("apply_hotel_credit", "apply", "2026-10-04", %{
                 "group_id" => "use-credit",
                 "amount_cents" => 400
               })
             ]),
             &(&1["status"] == "applied")
           )

    issue = report(conn, "2026-10-03")
    assert hd(issue["cash"])["movements"]["converted_to_credit_cents"] == 1_000
    assert issue["credit"]["movements"]["issued_cents"] == 1_100
    assert issue["credit"]["closing_liability_cents"] == 1_100

    expiry = report(conn, "2027-10-04")
    assert expiry["credit"]["movements"]["expired_cents"] == 700
    assert expiry["credit"]["closing_liability_cents"] == 400

    assert [consumed] =
             submit(conn, [
               operation("cancel_group", "consume", "2027-10-05", %{"group_id" => "use-credit"})
             ])

    assert consumed["status"] == "applied"
    consumed_report = report(conn, "2027-10-05")
    assert consumed_report["credit"]["movements"]["consumed_cents"] == 400
    assert consumed_report["credit"]["closing_liability_cents"] == 0
  end

  test "a chargeback reclassifies a prior refund with signed movements", %{conn: conn} do
    group =
      open("group", "open", "hotel", "guest", %{
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })

    assert Enum.all?(
             submit(conn, [
               group,
               start(),
               operation("record_cash_payment", "pay", "2026-10-03", %{
                 "group_id" => "group",
                 "amount_cents" => 1_000
               }),
               operation("cancel_group", "cancel", "2026-10-04", %{"group_id" => "group"}),
               operation("charge_back_payment", "charge", "2026-10-05", %{
                 "payment_operation_id" => "pay"
               })
             ]),
             &(&1["status"] == "applied")
           )

    [cash] = report(conn, "2026-10-05")["cash"]
    assert cash["movements"]["refunded_cents"] == -1_000
    assert cash["movements"]["charged_back_cents"] == 1_000
    assert cash["opening_held_cents"] == 0
    assert cash["closing_held_cents"] == 0
  end

  test "credit expiring on the inception date is in opening liability and expires that day", %{
    conn: conn
  } do
    group =
      open("group", "open", "hotel", "guest", %{
        "arrival_on" => "2026-11-01",
        "departure_on" => "2026-11-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })

    assert Enum.all?(
             submit(conn, [
               group,
               operation("record_cash_payment", "pay", "2026-10-02", %{
                 "group_id" => "group",
                 "amount_cents" => 1_000
               }),
               operation("cancel_group", "issue", "2026-10-03", %{
                 "group_id" => "group",
                 "refund_method" => "hotel_credit"
               }),
               start("start", "2027-10-04")
             ]),
             &(&1["status"] == "applied")
           )

    credit = report(conn, "2027-10-04")["credit"]
    assert credit["opening_liability_cents"] == 1_100
    assert credit["movements"]["expired_cents"] == 1_100
    assert credit["closing_liability_cents"] == 0
  end

  test "reports unused entitlement revocation and later shortfall absorption", %{conn: conn} do
    flexible = fn id, operation_id ->
      open(id, operation_id, "hotel", "guest", %{
        "arrival_on" => "2026-11-15",
        "departure_on" => "2026-11-16",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
      })
    end

    assert Enum.all?(
             submit(conn, [
               flexible.("source", "open-source"),
               flexible.("destination", "open-destination"),
               operation("record_cash_payment", "pay", "2026-10-01", %{
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }),
               operation("cancel_group", "issue", "2026-10-02", %{
                 "group_id" => "source",
                 "refund_method" => "hotel_credit"
               }),
               start(),
               operation("apply_hotel_credit", "apply", "2026-10-03", %{
                 "group_id" => "destination",
                 "amount_cents" => 800
               }),
               operation("charge_back_payment", "charge", "2026-10-04", %{
                 "payment_operation_id" => "pay"
               }),
               operation("cancel_group", "restore", "2026-10-05", %{
                 "group_id" => "destination"
               })
             ]),
             &(&1["status"] == "applied")
           )

    charge = report(conn, "2026-10-04")["credit"]
    assert charge["movements"]["revoked_cents"] == 300
    assert charge["closing_liability_cents"] == 800

    restore = report(conn, "2026-10-05")["credit"]
    assert restore["movements"]["absorbed_cents"] == 800
    assert restore["closing_liability_cents"] == 0
  end
end
