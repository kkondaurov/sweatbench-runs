defmodule GroupStayWeb.CloseFinancePeriodTest do
  use GroupStayWeb.ConnCase

  defp cash_for(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp late_cash_for(report, property_id) do
    Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
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

  describe "closing through a date" do
    test "an applied close returns exactly operation_id, status, and period_end_on", %{
      conn: conn
    } do
      open_group_fixture(conn)
      start_finance_reporting(conn)

      assert close_finance_period(conn) == %{
               "operation_id" => "op-close-period",
               "status" => "applied",
               "period_end_on" => "2026-11-15"
             }
    end

    test "reports through the cutoff are closed and later reports stay open", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 9500)
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      assert daily_report_data(conn, "2026-11-01")["status"] == "closed"
      assert daily_report_data(conn, "2026-11-14")["status"] == "closed"
      assert daily_report_data(conn, "2026-11-15")["status"] == "closed"
      assert daily_report_data(conn, "2026-11-16")["status"] == "open"
    end

    test "a close before reporting has started is rejected", %{conn: conn} do
      open_group_fixture(conn)

      assert close_finance_period(conn) == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "a close before starts_on is rejected", %{conn: conn} do
      start_finance_reporting(conn)

      result = close_finance_period(conn, %{"period_end_on" => "2026-10-31"})

      assert result == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert daily_report_data(conn, "2026-11-01")["status"] == "open"
    end

    test "an invalid or missing period_end_on is rejected", %{conn: conn} do
      start_finance_reporting(conn)

      invalid = close_finance_period(conn, %{"period_end_on" => "not-a-date"})

      assert invalid == %{
               "operation_id" => "op-close-period",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      %{"results" => [missing]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-close-missing",
            "type" => "close_finance_period",
            "occurred_on" => "2026-11-30"
          }
        ])

      assert missing["status"] == "rejected"
      assert missing["code"] == "invalid_period"
    end

    test "a close without occurred_on is an invalid operation", %{conn: conn} do
      start_finance_reporting(conn)

      %{"results" => [result]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-close",
            "type" => "close_finance_period",
            "period_end_on" => "2026-11-15"
          }
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end

    test "a later close must be strictly later than the latest successful close", %{conn: conn} do
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      same =
        close_finance_period(conn, %{
          "operation_id" => "op-close-same",
          "period_end_on" => "2026-11-15"
        })

      assert same == %{
               "operation_id" => "op-close-same",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      earlier =
        close_finance_period(conn, %{
          "operation_id" => "op-close-earlier",
          "period_end_on" => "2026-11-10"
        })

      assert earlier["status"] == "rejected"
      assert earlier["code"] == "invalid_period"

      later =
        close_finance_period(conn, %{
          "operation_id" => "op-close-later",
          "period_end_on" => "2026-11-20"
        })

      assert later == %{
               "operation_id" => "op-close-later",
               "status" => "applied",
               "period_end_on" => "2026-11-20"
             }

      assert daily_report_data(conn, "2026-11-20")["status"] == "closed"
      assert daily_report_data(conn, "2026-11-21")["status"] == "open"
    end

    test "a close on starts_on is valid", %{conn: conn} do
      start_finance_reporting(conn)

      assert %{"status" => "applied"} =
               close_finance_period(conn, %{"period_end_on" => "2026-11-01"})

      assert daily_report_data(conn, "2026-11-01")["status"] == "closed"
      assert daily_report_data(conn, "2026-11-02")["status"] == "open"
    end

    test "a replay of an applied close returns its exact stored result", %{conn: conn} do
      start_finance_reporting(conn)
      first = close_finance_period(conn)
      assert first["status"] == "applied"

      # Even after a later close has moved the cutoff on, the replay returns
      # the stored result without re-evaluating the close.
      assert %{"status" => "applied"} =
               close_finance_period(conn, %{
                 "operation_id" => "op-close-later",
                 "period_end_on" => "2026-11-20"
               })

      assert close_finance_period(conn) == first
    end

    test "reusing the close identifier with a different payload is a conflict", %{conn: conn} do
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      conflict = close_finance_period(conn, %{"period_end_on" => "2026-11-20"})

      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"

      # The conflicting cutoff was not applied.
      assert daily_report_data(conn, "2026-11-20")["status"] == "open"
    end

    test "a rejected close is remembered like other rejections", %{conn: conn} do
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      rejected =
        close_finance_period(conn, %{
          "operation_id" => "op-close-old",
          "period_end_on" => "2026-11-10"
        })

      assert rejected["code"] == "invalid_period"

      retry =
        close_finance_period(conn, %{
          "operation_id" => "op-close-old",
          "period_end_on" => "2026-11-10"
        })

      assert retry == rejected
    end

    test "closing does not change group state or revisions", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 9500)
      start_finance_reporting(conn)
      before = group_data(conn, "group-81")

      assert %{"status" => "applied"} = close_finance_period(conn)

      assert group_data(conn, "group-81") == before
      assert ledger_data(conn)["cash_held_cents"] == 9500
    end

    test "reports before starts_on remain unavailable after a close", %{conn: conn} do
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      response =
        Phoenix.ConnTest.dispatch(
          conn,
          GroupStayWeb.Endpoint,
          :get,
          "/api/v1/finance/daily-report",
          %{"date" => "2026-10-31"}
        )

      assert Phoenix.ConnTest.json_response(response, 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end
  end

  describe "posting after a close" do
    setup %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 9500)
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)
      %{conn: conn}
    end

    test "an old-dated operation posts on the first open day", %{conn: conn} do
      pay_group(conn, "group-81", 500, %{
        "operation_id" => "op-pay-backdated",
        "occurred_on" => "2026-11-03"
      })

      closed = daily_report_data(conn, "2026-11-15")
      assert closed["status"] == "closed"
      assert cash_for(closed, "ams-canal")["closing_held_cents"] == 9500
      assert cash_for(closed, "ams-canal")["movements"]["received_cents"] == 0
      assert closed["late_adjustments"]["cash"] == []

      first_open = daily_report_data(conn, "2026-11-16")
      assert cash_for(first_open, "ams-canal")["movements"]["received_cents"] == 0
      assert cash_for(first_open, "ams-canal")["closing_held_cents"] == 10_000

      assert [late] = first_open["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert late["movements"]["received_cents"] == 500

      assert ledger_data(conn)["cash_held_cents"] == 10_000
    end

    test "an operation whose occurred_on is already open keeps that date", %{conn: conn} do
      pay_group(conn, "group-81", 500, %{
        "operation_id" => "op-pay-open",
        "occurred_on" => "2026-11-20"
      })

      report = daily_report_data(conn, "2026-11-20")
      assert cash_for(report, "ams-canal")["movements"]["received_cents"] == 500
      assert report["late_adjustments"]["cash"] == []

      # Nothing posted on the first open day.
      assert cash_for(daily_report_data(conn, "2026-11-16"), "ams-canal")["closing_held_cents"] ==
               9500
    end

    test "an operation keeps the posting date chosen when it commits", %{conn: conn} do
      # Posts while 2026-11-20 is still open.
      pay_group(conn, "group-81", 500, %{
        "operation_id" => "op-pay-before",
        "occurred_on" => "2026-11-20"
      })

      # A later close passes over the posting date without moving it.
      assert %{"status" => "applied"} =
               close_finance_period(conn, %{
                 "operation_id" => "op-close-later",
                 "period_end_on" => "2026-11-30"
               })

      report = daily_report_data(conn, "2026-11-20")
      assert report["status"] == "closed"
      assert cash_for(report, "ams-canal")["movements"]["received_cents"] == 500
      assert report["late_adjustments"]["cash"] == []

      # An old-dated operation after the second close posts on 2026-12-01.
      pay_group(conn, "group-81", 300, %{
        "operation_id" => "op-pay-after",
        "occurred_on" => "2026-11-20"
      })

      later = daily_report_data(conn, "2026-12-01")
      assert cash_for(later, "ams-canal")["movements"]["received_cents"] == 500
      assert late_cash_for(later, "ams-canal")["movements"]["received_cents"] == 300
      assert cash_for(later, "ams-canal")["closing_held_cents"] == 10_300
    end

    test "operations around a close in one batch see the committed close", %{conn: conn} do
      # The setup close is through 2026-11-15, so 2026-11-16 is open when the
      # batch starts.
      %{"results" => results} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-pay-before",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-16",
            "group_id" => "group-81",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "op-close-second",
            "type" => "close_finance_period",
            "occurred_on" => "2026-11-30",
            "period_end_on" => "2026-11-20"
          },
          %{
            "operation_id" => "op-pay-after",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-16",
            "group_id" => "group-81",
            "amount_cents" => 1000
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]

      # The operation immediately before the close posted into the period
      # being closed.
      closed = daily_report_data(conn, "2026-11-20")
      assert closed["status"] == "closed"
      assert cash_for(closed, "ams-canal")["movements"]["received_cents"] == 1000
      assert closed["late_adjustments"]["cash"] == []

      # The old-dated operation immediately after the close posted on the
      # first open day; the cumulative ordinary total keeps the on-time
      # payment only.
      first_open = daily_report_data(conn, "2026-11-21")
      assert cash_for(first_open, "ams-canal")["movements"]["received_cents"] == 1000
      assert late_cash_for(first_open, "ams-canal")["movements"]["received_cents"] == 1000
      assert cash_for(first_open, "ams-canal")["closing_held_cents"] == 11_500
    end

    test "the posting rule changes only finance reporting", %{conn: conn} do
      result =
        pay_group(conn, "group-81", 500, %{
          "operation_id" => "op-pay-backdated",
          "occurred_on" => "2026-11-03"
        })

      assert result["status"] == "applied"
      assert result["revision"] == 3
      assert result["outstanding_deposit_cents"] == 9500

      data = group_data(conn, "group-81")
      assert data["deposit_paid_cents"] == 10_000
      assert data["revision"] == 3

      assert ledger_data(conn)["cash_held_cents"] == 10_000

      statement =
        conn
        |> Phoenix.ConnTest.dispatch(
          GroupStayWeb.Endpoint,
          :get,
          "/api/v1/payments/op-pay-backdated"
        )
        |> Phoenix.ConnTest.json_response(200)
        |> Map.fetch!("data")

      assert statement["held_cents"] == 500

      conn = get(conn, ~p"/api/v1/operations/op-pay-backdated")
      assert json_response(conn, 200) == %{"data" => result}
    end
  end

  describe "published reports stay stable" do
    test "closed reports are byte-for-byte stable across later operations and closes", %{
      conn: conn
    } do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 9500)
      start_finance_reporting(conn)

      # A settlement whose issued credit expires inside the closed period.
      assert %{"status" => "applied"} =
               cancel_group(conn, "group-81", "2026-11-02", %{
                 "refund_method" => "hotel_credit"
               })

      assert %{"status" => "applied"} =
               close_finance_period(conn, %{"period_end_on" => "2027-11-30"})

      snapshots = %{
        "2026-11-01" => daily_report_data(conn, "2026-11-01"),
        "2026-11-02" => daily_report_data(conn, "2026-11-02"),
        "2027-11-03" => daily_report_data(conn, "2027-11-03")
      }

      assert snapshots["2026-11-02"]["status"] == "closed"
      assert snapshots["2027-11-03"]["status"] == "closed"
      # The derived expiry of the issued credit is visible in the closed day.
      assert snapshots["2027-11-03"]["credit"]["movements"]["expired_cents"] == 10_450
      assert snapshots["2027-11-03"]["credit"]["closing_liability_cents"] == 0

      # Later operations, including a backdated one, and a later close.
      open_group_at(conn, "group-82", "rotx-dam")

      pay_group(conn, "group-82", 1000, %{
        "operation_id" => "op-pay-late",
        "occurred_on" => "2026-11-05"
      })

      assert %{"status" => "applied"} =
               close_finance_period(conn, %{
                 "operation_id" => "op-close-later",
                 "period_end_on" => "2027-12-15"
               })

      for {date, snapshot} <- snapshots do
        assert daily_report_data(conn, date) == snapshot,
               "report for #{date} changed after later operations and a later close"
      end

      # The backdated payment posted on the first open day after the close.
      first_open = daily_report_data(conn, "2027-12-01")
      assert late_cash_for(first_open, "rotx-dam")["movements"]["received_cents"] == 1000
    end

    test "reading closed reports repeatedly never changes them", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 9500)
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      first = daily_report_data(conn, "2026-11-10")
      assert daily_report_data(conn, "2026-11-10") == first
      assert daily_report_data(conn, "2026-11-10") == first
    end
  end

  describe "late adjustments" do
    test "every report carries a late_adjustments block", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 9500)
      start_finance_reporting(conn)

      report = daily_report_data(conn, "2026-11-01")

      assert report["late_adjustments"] == %{
               "cash" => [],
               "credit" => zero_credit_movements()
             }
    end

    test "a zero-net correction keeps its signed classifications", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 5000)
      start_finance_reporting(conn)

      # The refund posts inside the period that will be closed.
      assert %{"status" => "applied"} = cancel_group(conn, "group-81", "2026-11-02")
      assert %{"status" => "applied"} = close_finance_period(conn)

      # Charging back the refunded payment is backdated into the closed
      # period, so it posts on the first open day as a late adjustment.
      %{"results" => [chargeback]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-10",
            "payment_operation_id" => "op-pay-group-81"
          }
        ])

      assert chargeback["status"] == "applied"
      assert chargeback["charged_back_cents"] == 5000

      report = daily_report_data(conn, "2026-11-16")
      cash = cash_for(report, "ams-canal")

      # Ordinary columns keep the on-time refund only.
      assert cash["opening_held_cents"] == 5000
      assert cash["movements"]["refunded_cents"] == 5000
      assert cash["movements"]["charged_back_cents"] == 0

      late = late_cash_for(report, "ams-canal")

      assert late["movements"] == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => -5000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 5000
             }

      # The day's total movement is ordinary plus late; the closing uses both.
      assert cash["closing_held_cents"] == 0

      ledger = ledger_data(conn)
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "late cash entries are ordered by property_id and omit all-zero properties", %{
      conn: conn
    } do
      open_group_fixture(conn)
      open_group_at(conn, "group-82", "damrak")
      open_group_at(conn, "group-83", "rotx-dam")

      pay_group(conn, "group-81", 5000)
      pay_group(conn, "group-82", 3000)

      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      submit_batch(conn, [
        %{
          "operation_id" => "op-pay-rotx",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-03",
          "group_id" => "group-83",
          "amount_cents" => 1000
        },
        %{
          "operation_id" => "op-pay-ams",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-03",
          "group_id" => "group-81",
          "amount_cents" => 500
        }
      ])

      report = daily_report_data(conn, "2026-11-16")

      # damrak had no late movement and is omitted; rotx-dam had none of its
      # ordinary movements moved and appears only in the late block through
      # its new payment.
      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "rotx-dam"]

      assert late_cash_for(report, "ams-canal")["movements"]["received_cents"] == 500
      assert late_cash_for(report, "rotx-dam")["movements"]["received_cents"] == 1000
    end

    test "late credit movements are reported in the credit object", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 5000)
      start_finance_reporting(conn)

      assert %{"status" => "applied"} =
               cancel_group(conn, "group-81", "2026-11-02", %{"refund_method" => "hotel_credit"})

      assert %{"status" => "applied"} = close_finance_period(conn)

      # Charging back backdated into the closed period revokes entitlement on
      # the first open day.
      submit_batch(conn, [
        %{
          "operation_id" => "op-chargeback",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-10",
          "payment_operation_id" => "op-pay-group-81"
        }
      ])

      report = daily_report_data(conn, "2026-11-16")

      assert report["credit"]["movements"]["issued_cents"] == 5500
      assert report["credit"]["movements"]["revoked_cents"] == 0

      assert report["late_adjustments"]["credit"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 500,
               "absorbed_cents" => 0
             }

      assert report["credit"]["closing_liability_cents"] == 5000
      assert ledger_data(conn)["credit_liability_cents"] == 5000
    end

    test "a late application into a lot expiring inside the closed period reconciles", %{
      conn: conn
    } do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 5000)
      start_finance_reporting(conn)

      # The lot issued here expires on 2027-11-02, inside the closed period.
      assert %{"status" => "applied"} =
               cancel_group(conn, "group-81", "2026-11-02", %{
                 "refund_method" => "hotel_credit"
               })

      open_group_at(conn, "group-82", "rotx-dam")

      assert %{"status" => "applied"} =
               close_finance_period(conn, %{"period_end_on" => "2027-11-30"})

      closed_expiry = daily_report_data(conn, "2027-11-03")
      assert closed_expiry["credit"]["movements"]["expired_cents"] == 5500

      # Backdated while the lot was still available, so the domain applies it;
      # the posting moves past the lot's expiry.
      submit_batch(conn, [
        %{
          "operation_id" => "op-apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-10-01",
          "group_id" => "group-82",
          "amount_cents" => 2000
        }
      ])

      report = daily_report_data(conn, "2027-12-01")

      # The applied credit remains liability while the group holds it.
      assert report["credit"]["closing_liability_cents"] == 2000
      assert ledger_data(conn, %{"on" => "2027-12-01"})["credit_liability_cents"] == 2000

      assert report["late_adjustments"]["credit"]["expired_cents"] == -2000

      # The closed expiry day is unchanged.
      assert daily_report_data(conn, "2027-11-03") == closed_expiry
    end

    test "a backdated settlement whose lot is already expired at posting reconciles", %{
      conn: conn
    } do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 5000)
      start_finance_reporting(conn)

      assert %{"status" => "applied"} = close_finance_period(conn)

      open_group_at(conn, "group-82", "rotx-dam")
      pay_group(conn, "group-82", 3000)

      # Occurred more than a year before the posting date: the issued lot is
      # already expired when the movement posts on the first open day.
      submit_batch(conn, [
        %{
          "operation_id" => "op-cancel-82",
          "type" => "cancel_group",
          "occurred_on" => "2025-01-01",
          "group_id" => "group-82",
          "refund_method" => "hotel_credit"
        }
      ])

      report = daily_report_data(conn, "2026-11-16")

      assert report["late_adjustments"]["credit"]["issued_cents"] == 3300
      assert report["late_adjustments"]["credit"]["expired_cents"] == 3300
      assert report["credit"]["closing_liability_cents"] == 0
      assert ledger_data(conn, %{"on" => "2026-11-16"})["credit_liability_cents"] == 0
    end

    test "a late consumption of applied credit is reported", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 5000)
      start_finance_reporting(conn)

      assert %{"status" => "applied"} =
               cancel_group(conn, "group-81", "2026-11-02", %{"refund_method" => "hotel_credit"})

      open_group_at(conn, "group-82", "rotx-dam", %{
        "arrival_on" => "2026-11-25",
        "departure_on" => "2026-11-28"
      })

      submit_batch(conn, [
        %{
          "operation_id" => "op-apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-16",
          "group_id" => "group-82",
          "amount_cents" => 2000
        }
      ])

      assert %{"status" => "applied"} =
               close_finance_period(conn, %{
                 "operation_id" => "op-close-second",
                 "period_end_on" => "2026-11-20"
               })

      # Cancelling on 2026-11-19 is non-refundable (arrival 2026-11-25), so
      # the applied credit is consumed; the backdated date falls inside the
      # closed period and posts on the first open day.
      assert %{"status" => "applied"} = cancel_group(conn, "group-82", "2026-11-19")

      report = daily_report_data(conn, "2026-11-21")
      assert report["credit"]["movements"]["consumed_cents"] == 0
      assert report["late_adjustments"]["credit"]["consumed_cents"] == 2000
      assert report["credit"]["closing_liability_cents"] == 3500
      assert ledger_data(conn)["credit_liability_cents"] == 3500
    end

    test "movements that posted on time into a later-closed period stay ordinary", %{
      conn: conn
    } do
      open_group_fixture(conn)
      start_finance_reporting(conn)

      # Posts on 2026-11-10 while the day is still open.
      pay_group(conn, "group-81", 1000, %{
        "operation_id" => "op-pay-on-time",
        "occurred_on" => "2026-11-10"
      })

      # The close passes over the posting date afterward.
      assert %{"status" => "applied"} = close_finance_period(conn)

      report = daily_report_data(conn, "2026-11-15")
      assert report["status"] == "closed"
      assert cash_for(report, "ams-canal")["movements"]["received_cents"] == 1000
      assert report["late_adjustments"]["cash"] == []
    end

    test "closing equations hold across ordinary and late movements", %{conn: conn} do
      open_group_fixture(conn)
      open_group_at(conn, "group-82", "rotx-dam")
      pay_group(conn, "group-81", 9000)
      pay_group(conn, "group-82", 4000)
      start_finance_reporting(conn)
      assert %{"status" => "applied"} = close_finance_period(conn)

      submit_batch(conn, [
        %{
          "operation_id" => "op-transfer-late",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-11-05",
          "source_group_id" => "group-81",
          "destination_group_id" => "group-82",
          "amount_cents" => 1500
        },
        %{
          "operation_id" => "op-pay-open",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "amount_cents" => 500
        }
      ])

      report = daily_report_data(conn, "2026-11-20")

      late_by_property =
        Map.new(
          Enum.map(report["late_adjustments"]["cash"], fn entry ->
            {entry["property_id"], entry["movements"]}
          end)
        )

      for cash <- report["cash"] do
        m = cash["movements"]
        late = Map.get(late_by_property, cash["property_id"], %{})

        total = fn key ->
          m["#{key}_cents"] + Map.get(late, "#{key}_cents", 0)
        end

        assert cash["closing_held_cents"] ==
                 cash["opening_held_cents"] +
                   total.("received") +
                   total.("transferred_in") -
                   total.("transferred_out") -
                   total.("refunded") -
                   total.("retained") -
                   total.("converted_to_credit") -
                   total.("reduced") -
                   total.("charged_back")
      end

      total_closing = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()
      assert total_closing == ledger_data(conn)["cash_held_cents"]

      credit = report["credit"]
      late_credit = report["late_adjustments"]["credit"]

      assert credit["closing_liability_cents"] ==
               credit["opening_liability_cents"] +
                 credit["movements"]["issued_cents"] + late_credit["issued_cents"] -
                 credit["movements"]["expired_cents"] - late_credit["expired_cents"] -
                 credit["movements"]["consumed_cents"] - late_credit["consumed_cents"] -
                 credit["movements"]["revoked_cents"] - late_credit["revoked_cents"] -
                 credit["movements"]["absorbed_cents"] - late_credit["absorbed_cents"]

      assert credit["closing_liability_cents"] == ledger_data(conn)["credit_liability_cents"]
    end
  end
end
