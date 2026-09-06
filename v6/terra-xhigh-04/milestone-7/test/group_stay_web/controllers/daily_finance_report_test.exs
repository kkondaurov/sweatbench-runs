defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: true

  import Phoenix.ConnTest

  test "starts reporting from the committed opening position and posts later effects by date", %{
    conn: conn
  } do
    results =
      post_operations(conn, [
        open_group("open-prior", "prior", "guest-1", "ams-canal", "2027-01-01"),
        cash_payment("pay-prior", "prior", "2027-01-02", 1_000),
        start_reporting("start-reporting", "2027-01-03"),
        open_group("open-later", "later", "guest-2", "berlin-mitte", "2027-01-03"),
        cash_payment("pay-later", "later", "2027-01-02", 500)
      ])

    no_cash_movements = cash_movements()
    received_cash_movements = cash_movements(received_cents: 500)
    no_credit_report = credit_report()

    assert %{"results" => [_, _, start_result, _, _]} = results

    assert %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2027-01-03"
           } = start_result

    assert ["operation_id", "starts_on", "status"] == Map.keys(start_result) |> Enum.sort()

    assert %{
             "results" => [
               %{
                 "operation_id" => "start-reporting",
                 "status" => "applied",
                 "starts_on" => "2027-01-03"
               }
             ]
           } = post_operations(build_conn(), [start_reporting("start-reporting", "2027-01-03")])

    assert %{
             "data" => %{
               "date" => "2027-01-03",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "movements" => ^no_cash_movements,
                   "closing_held_cents" => 1_000
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 0,
                   "movements" => ^received_cash_movements,
                   "closing_held_cents" => 500
                 }
               ],
               "credit" => ^no_credit_report
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-03")
             |> json_response(200)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "closing_held_cents" => 1_000
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 500,
                   "closing_held_cents" => 500
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200)

    post_operations(build_conn(), [cancel_group("cancel-prior", "prior", "2027-01-04", "cash")])

    refunded_cash_movements = cash_movements(refunded_cents: 1_000)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "movements" => ^refunded_cash_movements,
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 500,
                   "closing_held_cents" => 500
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200)
  end

  test "reports transfers and chargeback reclassification at the cash's current property", %{
    conn: conn
  } do
    post_operations(conn, [
      start_reporting("start-reporting", "2027-01-01"),
      open_group("open-source", "source", "guest-1", "ams-canal", "2027-01-01"),
      cash_payment("pay-source", "source", "2027-01-02", 1_000),
      open_group("open-destination", "destination", "guest-1", "berlin-mitte", "2027-01-01"),
      transfer("move-cash", "source", "destination", "2027-01-04", 500, 2, 1),
      cancel_group("cancel-destination", "destination", "2027-01-05", "cash"),
      charge_back("charge-source", "pay-source", "2027-01-06", 3)
    ])

    transferred_out_cash_movements = cash_movements(transferred_out_cents: 500)
    transferred_in_cash_movements = cash_movements(transferred_in_cents: 500)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "movements" => ^transferred_out_cash_movements,
                   "closing_held_cents" => 500
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 0,
                   "movements" => ^transferred_in_cash_movements,
                   "closing_held_cents" => 500
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200)

    charged_back_cash_movements = cash_movements(charged_back_cents: 500)

    reclassified_cash_movements =
      cash_movements(refunded_cents: -500, charged_back_cents: 500)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 500,
                   "movements" => ^charged_back_cash_movements,
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "berlin-mitte",
                   "opening_held_cents" => 0,
                   "movements" => ^reclassified_cash_movements,
                   "closing_held_cents" => 0
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-06")
             |> json_response(200)
  end

  test "reports credit issuance and automatic expiry without a partner operation", %{conn: conn} do
    post_operations(conn, [
      start_reporting("start-reporting", "2027-01-01"),
      open_group("open-credit", "credit", "guest-1", "ams-canal", "2027-01-01"),
      cash_payment("pay-credit", "credit", "2027-01-02", 1_000),
      cancel_group("convert-credit", "credit", "2027-01-02", "hotel_credit")
    ])

    conversion_cash_movements =
      cash_movements(received_cents: 1_000, converted_to_credit_cents: 1_000)

    issued_credit_report =
      credit_report(0, issued_cents: 1_100, closing_liability_cents: 1_100)

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => ^conversion_cash_movements,
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => ^issued_credit_report
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-02")
             |> json_response(200)

    expired_credit_report =
      credit_report(1_100, expired_cents: 1_100, closing_liability_cents: 0)

    assert %{
             "data" => %{
               "cash" => [],
               "credit" => ^expired_credit_report
             }
           } =
             get(build_conn(), "/api/v1/finance/daily-report?date=2028-01-03")
             |> json_response(200)
  end

  test "validates reporting dates and availability", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=not-a-date")
             |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-01")
             |> json_response(404)

    assert %{
             "results" => [
               %{
                 "operation_id" => "bad-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           } =
             post_operations(build_conn(), [
               %{"operation_id" => "bad-start", "type" => "start_finance_reporting"}
             ])

    assert %{"results" => [%{"status" => "applied"}]} =
             post_operations(build_conn(), [start_reporting("start-reporting", "2027-01-02")])

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-01")
             |> json_response(404)

    assert %{
             "results" => [
               %{
                 "operation_id" => "later-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           } = post_operations(build_conn(), [start_reporting("later-start", "2027-01-03")])
  end

  defp cash_movements(overrides \\ []) do
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
      Map.new(overrides, fn {field, value} -> {Atom.to_string(field), value} end)
    )
  end

  defp credit_report(opening_liability_cents \\ 0, overrides \\ []) do
    {closing_liability_cents, movement_overrides} =
      Keyword.pop(overrides, :closing_liability_cents)

    movements =
      Map.merge(
        %{
          "issued_cents" => 0,
          "expired_cents" => 0,
          "consumed_cents" => 0,
          "revoked_cents" => 0,
          "absorbed_cents" => 0
        },
        Map.new(movement_overrides, fn {field, value} -> {Atom.to_string(field), value} end)
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

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_group(operation_id, group_id, guest_id, property_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2027-04-10",
      "departure_on" => "2027-04-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 5_000}]
    }
  end

  defp cash_payment(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_group(operation_id, group_id, occurred_on, refund_method) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         occurred_on,
         amount_cents,
         source_revision,
         destination_revision
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp post_operations(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations}) |> json_response(200)
  end
end
