defmodule GroupStayWeb.FinanceDailyReportTest do
  use GroupStayWeb.ConnCase

  defp get_report(conn, params) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/finance/daily-report",
      params
    )
  end

  test "a missing or invalid date returns invalid_reporting_date", %{conn: conn} do
    missing = get_report(conn, %{})

    assert Phoenix.ConnTest.json_response(missing, 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    invalid = get_report(conn, %{"date" => "yesterday"})

    assert Phoenix.ConnTest.json_response(invalid, 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    invalid_day = get_report(conn, %{"date" => "2026-13-40"})

    assert Phoenix.ConnTest.json_response(invalid_day, 422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }
  end

  test "before reporting has started the report is not available", %{conn: conn} do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 9500)

    response = get_report(conn, %{"date" => "2026-11-01"})

    assert Phoenix.ConnTest.json_response(response, 404) == %{
             "error" => %{"code" => "report_not_available"}
           }
  end

  test "a date before starts_on is not available", %{conn: conn} do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 9500)

    start_finance_reporting(conn, %{
      "occurred_on" => "2026-11-05",
      "starts_on" => "2026-11-05"
    })

    response = get_report(conn, %{"date" => "2026-11-04"})

    assert Phoenix.ConnTest.json_response(response, 404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert %{"date" => "2026-11-05"} = daily_report_data(conn, "2026-11-05")
  end

  test "a property is omitted only when its opening, closing, and movements are zero", %{
    conn: conn
  } do
    open_group_fixture(conn)
    open_group_at(conn, "group-82", "rotx-dam")
    open_group_at(conn, "group-83", "damrak")

    pay_group(conn, "group-81", 5000)
    pay_group(conn, "group-82", 3000)

    start_finance_reporting(conn)

    # group-82 is cancelled refundably, so rotx-dam's movements net to zero
    # but are not all zero; damrak never sees cash and stays omitted.
    assert %{"status" => "applied"} = cancel_group(conn, "group-82", "2026-11-02")

    report = daily_report_data(conn, "2026-11-02")
    assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "rotx-dam"]

    [ams, rotx] = report["cash"]
    assert ams["opening_held_cents"] == 5000
    assert ams["closing_held_cents"] == 5000

    assert rotx["opening_held_cents"] == 3000
    assert rotx["movements"]["received_cents"] == 0
    assert rotx["movements"]["refunded_cents"] == 3000
    assert rotx["closing_held_cents"] == 0
  end

  test "cash entries are ordered by property_id", %{conn: conn} do
    open_group_at(conn, "group-82", "rotx-dam")
    open_group_fixture(conn)
    open_group_at(conn, "group-83", "damrak")

    pay_group(conn, "group-82", 1000)
    pay_group(conn, "group-81", 2000)
    pay_group(conn, "group-83", 3000)

    start_finance_reporting(conn)

    report = daily_report_data(conn, "2026-11-01")
    assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "damrak", "rotx-dam"]
  end

  test "every cash entry satisfies the closing equation", %{conn: conn} do
    open_group_fixture(conn)
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
      }
    ])

    report = daily_report_data(conn, "2026-11-03")

    for cash <- report["cash"] do
      m = cash["movements"]

      assert cash["closing_held_cents"] ==
               cash["opening_held_cents"] +
                 m["received_cents"] +
                 m["transferred_in_cents"] -
                 m["transferred_out_cents"] -
                 m["refunded_cents"] -
                 m["retained_cents"] -
                 m["converted_to_credit_cents"] -
                 m["reduced_cents"] -
                 m["charged_back_cents"]
    end
  end

  test "reading reports never changes reports or domain state", %{conn: conn} do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 9500)
    start_finance_reporting(conn)

    pay_group(conn, "group-81", 500, %{
      "operation_id" => "op-pay-late",
      "occurred_on" => "2026-11-02"
    })

    first = daily_report_data(conn, "2026-11-02")
    ledger_before = ledger_data(conn)

    assert daily_report_data(conn, "2026-11-01") == daily_report_data(conn, "2026-11-01")
    assert daily_report_data(conn, "2026-11-02") == first
    assert ledger_data(conn) == ledger_before
  end

  test "sequential submissions produce the same report as the equivalent batch", %{
    conn: conn
  } do
    # The same history submitted as one batch is asserted in
    # StartFinanceReportingTest to open at 9500 and report received 1000.
    operations = [
      valid_open_operation(),
      %{
        "operation_id" => "op-pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9500
      },
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => "2026-11-01"
      },
      %{
        "operation_id" => "op-pay-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "group-81",
        "amount_cents" => 1000
      }
    ]

    for operation <- operations do
      %{"results" => [result]} = submit_batch(conn, [operation])
      assert result["status"] == "applied"
    end

    report = daily_report_data(conn, "2026-11-02")
    assert [cash] = report["cash"]
    assert cash["opening_held_cents"] == 9500
    assert cash["movements"]["received_cents"] == 1000
    assert cash["closing_held_cents"] == 10_500
  end
end
