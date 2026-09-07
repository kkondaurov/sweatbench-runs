defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp post_operations(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_group(id \\ "group") do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-01",
      "departure_on" => "2026-12-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 50_000}]
    }
  end

  defp start_reporting do
    %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-02-01"
    }
  end

  defp close(id, date) do
    %{
      "operation_id" => id,
      "type" => "close_finance_period",
      "period_end_on" => date
    }
  end

  defp payment(id, date, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => date,
      "group_id" => "group",
      "amount_cents" => amount
    }
  end

  test "validates advancing periods and durably replays the exact close result" do
    before_start = close("too-soon", "2026-02-01")

    assert [%{"status" => "rejected", "code" => "invalid_period"} = rejection] =
             post_operations([before_start])

    post_operations([start_reporting()])

    # A rejected operation is still replayed even after domain state changes.
    assert post_operations([before_start]) == [rejection]

    assert [
             %{"code" => "invalid_period"},
             %{"code" => "invalid_period"},
             applied
           ] =
             post_operations([
               close("bad-date", "not-a-date"),
               close("before-inception", "2026-01-31"),
               close("close-1", "2026-02-02")
             ])

    assert applied == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2026-02-02"
           }

    assert post_operations([close("close-1", "2026-02-02")]) == [applied]

    assert [%{"code" => "operation_id_conflict"}] =
             post_operations([close("close-1", "2026-02-03")])

    assert [%{"code" => "invalid_period"}, %{"code" => "invalid_period"}] =
             post_operations([
               close("duplicate-cutoff", "2026-02-02"),
               close("earlier-cutoff", "2026-02-01")
             ])

    assert report("2026-02-02")["status"] == "closed"
    assert report("2026-02-03")["status"] == "open"
  end

  test "batch ordering fixes posting dates and later closes never rewrite published reports" do
    post_operations([
      open_group(),
      start_reporting(),
      payment("before-close", "2026-02-01", 1_000),
      close("close-1", "2026-02-01"),
      payment("late-payment", "2026-01-15", 2_000)
    ])

    first_closed_report = report("2026-02-01")
    assert first_closed_report["status"] == "closed"
    assert hd(first_closed_report["cash"])["movements"]["received_cents"] == 1_000
    assert first_closed_report["late_adjustments"]["cash"] == []

    open_report = report("2026-02-02")
    assert open_report["status"] == "open"
    assert hd(open_report["cash"])["movements"]["received_cents"] == 0

    assert open_report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "hotel",
               "movements" => %{
                 "received_cents" => 2_000,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
           ]

    assert hd(open_report["cash"])["closing_held_cents"] == 3_000

    post_operations([
      close("close-2", "2026-02-02"),
      payment("next-late-payment", "2026-01-16", 1_000)
    ])

    assert report("2026-02-01") == first_closed_report
    assert report("2026-02-02") == Map.put(open_report, "status", "closed")

    next_report = report("2026-02-03")
    assert next_report["status"] == "open"
    assert hd(next_report["cash"])["opening_held_cents"] == 3_000
    assert hd(next_report["cash"])["closing_held_cents"] == 4_000
    assert hd(next_report["late_adjustments"]["cash"])["movements"]["received_cents"] == 1_000
  end

  test "late adjustments retain signed zero-net classifications" do
    post_operations([
      open_group(),
      payment("cash", "2026-01-02", 5_000),
      start_reporting(),
      %{
        "operation_id" => "refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-01",
        "group_id" => "group"
      },
      close("close", "2026-02-01"),
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-01-20",
        "payment_operation_id" => "cash"
      }
    ])

    data = report("2026-02-02")
    assert [cash] = data["cash"]
    assert cash["opening_held_cents"] == 0
    assert cash["closing_held_cents"] == 0
    assert cash["movements"]["refunded_cents"] == 0
    assert cash["movements"]["charged_back_cents"] == 0

    assert [late] = data["late_adjustments"]["cash"]
    assert late["movements"]["refunded_cents"] == -5_000
    assert late["movements"]["charged_back_cents"] == 5_000

    assert data["late_adjustments"]["credit"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end

  test "applying credit after its published expiry reverses expiry on the open posting day" do
    origin = open_group("origin")

    destination =
      open_group()
      |> Map.put("rate_plan", "advance_purchase")

    post_operations([
      origin,
      Map.merge(payment("cash", "2026-01-02", 5_000), %{"group_id" => "origin"}),
      start_reporting(),
      %{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-02",
        "group_id" => "origin",
        "refund_method" => "hotel_credit"
      },
      destination,
      close("close", "2027-02-03"),
      %{
        "operation_id" => "late-application",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-02-02",
        "group_id" => "group",
        "amount_cents" => 2_000
      }
    ])

    assert report("2027-02-03")["credit"]["closing_liability_cents"] == 0

    credit = report("2027-02-04")["credit"]
    assert credit["opening_liability_cents"] == 0
    assert credit["movements"]["expired_cents"] == 0
    assert credit["closing_liability_cents"] == 2_000

    assert report("2027-02-04")["late_adjustments"]["credit"]["expired_cents"] == -2_000
  end
end
