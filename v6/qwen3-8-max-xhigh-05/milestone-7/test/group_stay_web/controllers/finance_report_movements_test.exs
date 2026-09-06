defmodule GroupStayWeb.FinanceReportMovementsTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    %{conn: conn}
  end

  defp cash_for(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  test "payments received after the start post to the later of occurred_on and starts_on", %{
    conn: conn
  } do
    pay_group(conn, "group-81", 9500)

    start_finance_reporting(conn, %{
      "occurred_on" => "2026-11-01",
      "starts_on" => "2026-11-01"
    })

    # Occurred before starts_on: posts to starts_on.
    pay_group(conn, "group-81", 500, %{
      "operation_id" => "op-pay-backdated",
      "occurred_on" => "2026-10-15"
    })

    # Occurred after starts_on: posts to occurred_on.
    pay_group(conn, "group-81", 1000, %{
      "operation_id" => "op-pay-later",
      "occurred_on" => "2026-11-03"
    })

    first = daily_report_data(conn, "2026-11-01")
    assert cash_for(first, "ams-canal")["opening_held_cents"] == 9500
    assert cash_for(first, "ams-canal")["movements"]["received_cents"] == 500
    assert cash_for(first, "ams-canal")["closing_held_cents"] == 10_000

    third = daily_report_data(conn, "2026-11-03")
    assert cash_for(third, "ams-canal")["movements"]["received_cents"] == 1500
    assert cash_for(third, "ams-canal")["closing_held_cents"] == 11_000

    # The later submission changed the earlier open report.
    assert cash_for(daily_report_data(conn, "2026-11-01"), "ams-canal")["closing_held_cents"] ==
             10_000

    assert ledger_data(conn)["cash_held_cents"] == 11_000
  end

  test "a refundable cancellation reports positive refunded movements", %{conn: conn} do
    pay_group(conn, "group-81", 9500)
    start_finance_reporting(conn)

    result = cancel_group(conn, "group-81", "2026-11-26")
    assert result["refunded_cents"] == 9500

    report = daily_report_data(conn, "2026-11-26")
    cash = cash_for(report, "ams-canal")
    assert cash["opening_held_cents"] == 9500
    assert cash["movements"]["refunded_cents"] == 9500
    assert cash["closing_held_cents"] == 0

    assert ledger_data(conn)["cash_refunded_cents"] == 9500
  end

  test "a non-refundable cancellation reports retained movements", %{conn: conn} do
    pay_group(conn, "group-81", 9500)
    start_finance_reporting(conn)

    result = cancel_group(conn, "group-81", "2026-12-01")
    assert result["retained_cents"] == 9500

    report = daily_report_data(conn, "2026-12-01")
    cash = cash_for(report, "ams-canal")
    assert cash["movements"]["retained_cents"] == 9500
    assert cash["closing_held_cents"] == 0

    assert ledger_data(conn)["cash_retained_cents"] == 9500
  end

  test "a credit settlement reports converted cash and issued liability", %{conn: conn} do
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)

    result = cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
    assert result["credit_issued_cents"] == 5500

    report = daily_report_data(conn, "2026-11-26")
    cash = cash_for(report, "ams-canal")
    assert cash["movements"]["converted_to_credit_cents"] == 5000
    assert cash["closing_held_cents"] == 0

    assert report["credit"]["opening_liability_cents"] == 0
    assert report["credit"]["movements"]["issued_cents"] == 5500
    assert report["credit"]["closing_liability_cents"] == 5500

    assert ledger_data(conn)["cash_converted_to_credit_cents"] == 5000
    assert ledger_data(conn)["credit_liability_cents"] == 5500
  end

  test "transfers report equal out and in amounts on the groups' properties", %{conn: conn} do
    open_group_at(conn, "group-82", "rotx-dam")
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)

    %{"results" => [transfer]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-transfer",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-11-02",
          "source_group_id" => "group-81",
          "destination_group_id" => "group-82",
          "amount_cents" => 2000
        }
      ])

    assert transfer["status"] == "applied"

    report = daily_report_data(conn, "2026-11-02")
    ams = cash_for(report, "ams-canal")
    rotx = cash_for(report, "rotx-dam")

    assert ams["opening_held_cents"] == 5000
    assert ams["movements"]["transferred_out_cents"] == 2000
    assert ams["closing_held_cents"] == 3000

    assert rotx["opening_held_cents"] == 0
    assert rotx["movements"]["transferred_in_cents"] == 2000
    assert rotx["closing_held_cents"] == 2000

    total_in =
      report["cash"] |> Enum.map(& &1["movements"]["transferred_in_cents"]) |> Enum.sum()

    total_out =
      report["cash"] |> Enum.map(& &1["movements"]["transferred_out_cents"]) |> Enum.sum()

    assert total_in == total_out
    assert ledger_data(conn)["cash_held_cents"] == 5000
  end

  test "a reduction follows the cash to the property where it is held", %{conn: conn} do
    open_group_at(conn, "group-82", "rotx-dam")
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)

    submit_batch(conn, [
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 2000
      },
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => "op-pay-group-81",
        "amount_cents" => 500
      }
    ])

    report = daily_report_data(conn, "2026-11-03")
    ams = cash_for(report, "ams-canal")
    rotx = cash_for(report, "rotx-dam")

    # The reduction removed the most recently filled cash, which was held at
    # the destination property after the transfer.
    assert ams["movements"]["reduced_cents"] == 0
    assert ams["closing_held_cents"] == 3000

    assert rotx["movements"]["reduced_cents"] == 500
    assert rotx["closing_held_cents"] == 1500

    assert ledger_data(conn)["cash_reduced_cents"] == 500
    assert ledger_data(conn)["cash_held_cents"] == 4500
  end

  test "reversing a refund reports negative refunded and positive charged back", %{conn: conn} do
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)
    cancel_group(conn, "group-81", "2026-11-26")

    refunded_before =
      cash_for(daily_report_data(conn, "2026-11-26"), "ams-canal")["movements"]["refunded_cents"]

    assert refunded_before == 5000

    %{"results" => [chargeback]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-28",
          "payment_operation_id" => "op-pay-group-81"
        }
      ])

    assert chargeback["status"] == "applied"
    assert chargeback["charged_back_cents"] == 5000

    report = daily_report_data(conn, "2026-11-28")
    cash = cash_for(report, "ams-canal")

    # The reversal is a negative refunded movement: the cumulative refunded
    # total drops by the reversed amount while charged back rises by it.
    assert cash["movements"]["refunded_cents"] == 0
    assert cash["movements"]["refunded_cents"] - refunded_before == -5000
    assert cash["movements"]["charged_back_cents"] == 5000
    assert cash["closing_held_cents"] == 0

    ledger = ledger_data(conn)
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 5000
  end

  test "a chargeback of held cash reports charged back where the cash is held", %{conn: conn} do
    open_group_at(conn, "group-82", "rotx-dam")
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)

    submit_batch(conn, [
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 2000
      },
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => "op-pay-group-81"
      }
    ])

    report = daily_report_data(conn, "2026-11-03")
    ams = cash_for(report, "ams-canal")
    rotx = cash_for(report, "rotx-dam")

    assert ams["movements"]["charged_back_cents"] == 3000
    assert ams["closing_held_cents"] == 0
    assert rotx["movements"]["charged_back_cents"] == 2000
    assert rotx["closing_held_cents"] == 0

    assert ledger_data(conn)["cash_charged_back_cents"] == 5000
    assert ledger_data(conn)["cash_held_cents"] == 0
  end

  test "a credit-only transfer reports no cash movement", %{conn: conn} do
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)

    # Cancel for hotel credit, then fund a second group with that credit.
    cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
    open_group_at(conn, "group-82", "rotx-dam")
    open_group_at(conn, "group-83", "damrak")

    submit_batch(conn, [
      %{
        "operation_id" => "op-apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-82",
        "amount_cents" => 2000
      },
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-28",
        "source_group_id" => "group-82",
        "destination_group_id" => "group-83",
        "amount_cents" => 1000
      }
    ])

    report = daily_report_data(conn, "2026-11-28")

    # The converted cash movement from the cancellation is the only cash
    # movement; the credit application and transfer move no cash.
    ams = cash_for(report, "ams-canal")
    assert ams["movements"]["converted_to_credit_cents"] == 5000
    assert cash_for(report, "rotx-dam") == nil
    assert cash_for(report, "damrak") == nil

    # Applying and transferring credit changes no liability.
    assert report["credit"]["closing_liability_cents"] == 5500
    assert ledger_data(conn)["credit_liability_cents"] == 5500
  end

  test "a chargeback follows settled cash to the property where it settled", %{conn: conn} do
    open_group_at(conn, "group-82", "rotx-dam")
    pay_group(conn, "group-81", 5000)
    start_finance_reporting(conn)

    submit_batch(conn, [
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 2000
      },
      %{
        "operation_id" => "op-cancel-82",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-03",
        "group_id" => "group-82"
      },
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => "op-pay-group-81"
      }
    ])

    report = daily_report_data(conn, "2026-11-04")
    ams = cash_for(report, "ams-canal")
    rotx = cash_for(report, "rotx-dam")

    # The transferred cash settled (was refunded) at the destination property
    # and is charged back there, not at the payment's original property.
    assert ams["movements"]["charged_back_cents"] == 3000
    assert ams["closing_held_cents"] == 0

    assert rotx["movements"]["refunded_cents"] == 0
    assert rotx["movements"]["charged_back_cents"] == 2000
    assert rotx["closing_held_cents"] == 0

    assert ledger_data(conn)["cash_charged_back_cents"] == 5000
  end

  test "cancelling selected rooms reports the settled rooms' movements", %{conn: conn} do
    pay_group(conn, "group-81", 9000)
    start_finance_reporting(conn)

    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "room_ids" => ["room-a"]
        }
      ])

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 9000

    report = daily_report_data(conn, "2026-11-26")
    cash = cash_for(report, "ams-canal")
    assert cash["opening_held_cents"] == 9000
    assert cash["movements"]["refunded_cents"] == 9000
    assert cash["closing_held_cents"] == 0
  end

  test "rejected operations leave no reporting movement", %{conn: conn} do
    start_finance_reporting(conn)

    submit_batch(conn, [
      %{
        "operation_id" => "op-pay-invalid",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "group-81",
        "amount_cents" => 0
      },
      %{
        "operation_id" => "op-pay-missing-group",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "group-missing",
        "amount_cents" => 1000
      }
    ])

    report = daily_report_data(conn, "2026-11-02")
    assert report["cash"] == []
  end

  test "a later rejected operation leaves earlier applied movements in place", %{conn: conn} do
    start_finance_reporting(conn)

    %{"results" => results} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-pay-good",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-81",
          "amount_cents" => 1000
        },
        %{
          "operation_id" => "op-pay-bad",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-81",
          "amount_cents" => -5
        }
      ])

    assert Enum.map(results, & &1["status"]) == ["applied", "rejected"]

    report = daily_report_data(conn, "2026-11-02")
    assert cash_for(report, "ams-canal")["movements"]["received_cents"] == 1000
  end

  test "a durable retry does not report a movement twice", %{conn: conn} do
    start_finance_reporting(conn)

    operation = %{
      "operation_id" => "op-pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-02",
      "group_id" => "group-81",
      "amount_cents" => 1000
    }

    %{"results" => [first]} = submit_batch(conn, [operation])
    %{"results" => [retry]} = submit_batch(conn, [operation])
    assert retry == first

    report = daily_report_data(conn, "2026-11-02")
    assert cash_for(report, "ams-canal")["movements"]["received_cents"] == 1000
    assert cash_for(report, "ams-canal")["closing_held_cents"] == 1000
  end

  test "cash closings reconcile with the ledger's held cash", %{conn: conn} do
    open_group_at(conn, "group-82", "rotx-dam")
    pay_group(conn, "group-81", 9000)
    pay_group(conn, "group-82", 4000)
    start_finance_reporting(conn)

    submit_batch(conn, [
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 1500
      },
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-03",
        "group_id" => "group-82"
      },
      %{
        "operation_id" => "op-pay-more",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-03",
        "group_id" => "group-81",
        "amount_cents" => 500
      }
    ])

    report = daily_report_data(conn, "2026-11-03")

    total_closing =
      report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

    assert total_closing == ledger_data(conn)["cash_held_cents"]
  end
end
