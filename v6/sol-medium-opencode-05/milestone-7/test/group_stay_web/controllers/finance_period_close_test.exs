defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "validates closes, advances the cutoff, and durably replays results" do
    close = close_operation("close-1", "2026-10-02")

    assert %{"results" => [before_start]} = submit([close])
    assert before_start["code"] == "invalid_period"

    start_reporting("2026-10-01")
    assert %{"results" => [^before_start]} = submit([close])

    assert %{"results" => [invalid_date, before_inception, no_open_day]} =
             submit([
               close_operation("invalid-date", "not-a-date"),
               close_operation("before-inception", "2026-09-30"),
               close_operation("no-open-day", "9999-12-31")
             ])

    assert invalid_date["code"] == "invalid_period"
    assert before_inception["code"] == "invalid_period"
    assert no_open_day["code"] == "invalid_period"

    applied_close = close_operation("close-2", "2026-10-02")

    assert %{"results" => [applied]} = submit([applied_close])

    assert applied == %{
             "operation_id" => "close-2",
             "status" => "applied",
             "period_end_on" => "2026-10-02"
           }

    assert %{"results" => [^applied]} = submit([applied_close])

    assert %{"data" => ^applied} =
             get(build_conn(), "/api/v1/operations/close-2") |> json_response(200)

    assert %{"results" => [same, earlier, later]} =
             submit([
               close_operation("same-close", "2026-10-02"),
               close_operation("earlier-close", "2026-10-01"),
               close_operation("later-close", "2026-10-04")
             ])

    assert same["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"
    assert later["status"] == "applied"
    assert report("2026-10-04")["status"] == "closed"
    assert report("2026-10-05")["status"] == "open"
  end

  test "keeps closed reports stable and posts old cash effects as late adjustments" do
    submit([
      open("group", "ams-canal"),
      start_operation("2026-10-01"),
      payment("before-close", "group", 500, "2026-10-02"),
      close_operation("close", "2026-10-02"),
      payment("after-close", "group", 400, "2026-01-01"),
      payment("open-period", "group", 300, "2026-10-04")
    ])

    closed = report("2026-10-02")
    assert closed["status"] == "closed"
    assert cash_entry(closed, "ams-canal")["movements"]["received_cents"] == 500

    first_open = report("2026-10-03")
    cash = cash_entry(first_open, "ams-canal")
    assert cash["movements"] == zero_cash_movements()
    assert cash["closing_held_cents"] == 900

    assert first_open["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_cash_movements() | "received_cents" => 400}
               }
             ],
             "credit" => zero_credit_movements()
           }

    fourth = report("2026-10-04")
    assert cash_entry(fourth, "ams-canal")["movements"]["received_cents"] == 300
    assert fourth["late_adjustments"] == empty_late_adjustments()

    submit([close_operation("later-close", "2026-10-10")])
    assert report("2026-10-02") == closed
    assert cash_entry(report("2026-10-11"), "ams-canal")["closing_held_cents"] == 1_200
  end

  test "preserves signed late classifications with zero net cash effect" do
    submit([
      open("source", "ams-canal"),
      open("destination", "ams-canal"),
      start_operation("2026-10-01"),
      payment("payment", "source", 1_000, "2026-10-01"),
      close_operation("close", "2026-10-02"),
      %{
        "operation_id" => "late-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 500,
        "occurred_on" => "2026-01-01"
      }
    ])

    report = report("2026-10-03")
    late = report["late_adjustments"]["cash"] |> List.first() |> Map.fetch!("movements")
    assert late["transferred_in_cents"] == 500
    assert late["transferred_out_cents"] == 500

    cash = cash_entry(report, "ams-canal")
    assert cash["opening_held_cents"] == 1_000
    assert cash["closing_held_cents"] == 1_000
  end

  test "reports late credit issuance and expiry without changing a closed day" do
    submit([
      open("seed", "ams-canal"),
      payment("payment", "seed", 1_000, "2024-01-01"),
      start_operation("2026-10-01"),
      close_operation("close", "2026-10-02")
    ])

    closed = report("2026-10-02")

    submit([
      %{
        "operation_id" => "late-credit",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2024-01-02",
        "refund_method" => "hotel_credit"
      }
    ])

    assert report("2026-10-02") == closed

    first_open = report("2026-10-03")
    assert first_open["credit"]["movements"] == zero_credit_movements()

    assert first_open["late_adjustments"]["credit"] == %{
             zero_credit_movements()
             | "issued_cents" => 1_100,
               "expired_cents" => 1_100
           }

    assert first_open["credit"]["closing_liability_cents"] == 0
  end

  test "does not rewrite a closed automatic expiry when credit is applied later" do
    submit([
      open("seed", "ams-canal"),
      start_operation("2026-10-01"),
      payment("payment", "seed", 1_000, "2026-10-02"),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2026-10-03",
        "refund_method" => "hotel_credit"
      },
      open("credit-group", "berlin-mitte"),
      close_operation("close", "2027-10-04")
    ])

    closed_expiry = report("2027-10-04")
    assert closed_expiry["credit"]["movements"]["expired_cents"] == 1_100

    submit([
      %{
        "operation_id" => "late-application",
        "type" => "apply_hotel_credit",
        "group_id" => "credit-group",
        "amount_cents" => 1_100,
        "occurred_on" => "2026-10-04"
      }
    ])

    assert report("2027-10-04") == closed_expiry

    first_open = report("2027-10-05")
    assert first_open["late_adjustments"]["credit"]["expired_cents"] == -1_100
    assert first_open["credit"]["opening_liability_cents"] == 0
    assert first_open["credit"]["closing_liability_cents"] == 1_100
  end

  test "does not rewrite closed expiry when late-applied credit is restored" do
    submit([
      open("seed", "ams-canal"),
      start_operation("2026-10-01"),
      payment("payment", "seed", 1_000, "2026-10-02"),
      %{
        "operation_id" => "issue-credit",
        "type" => "cancel_group",
        "group_id" => "seed",
        "occurred_on" => "2026-10-03",
        "refund_method" => "hotel_credit"
      },
      open("credit-group", "berlin-mitte"),
      close_operation("expiry-close", "2027-10-04"),
      %{
        "operation_id" => "late-application",
        "type" => "apply_hotel_credit",
        "group_id" => "credit-group",
        "amount_cents" => 1_100,
        "occurred_on" => "2026-10-04"
      },
      close_operation("application-close", "2027-10-05")
    ])

    closed_expiry = report("2027-10-04")
    closed_application = report("2027-10-05")
    assert closed_application["late_adjustments"]["credit"]["expired_cents"] == -1_100

    submit([
      %{
        "operation_id" => "late-restoration",
        "type" => "cancel_group",
        "group_id" => "credit-group",
        "occurred_on" => "2026-10-05"
      }
    ])

    assert report("2027-10-04") == closed_expiry
    assert report("2027-10-05") == closed_application

    restoration = report("2027-10-06")
    assert restoration["credit"]["movements"] == zero_credit_movements()
    assert restoration["late_adjustments"]["credit"]["expired_cents"] == 1_100
    assert restoration["credit"]["closing_liability_cents"] == 0
  end

  defp submit(operations) do
    post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cash_entry(report, property_id),
    do: Enum.find(report["cash"], &(&1["property_id"] == property_id))

  defp start_reporting(date), do: submit([start_operation(date)])

  defp start_operation(date) do
    %{
      "operation_id" => "start-reporting",
      "type" => "start_finance_reporting",
      "starts_on" => date
    }
  end

  defp close_operation(operation_id, date) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => date
    }
  end

  defp open(group_id, property_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => "guest-1",
      "property_id" => property_id,
      "arrival_on" => "2027-12-10",
      "departure_on" => "2027-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 20_000}]
    }
  end

  defp payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp empty_late_adjustments,
    do: %{"cash" => [], "credit" => zero_credit_movements()}

  defp zero_cash_movements do
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
end
