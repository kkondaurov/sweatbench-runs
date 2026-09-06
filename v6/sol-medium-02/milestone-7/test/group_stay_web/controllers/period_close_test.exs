defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest",
        "property_id" => "ams",
        "arrival_on" => "2026-12-01",
        "departure_on" => "2026-12-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1_000}]
      },
      overrides
    )
  end

  defp start(id, starts_on) do
    %{"operation_id" => id, "type" => "start_finance_reporting", "starts_on" => starts_on}
  end

  defp close(id, period_end_on) do
    %{"operation_id" => id, "type" => "close_finance_period", "period_end_on" => period_end_on}
  end

  defp pay(id, group_id, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "validates, durably replays, and advances period closes", %{conn: conn} do
    [before_start] = submit(conn, [close("before-start", "2026-01-01")])
    assert before_start["code"] == "invalid_period"

    [missing_date] =
      submit(conn, [%{"operation_id" => "missing", "type" => "close_finance_period"}])

    assert missing_date["code"] == "invalid_period"

    submit(conn, [start("start", "2026-01-10")])

    [before_inception] = submit(conn, [close("too-early", "2026-01-09")])
    assert before_inception["code"] == "invalid_period"

    [closed] = submit(conn, [close("close-1", "2026-01-10")])

    assert closed == %{
             "operation_id" => "close-1",
             "status" => "applied",
             "period_end_on" => "2026-01-10"
           }

    assert submit(conn, [close("close-1", "2026-01-10")]) == [closed]

    [same_cutoff] = submit(conn, [close("close-2", "2026-01-10")])
    [earlier_cutoff] = submit(conn, [close("close-3", "2026-01-09")])
    assert same_cutoff["code"] == "invalid_period"
    assert earlier_cutoff["code"] == "invalid_period"

    [later] = submit(conn, [close("close-4", "2026-01-12")])
    assert later["status"] == "applied"
    assert report(conn, "2026-01-12")["status"] == "closed"
    assert report(conn, "2026-01-13")["status"] == "open"
  end

  test "same-batch operations post on the correct side of a close and closed data stays fixed", %{
    conn: conn
  } do
    [_, _, before, closed, after_close] =
      submit(conn, [
        start("start", "2026-10-01"),
        open("open", "group"),
        pay("before", "group", 100, "2026-10-03"),
        close("close", "2026-10-03"),
        pay("after", "group", 50, "2026-01-01")
      ])

    assert before["status"] == "applied"
    assert closed["status"] == "applied"
    assert after_close["status"] == "applied"

    cutoff_report = report(conn, "2026-10-03")
    assert cutoff_report["status"] == "closed"
    assert hd(cutoff_report["cash"])["movements"]["received_cents"] == 100
    assert cutoff_report["late_adjustments"]["cash"] == []

    first_open = report(conn, "2026-10-04")
    [cash] = first_open["cash"]
    assert cash["opening_held_cents"] == 100
    assert cash["movements"]["received_cents"] == 0
    assert cash["closing_held_cents"] == 150

    assert first_open["late_adjustments"]["cash"] == [
             %{
               "property_id" => "ams",
               "movements" => %{
                 "received_cents" => 50,
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

    submit(conn, [close("later-close", "2026-10-04"), pay("later-pay", "group", 25, "2026-01-01")])

    assert report(conn, "2026-10-03") == cutoff_report
    assert report(conn, "2026-10-04") == %{first_open | "status" => "closed"}
  end

  test "late chargebacks preserve signed zero-net classifications", %{conn: conn} do
    flexible = %{
      "arrival_on" => "2026-04-01",
      "departure_on" => "2026-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]
    }

    submit(conn, [
      start("start", "2026-01-01"),
      open("open", "group", flexible),
      pay("payment", "group", 100, "2026-01-02"),
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-01",
        "group_id" => "group"
      },
      close("close", "2026-02-02"),
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-02-01",
        "payment_operation_id" => "payment"
      }
    ])

    report = report(conn, "2026-02-03")
    [cash] = report["cash"]
    assert cash["opening_held_cents"] == 0
    assert cash["closing_held_cents"] == 0
    assert Enum.all?(cash["movements"], fn {_classification, amount} -> amount == 0 end)

    [late] = report["late_adjustments"]["cash"]
    assert late["movements"]["refunded_cents"] == -100
    assert late["movements"]["charged_back_cents"] == 100
  end

  test "a late credit application reverses the already-published expiry on its posting day", %{
    conn: conn
  } do
    flexible = %{
      "arrival_on" => "2026-04-01",
      "departure_on" => "2026-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]
    }

    submit(conn, [
      start("start", "2026-01-01"),
      open("source-open", "source", flexible),
      pay("source-pay", "source", 100, "2026-01-02"),
      %{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("target-open", "target", %{
        "occurred_on" => "2027-01-01",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 60}]
      }),
      close("close", "2027-02-02"),
      %{
        "operation_id" => "late-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-02-01",
        "group_id" => "target",
        "amount_cents" => 60
      }
    ])

    assert report(conn, "2027-02-02")["credit"]["closing_liability_cents"] == 0

    first_open = report(conn, "2027-02-03")
    assert first_open["credit"]["movements"]["expired_cents"] == 0
    assert first_open["late_adjustments"]["credit"]["expired_cents"] == -60
    assert first_open["credit"]["closing_liability_cents"] == 60
  end

  test "late-issued already-expired credit enters and leaves on the first open day", %{conn: conn} do
    flexible = %{
      "arrival_on" => "2026-04-01",
      "departure_on" => "2026-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]
    }

    submit(conn, [
      start("start", "2026-01-01"),
      open("open", "group", flexible),
      pay("payment", "group", 100, "2026-01-02"),
      close("close", "2027-03-01"),
      %{
        "operation_id" => "late-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-01",
        "group_id" => "group",
        "refund_method" => "hotel_credit"
      }
    ])

    first_open = report(conn, "2027-03-02")
    assert first_open["credit"]["closing_liability_cents"] == 0
    assert first_open["credit"]["movements"]["issued_cents"] == 0

    assert first_open["late_adjustments"]["credit"] == %{
             "issued_cents" => 110,
             "expired_cents" => 110,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end
end
