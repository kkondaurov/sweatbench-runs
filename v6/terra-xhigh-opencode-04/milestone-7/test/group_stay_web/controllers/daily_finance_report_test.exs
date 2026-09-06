defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates, durably starts, and gates finance reporting", %{conn: conn} do
    assert daily_report_error(conn, nil, 422) == "invalid_reporting_date"
    assert daily_report_error(conn, "not-a-date", 422) == "invalid_reporting_date"
    assert daily_report_error(conn, "2027-01-01", 404) == "report_not_available"

    assert submit(conn, [start_reporting("invalid-start", "not-a-date")]) == %{
             "results" => [
               %{
                 "operation_id" => "invalid-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }

    assert submit(conn, [
             %{"operation_id" => "missing-start", "type" => "start_finance_reporting"}
           ]) == %{
             "results" => [
               %{
                 "operation_id" => "missing-start",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
           }

    started = %{
      "operation_id" => "start-reporting",
      "status" => "applied",
      "starts_on" => "2027-01-10"
    }

    assert submit(conn, [start_reporting("start-reporting", "2027-01-10")]) == %{
             "results" => [started]
           }

    assert submit(conn, [start_reporting("start-reporting", "2027-01-10")]) == %{
             "results" => [started]
           }

    assert submit(conn, [start_reporting("another-start", "2027-01-11")]) == %{
             "results" => [
               %{
                 "operation_id" => "another-start",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ]
           }

    assert daily_report_error(conn, "2027-01-09", 404) == "report_not_available"
  end

  test "captures a same-batch opening position and posts later cash movements on the reporting date",
       %{conn: conn} do
    response =
      submit(conn, [
        open_group("open-1", "group-1", "ams-canal", "2027-02-01"),
        cash_payment("opening-payment", "group-1", 1_000, 1, "2027-02-02"),
        start_reporting("start-reporting", "2027-01-10"),
        cash_payment("posted-payment", "group-1", 1_000, 2, "2027-01-05")
      ])

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2027-01-10"
           }

    assert daily_report(conn, "2027-01-10") == %{
             "date" => "2027-01-10",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(received_cents: 1_000),
                 "closing_held_cents" => 2_000
               }
             ],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" => late_adjustments()
           }

    assert submit(conn, [cash_payment("posted-payment", "group-1", 1_000, 2, "2027-01-05")]) == %{
             "results" => [Enum.at(response["results"], 3)]
           }

    assert daily_report(conn, "2027-01-10")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_000,
               "movements" => cash_movements(received_cents: 1_000),
               "closing_held_cents" => 2_000
             }
           ]

    assert submit(conn, [cancel_group("cancel-1", "group-1", 3, "2027-01-11")]) == %{
             "results" => [
               %{
                 "operation_id" => "cancel-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "refunded_cents" => 2_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ]
           }

    assert daily_report(conn, "2027-01-11") == %{
             "date" => "2027-01-11",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 2_000,
                 "movements" => cash_movements(refunded_cents: 2_000),
                 "closing_held_cents" => 0
               }
             ],
             "credit" => credit_report(0, 0, 0, 0, 0, 0, 0),
             "late_adjustments" => late_adjustments()
           }
  end

  test "reports transferred and reduced cash at the properties where it is held", %{conn: conn} do
    submit(conn, [
      open_group("open-source", "source", "ams-canal", "2027-01-01"),
      cash_payment("pay-source", "source", 2_000, 1, "2027-01-01"),
      open_group("open-destination", "destination", "par-left", "2027-01-01"),
      start_reporting("start-reporting", "2027-01-10"),
      transfer("transfer-1", "source", "destination", 1_000, 2, 1, "2027-01-11"),
      reduce_payment("reduce-1", "pay-source", 500, 3, "2027-01-12")
    ])

    assert daily_report(conn, "2027-01-11")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2_000,
               "movements" => cash_movements(transferred_out_cents: 1_000),
               "closing_held_cents" => 1_000
             },
             %{
               "property_id" => "par-left",
               "opening_held_cents" => 0,
               "movements" => cash_movements(transferred_in_cents: 1_000),
               "closing_held_cents" => 1_000
             }
           ]

    assert daily_report(conn, "2027-01-12")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_000,
               "movements" => cash_movements(),
               "closing_held_cents" => 1_000
             },
             %{
               "property_id" => "par-left",
               "opening_held_cents" => 1_000,
               "movements" => cash_movements(reduced_cents: 500),
               "closing_held_cents" => 500
             }
           ]
  end

  test "reports hotel credit issuance and expiry without changing domain state", %{conn: conn} do
    submit(conn, [
      open_group("open-source", "source", "ams-canal", "2027-01-01"),
      cash_payment("pay-source", "source", 1_000, 1, "2027-01-01"),
      start_reporting("start-reporting", "2027-01-01"),
      cancel_group("cancel-source", "source", 2, "2027-01-02", "hotel_credit"),
      open_group("open-target", "target", "ams-canal", "2027-01-03"),
      apply_credit("apply-credit", "target", 1_000, 1, "2027-01-03")
    ])

    assert daily_report(conn, "2027-01-02")["credit"] ==
             credit_report(0, 1_100, 0, 0, 0, 0, 1_100)

    expiry_report = daily_report(conn, "2028-01-03")

    assert expiry_report["credit"] == credit_report(1_100, 0, 100, 0, 0, 0, 1_000)
    assert daily_report(conn, "2028-01-03") == expiry_report

    assert conn
           |> get(~p"/api/v1/ledger?on=2028-01-03")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 1_000
  end

  test "reclassifies a post-start cash refund when it is charged back", %{conn: conn} do
    submit(conn, [
      open_group("open-1", "group-1", "ams-canal", "2027-01-01"),
      cash_payment("pay-1", "group-1", 1_000, 1, "2027-01-01"),
      start_reporting("start-reporting", "2027-01-01"),
      cancel_group("cancel-1", "group-1", 2, "2027-01-02"),
      charge_back("chargeback-1", "pay-1", 3, "2027-01-03")
    ])

    assert daily_report(conn, "2027-01-03")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => cash_movements(refunded_cents: -1_000, charged_back_cents: 1_000),
               "closing_held_cents" => 0
             }
           ]
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp daily_report(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp daily_report_error(conn, nil, status) do
    conn
    |> get(~p"/api/v1/finance/daily-report")
    |> json_response(status)
    |> get_in(["error", "code"])
  end

  defp daily_report_error(conn, date, status) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(status)
    |> get_in(["error", "code"])
  end

  defp open_group(operation_id, group_id, property_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
    }
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_group(
         operation_id,
         group_id,
         expected_revision,
         occurred_on,
         refund_method \\ "cash"
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision,
      "refund_method" => refund_method
    }
  end

  defp apply_credit(operation_id, group_id, amount_cents, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         expected_revision,
         destination_expected_revision,
         occurred_on
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision,
      "destination_expected_revision" => destination_expected_revision
    }
  end

  defp reduce_payment(
         operation_id,
         payment_operation_id,
         amount_cents,
         expected_revision,
         occurred_on
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back(operation_id, payment_operation_id, expected_revision, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp cash_movements(overrides \\ []) do
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
    |> Map.merge(Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end))
  end

  defp credit_report(opening, issued, expired, consumed, revoked, absorbed, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => %{
        "issued_cents" => issued,
        "expired_cents" => expired,
        "consumed_cents" => consumed,
        "revoked_cents" => revoked,
        "absorbed_cents" => absorbed
      },
      "closing_liability_cents" => closing
    }
  end

  defp late_adjustments do
    %{
      "cash" => [],
      "credit" => %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      }
    }
  end
end
