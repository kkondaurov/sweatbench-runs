defmodule GroupStayWeb.StartFinanceReportingTest do
  use GroupStayWeb.ConnCase

  test "the first applied start enables reporting with the current state as opening", %{
    conn: conn
  } do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 9500)

    result =
      start_finance_reporting(conn, %{
        "operation_id" => "op-start",
        "occurred_on" => "2026-11-01",
        "starts_on" => "2026-11-01"
      })

    assert result == %{
             "operation_id" => "op-start",
             "status" => "applied",
             "starts_on" => "2026-11-01"
           }

    report = daily_report_data(conn, "2026-11-01")
    assert report["date"] == "2026-11-01"
    assert report["status"] == "open"

    assert [cash] = report["cash"]
    assert cash["property_id"] == "ams-canal"
    assert cash["opening_held_cents"] == 9500
    assert cash["closing_held_cents"] == 9500

    assert cash["movements"] == %{
             "received_cents" => 0,
             "transferred_in_cents" => 0,
             "transferred_out_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert report["credit"] == %{
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
  end

  test "the opening includes committed operations whose occurred_on is on or after starts_on", %{
    conn: conn
  } do
    open_group_fixture(conn)
    pay_group(conn, "group-81", 5000, %{"occurred_on" => "2026-12-15"})

    assert %{"status" => "applied"} =
             start_finance_reporting(conn, %{
               "occurred_on" => "2026-11-01",
               "starts_on" => "2026-11-01"
             })

    report = daily_report_data(conn, "2026-11-01")
    assert [cash] = report["cash"]
    assert cash["opening_held_cents"] == 5000
    assert cash["movements"]["received_cents"] == 0
    assert cash["closing_held_cents"] == 5000
  end

  test "in one batch, operations before the start open and operations after it move", %{
    conn: conn
  } do
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

    %{"results" => results} = submit_batch(conn, operations)
    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]

    opening_report = daily_report_data(conn, "2026-11-01")
    assert [opening_cash] = opening_report["cash"]
    assert opening_cash["opening_held_cents"] == 9500
    assert opening_cash["movements"]["received_cents"] == 0
    assert opening_cash["closing_held_cents"] == 9500

    report = daily_report_data(conn, "2026-11-02")
    assert [cash] = report["cash"]
    assert cash["opening_held_cents"] == 9500
    assert cash["movements"]["received_cents"] == 1000
    assert cash["closing_held_cents"] == 10_500
  end

  test "a different start operation is rejected once reporting has started", %{conn: conn} do
    assert %{"status" => "applied"} = start_finance_reporting(conn)

    result =
      start_finance_reporting(conn, %{
        "operation_id" => "op-start-2",
        "starts_on" => "2026-12-01"
      })

    assert result == %{
             "operation_id" => "op-start-2",
             "status" => "rejected",
             "code" => "reporting_already_started"
           }
  end

  test "a retry of the original start returns its stored result", %{conn: conn} do
    first = start_finance_reporting(conn)
    assert first["status"] == "applied"

    retry = start_finance_reporting(conn)
    assert retry == first
  end

  test "reusing the start identifier with a different payload is a conflict", %{conn: conn} do
    assert %{"status" => "applied"} = start_finance_reporting(conn)

    conflict = start_finance_reporting(conn, %{"starts_on" => "2026-12-01"})

    assert conflict["status"] == "rejected"
    assert conflict["code"] == "operation_id_conflict"
  end

  test "an invalid or missing starts_on is rejected as invalid_reporting_date", %{conn: conn} do
    invalid = start_finance_reporting(conn, %{"starts_on" => "not-a-date"})

    assert invalid == %{
             "operation_id" => "op-start-reporting",
             "status" => "rejected",
             "code" => "invalid_reporting_date"
           }

    missing =
      submit_batch(conn, [
        %{
          "operation_id" => "op-start-missing",
          "type" => "start_finance_reporting",
          "occurred_on" => "2026-11-01"
        }
      ])

    assert %{"results" => [missing_result]} = missing
    assert missing_result["status"] == "rejected"
    assert missing_result["code"] == "invalid_reporting_date"

    # Reporting never started, so the report remains unavailable.
    response =
      Phoenix.ConnTest.dispatch(
        conn,
        GroupStayWeb.Endpoint,
        :get,
        "/api/v1/finance/daily-report",
        %{"date" => "2026-11-01"}
      )

    assert Phoenix.ConnTest.json_response(response, 404) == %{
             "error" => %{"code" => "report_not_available"}
           }
  end

  test "a start without occurred_on is an invalid operation", %{conn: conn} do
    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-start",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-11-01"
        }
      ])

    assert result["status"] == "rejected"
    assert result["code"] == "invalid_operation"
  end

  test "starting reporting does not change group state or revisions", %{conn: conn} do
    open_group_fixture(conn)
    before = group_data(conn, "group-81")

    assert %{"status" => "applied"} = start_finance_reporting(conn)

    assert group_data(conn, "group-81") == before
  end
end
