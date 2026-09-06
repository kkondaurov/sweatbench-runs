defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts reporting at the exact batch position and validates report dates", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/finance/daily-report?date=2027-01-05"), 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert json_response(get(build_conn(), "/api/v1/finance/daily-report"), 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    operations = [
      open_group("group-1", "open-1", "ams-canal"),
      payment("group-1", "pay-before", 40, "2027-01-02"),
      start_reporting("start", "2027-01-05"),
      payment("group-1", "pay-after", 20, "2027-01-03")
    ]

    assert %{"results" => [_, _, start, _]} = submit(build_conn(), operations)

    assert start == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-05"
           }

    assert json_response(
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-04"),
             404
           ) == %{"error" => %{"code" => "report_not_available"}}

    assert %{"data" => report} = report("2027-01-05")

    assert report == %{
             "date" => "2027-01-05",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 40,
                 "movements" => cash_movements(%{"received_cents" => 20}),
                 "closing_held_cents" => 60
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             }
           }

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             submit(build_conn(), [start_reporting("another-start", "2027-02-01")])

    assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
             submit(build_conn(), [start_reporting("bad-start", "not-a-date")])
  end

  test "reports transfers and follows cash to its settlement property", %{conn: conn} do
    operations = [
      start_reporting("start", "2027-01-01"),
      open_group("source", "open-source", "ams-canal"),
      open_group("destination", "open-destination", "berlin-mitte"),
      payment("source", "pay", 100, "2027-01-02"),
      transfer("move", "source", "destination", 60, "2027-01-03"),
      cancel("destination", "refund", "2027-01-04"),
      chargeback("chargeback", "pay", "2027-01-05")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"cash" => transfer_cash}} = report("2027-01-03")

    assert transfer_cash == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 100,
               "movements" => cash_movements(%{"transferred_out_cents" => 60}),
               "closing_held_cents" => 40
             },
             %{
               "property_id" => "berlin-mitte",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"transferred_in_cents" => 60}),
               "closing_held_cents" => 60
             }
           ]

    assert %{"data" => %{"cash" => chargeback_cash}} = report("2027-01-05")

    assert chargeback_cash == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 40,
               "movements" => cash_movements(%{"charged_back_cents" => 40}),
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "berlin-mitte",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{"refunded_cents" => -60, "charged_back_cents" => 60}),
               "closing_held_cents" => 0
             }
           ]

    before_retry = report("2027-01-05")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(build_conn(), [chargeback("chargeback", "pay", "2027-01-05")])

    assert report("2027-01-05") == before_retry
  end

  test "reports company-wide credit issue, consumption, and automatic expiry", %{conn: conn} do
    operations = [
      start_reporting("start", "2027-01-01"),
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      cancel("origin", "issue", "2027-01-02") |> Map.put("refund_method", "hotel_credit"),
      open_group("spend", "open-spend", "ams-canal", "advance_purchase"),
      apply_credit("spend", "apply", 40, "2027-01-03"),
      cancel("spend", "consume", "2027-01-04")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => issued}} = report("2027-01-02")
    assert issued["movements"] == credit_movements(%{"issued_cents" => 110})
    assert issued["closing_liability_cents"] == 110

    assert %{"data" => %{"credit" => applied}} = report("2027-01-03")
    assert applied["movements"] == credit_movements()
    assert applied["closing_liability_cents"] == 110

    assert %{"data" => %{"credit" => consumed}} = report("2027-01-04")
    assert consumed["movements"] == credit_movements(%{"consumed_cents" => 40})
    assert consumed["closing_liability_cents"] == 70

    assert %{"data" => %{"credit" => expired}} = report("2028-01-03")
    assert expired["opening_liability_cents"] == 70
    assert expired["movements"] == credit_movements(%{"expired_cents" => 70})
    assert expired["closing_liability_cents"] == 0
    assert report("2028-01-03") == report("2028-01-03")
  end

  test "uses actual revocation when a chargeback is posted before an earlier application", %{
    conn: conn
  } do
    operations = [
      start_reporting("start", "2027-01-01"),
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      cancel("origin", "issue", "2027-01-02") |> Map.put("refund_method", "hotel_credit"),
      open_group("spend", "open-spend", "ams-canal"),
      apply_credit("spend", "apply", 80, "2027-01-10"),
      chargeback("chargeback", "pay-origin", "2027-01-05")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => credit}} = report("2027-01-05")
    assert credit["opening_liability_cents"] == 110
    assert credit["movements"] == credit_movements(%{"revoked_cents" => 30})
    assert credit["closing_liability_cents"] == 80

    assert %{"data" => %{"credit_liability_cents" => 80}} =
             get(build_conn(), "/api/v1/ledger?on=2027-01-10") |> json_response(200)
  end

  test "does not expire historically issued credit before its clamped posting date", %{conn: conn} do
    operations = [
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      start_reporting("start", "2028-02-01"),
      cancel("origin", "historical-issue", "2027-01-02")
      |> Map.put("refund_method", "hotel_credit")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => credit}} = report("2028-02-01")
    assert credit["opening_liability_cents"] == 0

    assert credit["movements"] ==
             credit_movements(%{"issued_cents" => 110, "expired_cents" => 110})

    assert credit["closing_liability_cents"] == 0
  end

  test "does not revoke liability that already left through expiry", %{conn: conn} do
    operations = [
      start_reporting("start", "2027-01-01"),
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      cancel("origin", "issue", "2027-01-02") |> Map.put("refund_method", "hotel_credit"),
      chargeback("late-chargeback", "pay-origin", "2028-01-04")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => expiry}} = report("2028-01-03")
    assert expiry["movements"] == credit_movements(%{"expired_cents" => 110})
    assert expiry["closing_liability_cents"] == 0

    assert %{"data" => %{"credit" => chargeback}} = report("2028-01-04")
    assert chargeback["movements"] == credit_movements()
    assert chargeback["closing_liability_cents"] == 0
  end

  test "reconciles credit applied after its reporting expiry with an earlier occurred date", %{
    conn: conn
  } do
    operations = [
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      cancel("origin", "issue", "2027-01-02") |> Map.put("refund_method", "hotel_credit"),
      start_reporting("start", "2028-02-01"),
      open_group("spend", "open-spend", "ams-canal"),
      apply_credit("spend", "historical-apply", 80, "2027-01-03")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => credit}} = report("2028-02-01")
    assert credit["opening_liability_cents"] == 0
    assert credit["movements"] == credit_movements(%{"expired_cents" => -80})
    assert credit["closing_liability_cents"] == 80

    assert %{"data" => %{"credit_liability_cents" => 80}} =
             get(build_conn(), "/api/v1/ledger?on=2028-02-01") |> json_response(200)
  end

  test "nets clamped expiry after same-day historical issuance and application", %{conn: conn} do
    operations = [
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      start_reporting("start", "2028-02-01"),
      cancel("origin", "historical-issue", "2027-01-02")
      |> Map.put("refund_method", "hotel_credit"),
      open_group("spend", "open-spend", "ams-canal"),
      apply_credit("spend", "historical-apply", 80, "2027-01-03")
    ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => credit}} = report("2028-02-01")

    assert credit["movements"] ==
             credit_movements(%{"issued_cents" => 110, "expired_cents" => 30})

    assert credit["closing_liability_cents"] == 80
  end

  test "splits same-day restored credit from latent expired credit when applying", %{conn: conn} do
    operations =
      historical_restoration_setup() ++
        [
          open_group("spend", "open-spend", "ams-canal"),
          apply_credit("spend", "mixed-apply", 100, "2027-01-05")
        ]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => credit}} = report("2028-02-01")
    assert credit["opening_liability_cents"] == 80
    assert credit["movements"] == credit_movements(%{"expired_cents" => -20})
    assert credit["closing_liability_cents"] == 100

    assert %{"data" => %{"credit_liability_cents" => 100}} =
             get(build_conn(), "/api/v1/ledger?on=2028-02-01") |> json_response(200)
  end

  test "revokes same-day restored liability from an otherwise expired lot", %{conn: conn} do
    operations =
      historical_restoration_setup() ++
        [chargeback("restored-chargeback", "pay-origin", "2027-01-05")]

    assert %{"results" => results} = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"credit" => credit}} = report("2028-02-01")
    assert credit["opening_liability_cents"] == 80
    assert credit["movements"] == credit_movements(%{"revoked_cents" => 80})
    assert credit["closing_liability_cents"] == 0

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(build_conn(), "/api/v1/ledger?on=2028-02-01") |> json_response(200)
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end

  defp report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}") |> json_response(200)
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_group(group_id, operation_id, property_id, rate_plan \\ "flexible") do
    rate = if rate_plan == "flexible", do: 500, else: 100

    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => rate}]
    }
  end

  defp payment(group_id, operation_id, amount, occurred_on) do
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

  defp cancel(group_id, operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
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

  defp apply_credit(group_id, operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp historical_restoration_setup do
    [
      open_group("origin", "open-origin", "ams-canal"),
      payment("origin", "pay-origin", 100, "2027-01-02"),
      cancel("origin", "issue", "2027-01-02") |> Map.put("refund_method", "hotel_credit"),
      open_group("holder", "open-holder", "ams-canal"),
      apply_credit("holder", "apply-holder", 80, "2027-01-03"),
      start_reporting("start", "2028-02-01"),
      cancel("holder", "restore-holder", "2027-01-04")
    ]
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
