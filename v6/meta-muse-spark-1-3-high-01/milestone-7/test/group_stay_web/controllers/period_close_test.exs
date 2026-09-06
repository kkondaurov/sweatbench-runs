defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp report!(date) do
    c = get(build_conn(), "/api/v1/finance/daily-report", %{date: date})
    assert %{"data" => data} = json_response(c, 200)
    data
  end

  test "daily report reconciles held cash and converts, then closes stay stable", %{conn: conn} do
    conn = post_batch(conn, [open_op("pc-g1")])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pc-pay1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "pc-g1",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pc-start",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-11-01"
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pc-pay2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-05",
          "group_id" => "pc-g1",
          "amount_cents" => 1_000
        }
      ])

    assert json_response(c, 200)

    # Opening on starts_on includes the pre-start payment.
    day1 = report!("2026-11-01")
    assert day1["status"] == "open"
    assert day1["date"] == "2026-11-01"
    assert [%{"property_id" => "ams-canal", "opening_held_cents" => 5_000} = e1] = day1["cash"]
    assert e1["closing_held_cents"] == 5_000
    assert e1["movements"]["received_cents"] == 0

    day5 = report!("2026-11-05")
    [e5] = day5["cash"]
    assert e5["opening_held_cents"] == 5_000
    assert e5["movements"]["received_cents"] == 1_000
    assert e5["closing_held_cents"] == 6_000
    assert day5["late_adjustments"]["cash"] == []
    assert day5["late_adjustments"]["credit"]["issued_cents"] == 0

    # Close through 11-10; both days become published.
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pc-close1",
          "type" => "close_finance_period",
          "period_end_on" => "2026-11-10"
        }
      ])

    assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-11-10"}]} =
             json_response(c, 200)

    closed5 = report!("2026-11-05")
    assert closed5["status"] == "closed"
    assert Map.delete(closed5, "status") == Map.delete(day5, "status")

    # An old-dated payment after the close posts on the first open day.
    c =
      post_batch(build_conn(), [
        open_op("pc-g2", %{"operation_id" => "op-open-pc-g2"}),
        %{
          "operation_id" => "pc-pay3",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-20",
          "group_id" => "pc-g2",
          "amount_cents" => 500
        }
      ])

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             json_response(c, 200)

    # Closed day is byte-for-byte stable.
    assert report!("2026-11-05") == closed5

    day11 = report!("2026-11-11")
    assert day11["status"] == "open"
    [e11] = day11["cash"]
    assert e11["movements"]["received_cents"] == 500
    assert e11["closing_held_cents"] == e11["opening_held_cents"] + 500

    [late] = day11["late_adjustments"]["cash"]
    assert late["property_id"] == "ams-canal"
    assert late["movements"]["received_cents"] == 500

    # Ordinary + late equals the total movement.
    assert e11["movements"]["received_cents"] ==
             500 + 0

    # A duplicate close cutoff is rejected; an earlier one too.
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pc-close-dup",
          "type" => "close_finance_period",
          "period_end_on" => "2026-11-10"
        }
      ])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             json_response(c, 200)

    # Retry of the applied close replays exactly.
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pc-close1",
          "type" => "close_finance_period",
          "period_end_on" => "2026-11-10"
        }
      ])

    assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-11-10"}]} =
             json_response(c, 200)
  end

  test "chargeback reversal keeps signed classifications without disappearing", %{conn: conn} do
    conn = post_batch(conn, [open_op("cb-g1")])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cb-pay1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "cb-g1",
          "amount_cents" => 1_000
        },
        %{
          "operation_id" => "cb-start",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-11-01"
        },
        %{
          "operation_id" => "cb-cx",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "cb-g1"
        },
        %{
          "operation_id" => "cb-cb",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-25",
          "payment_operation_id" => "cb-pay1"
        }
      ])

    assert %{"results" => results} = json_response(c, 200)
    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]

    day25 = report!("2026-11-25")
    [e] = day25["cash"]
    assert e["movements"]["refunded_cents"] == -1_000
    assert e["movements"]["charged_back_cents"] == 1_000
  end

  test "close validations and report availability", %{conn: conn} do
    # Before reporting starts: close rejected, report unavailable.
    c =
      post_batch(conn, [
        %{
          "operation_id" => "v-close-early",
          "type" => "close_finance_period",
          "period_end_on" => "2026-11-10"
        }
      ])

    assert %{"results" => [%{"code" => "invalid_period"}]} = json_response(c, 200)

    c = get(build_conn(), "/api/v1/finance/daily-report", %{date: "2026-11-05"})
    assert %{"error" => %{"code" => "report_not_available"}} = json_response(c, 404)

    c = get(build_conn(), "/api/v1/finance/daily-report", %{date: "not-a-date"})
    assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(c, 422)

    c = get(build_conn(), "/api/v1/finance/daily-report")
    assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(c, 422)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "v-bad-close",
          "type" => "close_finance_period",
          "period_end_on" => "nope"
        }
      ])

    assert %{"results" => [%{"code" => "invalid_period"}]} = json_response(c, 200)
  end
end
