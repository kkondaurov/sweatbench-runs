defmodule GroupStayWeb.FinanceReportCreditTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 5000)

    start_finance_reporting(conn, %{
      "occurred_on" => "2026-11-01",
      "starts_on" => "2026-11-01"
    })

    %{conn: conn}
  end

  defp issue_credit(conn) do
    result = cancel_group(conn, "group-81", "2026-11-02", %{"refund_method" => "hotel_credit"})
    assert result["credit_issued_cents"] == 5500
    result
  end

  defp apply_credit(conn, amount_cents, overrides \\ %{}) do
    operation =
      Map.merge(
        %{
          "operation_id" => "op-apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-03",
          "group_id" => "group-82",
          "amount_cents" => amount_cents
        },
        overrides
      )

    %{"results" => [result]} = submit_batch(conn, [operation])
    assert result["status"] == "applied"
    result
  end

  test "unused credit expires the day after expires_on without any operation", %{conn: conn} do
    issue_credit(conn)

    # The lot issued on 2026-11-02 is available through 2027-11-02 and
    # expires on 2027-11-03.
    before_expiry = daily_report_data(conn, "2027-11-02")
    assert before_expiry["credit"]["movements"]["issued_cents"] == 5500
    assert before_expiry["credit"]["movements"]["expired_cents"] == 0
    assert before_expiry["credit"]["closing_liability_cents"] == 5500

    on_expiry = daily_report_data(conn, "2027-11-03")
    assert on_expiry["credit"]["movements"]["expired_cents"] == 5500
    assert on_expiry["credit"]["closing_liability_cents"] == 0

    assert ledger_data(conn, %{"on" => "2027-11-03"})["credit_liability_cents"] == 0
  end

  test "applying and restoring credit produces no movement and keeps liability", %{conn: conn} do
    issue_credit(conn)
    open_group_at(conn, "group-82", "rotx-dam")
    apply_credit(conn, 2000)

    applied = daily_report_data(conn, "2026-11-03")
    assert applied["credit"]["movements"]["issued_cents"] == 5500
    assert applied["credit"]["closing_liability_cents"] == 5500
    assert ledger_data(conn)["credit_liability_cents"] == 5500

    # Refundable restoration returns the credit to its lot: still no movement.
    assert %{"status" => "applied"} = cancel_group(conn, "group-82", "2026-11-05")

    restored = daily_report_data(conn, "2026-11-05")
    assert restored["credit"]["closing_liability_cents"] == 5500
    assert restored["credit"]["movements"]["expired_cents"] == 0
    assert restored["credit"]["movements"]["absorbed_cents"] == 0
    assert ledger_data(conn)["credit_liability_cents"] == 5500
  end

  test "restoring credit whose lot has already expired reports expiry", %{conn: conn} do
    issue_credit(conn)

    # A far-future stay so cancellation after the lot's expiry is still
    # refundable.
    open_group_at(conn, "group-82", "rotx-dam", %{
      "arrival_on" => "2028-06-01",
      "departure_on" => "2028-06-04"
    })

    apply_credit(conn, 2000)

    # Cancel after the lot's expiry date: the restored amount expires
    # immediately instead of becoming available again.
    assert %{"status" => "applied"} = cancel_group(conn, "group-82", "2027-12-01")

    report = daily_report_data(conn, "2027-12-01")
    credit = report["credit"]

    # 3500 expired automatically on 2027-11-03; 2000 expired on restoration.
    assert credit["movements"]["expired_cents"] == 5500
    assert credit["closing_liability_cents"] == 0

    assert ledger_data(conn, %{"on" => "2027-12-01"})["credit_liability_cents"] == 0
  end

  test "non-refundable settlement consumes applied credit", %{conn: conn} do
    issue_credit(conn)
    open_group_at(conn, "group-82", "rotx-dam")
    apply_credit(conn, 2000)

    # group-82 arrives 2026-12-10; cancelling on 2026-12-01 is non-refundable.
    result = cancel_group(conn, "group-82", "2026-12-01")
    assert result["status"] == "applied"

    report = daily_report_data(conn, "2026-12-01")
    credit = report["credit"]
    assert credit["movements"]["issued_cents"] == 5500
    assert credit["movements"]["consumed_cents"] == 2000
    assert credit["closing_liability_cents"] == 3500

    assert ledger_data(conn)["credit_liability_cents"] == 3500
  end

  test "a chargeback revokes unspent entitlement", %{conn: conn} do
    issue_credit(conn)
    open_group_at(conn, "group-82", "rotx-dam")
    apply_credit(conn, 2000)

    %{"results" => [chargeback]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-04",
          "payment_operation_id" => "op-pay-group-81"
        }
      ])

    assert chargeback["status"] == "applied"

    report = daily_report_data(conn, "2026-11-04")
    credit = report["credit"]
    assert credit["movements"]["issued_cents"] == 5500
    # The entitlement is the bonus value the payment contributed: 500.
    assert credit["movements"]["revoked_cents"] == 500
    assert credit["closing_liability_cents"] == 5000

    assert ledger_data(conn)["credit_liability_cents"] == 5000
    assert ledger_data(conn)["credit_shortfall_cents"] == 0
  end

  test "restoration absorbed by a shortfall reports absorbed", %{conn: conn} do
    issue_credit(conn)
    open_group_at(conn, "group-82", "rotx-dam")
    apply_credit(conn, 5500)

    # The lot is fully spent, so the 500 entitlement cannot be removed and
    # becomes unrecovered clawback.
    submit_batch(conn, [
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => "op-pay-group-81"
      }
    ])

    assert ledger_data(conn)["credit_shortfall_cents"] == 500

    # Refundable cancellation restores the applied credit into a shortfalled
    # lot; the shortfall absorbs 500 before the rest becomes available.
    assert %{"status" => "applied"} = cancel_group(conn, "group-82", "2026-11-05")

    report = daily_report_data(conn, "2026-11-05")
    credit = report["credit"]
    assert credit["movements"]["revoked_cents"] == 0
    assert credit["movements"]["absorbed_cents"] == 500
    assert credit["closing_liability_cents"] == 5000

    assert ledger_data(conn)["credit_liability_cents"] == 5000
    assert ledger_data(conn)["credit_shortfall_cents"] == 0
  end

  test "revoking an already expired lot reports no revoked movement", %{conn: conn} do
    issue_credit(conn)

    # Charge back after the lot's expiry date (2027-11-03): the liability was
    # already gone, so nothing is revoked.
    %{"results" => [chargeback]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-12-01",
          "payment_operation_id" => "op-pay-group-81"
        }
      ])

    assert chargeback["status"] == "applied"

    report = daily_report_data(conn, "2027-12-01")
    credit = report["credit"]
    assert credit["movements"]["issued_cents"] == 5500
    assert credit["movements"]["expired_cents"] == 5500
    assert credit["movements"]["revoked_cents"] == 0
    assert credit["closing_liability_cents"] == 0
  end

  test "credit issued before reporting starts opens the liability", %{conn: conn} do
    # Cancel before starting reporting: the issued lot is part of the opening
    # position. (setup started reporting on 2026-11-01; use a fresh start.)
    conn
    |> cancel_group("group-81", "2026-11-02", %{"refund_method" => "hotel_credit"})

    report = daily_report_data(conn, "2026-11-02")
    assert report["credit"]["opening_liability_cents"] == 0
    assert report["credit"]["movements"]["issued_cents"] == 5500
  end

  test "the closing liability reconciles with the ledger view", %{conn: conn} do
    issue_credit(conn)
    open_group_at(conn, "group-82", "rotx-dam")
    apply_credit(conn, 2000)

    for date <- ["2026-11-02", "2026-11-03", "2027-11-02", "2027-11-03"] do
      report = daily_report_data(conn, date)
      ledger = ledger_data(conn, %{"on" => date})

      assert report["credit"]["closing_liability_cents"] ==
               ledger["credit_liability_cents"],
             "credit liability for #{date} does not reconcile"
    end
  end
end

defmodule GroupStayWeb.FinanceReportCreditOpeningTest do
  use GroupStayWeb.ConnCase

  test "credit issued and applied before reporting starts opens the liability", %{conn: conn} do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 5000)

    cancel_group(conn, "group-81", "2026-10-20", %{"refund_method" => "hotel_credit"})
    open_group_at(conn, "group-82", "rotx-dam")

    submit_batch(conn, [
      %{
        "operation_id" => "op-apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-25",
        "group_id" => "group-82",
        "amount_cents" => 2000
      }
    ])

    assert ledger_data(conn)["credit_liability_cents"] == 5500

    start_finance_reporting(conn, %{
      "occurred_on" => "2026-11-01",
      "starts_on" => "2026-11-01"
    })

    opening = daily_report_data(conn, "2026-11-01")
    assert opening["credit"]["opening_liability_cents"] == 5500
    assert opening["credit"]["closing_liability_cents"] == 5500

    # Non-refundable cancellation consumes the applied credit.
    assert %{"status" => "applied"} = cancel_group(conn, "group-82", "2026-12-01")

    consumed = daily_report_data(conn, "2026-12-01")
    assert consumed["credit"]["movements"]["consumed_cents"] == 2000
    assert consumed["credit"]["closing_liability_cents"] == 3500
    assert ledger_data(conn)["credit_liability_cents"] == 3500

    # The remaining 3500 expires the day after expires_on (2027-10-20).
    expired = daily_report_data(conn, "2027-10-21")
    assert expired["credit"]["movements"]["expired_cents"] == 3500
    assert expired["credit"]["closing_liability_cents"] == 0
  end
end
