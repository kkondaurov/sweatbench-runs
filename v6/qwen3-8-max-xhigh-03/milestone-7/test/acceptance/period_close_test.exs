defmodule GroupStayWeb.PeriodCloseAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of the finance period close: closing publishes every
  report through the cutoff, later operations post their finance effects on
  the first open day and appear there as late adjustments, published days
  stay byte-for-byte stable across later operations, later closes, and
  restarts, and the close changes nothing outside finance reporting.
  """

  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @report_path "/api/v1/finance/daily-report"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
  end

  defp run(conn, operations) do
    submit(conn, operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn |> get("#{@report_path}?date=#{date}") |> json_response(200) |> Map.fetch!("data")
  end

  defp raw_report(conn, date) do
    conn |> get("#{@report_path}?date=#{date}") |> response(200)
  end

  defp report_error(conn, date, status) do
    conn |> get("#{@report_path}?date=#{date}") |> json_response(status)
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp stored_result(conn, operation_id) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
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

  # group-92: same guest, other property.
  defp second_open_op(overrides \\ %{}) do
    Map.merge(
      open_op(%{
        "operation_id" => "op-open-92",
        "group_id" => "group-92",
        "property_id" => "rot-canal",
        "rooms" => [
          %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-d", "nightly_rate_cents" => 12_000}
        ]
      }),
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => "2026-11-01"
      },
      overrides
    )
  end

  defp close_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-close",
        "type" => "close_finance_period",
        "occurred_on" => "2026-11-30",
        "period_end_on" => "2026-11-30"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-03",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp chargeback_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-20",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp late_cash_entry(report, property_id) do
    Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
  end

  defp zero_credit do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  describe "close_finance_period" do
    test "the first applied close reports exactly its fields", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [result] = run(conn, [close_op()])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-11-30"
             }
    end

    test "a close before reporting has started is rejected", %{conn: conn} do
      assert [rejected] = run(conn, [close_op()])

      assert rejected == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert report_error(conn, "2026-11-01", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "a missing or invalid period_end_on is rejected", %{conn: conn} do
      assert [_] = run(conn, [start_op()])

      assert [missing] = run(conn, [Map.delete(close_op(), "period_end_on")])
      assert missing["status"] == "rejected"
      assert missing["code"] == "invalid_period"

      assert [nil_value] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-nil", "period_end_on" => nil})
               ])

      assert nil_value["status"] == "rejected"
      assert nil_value["code"] == "invalid_period"

      assert [invalid] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-bad", "period_end_on" => "tomorrow"})
               ])

      assert invalid["status"] == "rejected"
      assert invalid["code"] == "invalid_period"

      # A rejected close publishes nothing.
      assert report(conn, "2026-11-01")["status"] == "open"
    end

    test "a period_end_on before starts_on is rejected and the start date itself is accepted", %{
      conn: conn
    } do
      assert [_] = run(conn, [start_op()])

      assert [rejected] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-early", "period_end_on" => "2026-10-31"})
               ])

      assert rejected == %{
               "operation_id" => "op-close-early",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert [applied] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-min", "period_end_on" => "2026-11-01"})
               ])

      assert applied["status"] == "applied"
      assert applied["period_end_on"] == "2026-11-01"
      assert report(conn, "2026-11-01")["status"] == "closed"
      assert report(conn, "2026-11-02")["status"] == "open"
    end

    test "a different operation attempting the same or an earlier cutoff is rejected", %{
      conn: conn
    } do
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert [same] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-same", "period_end_on" => "2026-11-30"})
               ])

      assert same == %{
               "operation_id" => "op-close-same",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert [earlier] =
               run(conn, [
                 close_op(%{
                   "operation_id" => "op-close-earlier",
                   "period_end_on" => "2026-11-15"
                 })
               ])

      assert earlier["status"] == "rejected"
      assert earlier["code"] == "invalid_period"

      assert [later] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-later", "period_end_on" => "2026-12-31"})
               ])

      assert later["status"] == "applied"
      assert later["period_end_on"] == "2026-12-31"
    end

    test "replaying an applied close returns its exact stored result without republishing", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [payment_op()])
      assert [first] = run(conn, [close_op()])

      published = raw_report(conn, "2026-11-02")

      assert [retry] = run(conn, [close_op()])
      assert retry == first
      assert stored_result(conn, "op-close") == first

      # The retry does not publish again or move anything.
      assert raw_report(conn, "2026-11-02") == published

      assert cash_entry(report(conn, "2026-11-02"), "ams-canal")["movements"]["received_cents"] ==
               5_000

      # A later close still sees the original cutoff.
      assert [_] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-12-31"})
               ])

      assert [late_retry] = run(conn, [close_op()])
      assert late_retry == first
    end

    test "reusing the close identifier with a different payload conflicts", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert [conflict] = run(conn, [close_op(%{"period_end_on" => "2026-12-31"})])

      assert conflict == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      # The conflict does not move the cutoff.
      assert [applied] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-12-15"})
               ])

      assert applied["status"] == "applied"
    end
  end

  describe "publishing" do
    test "reports through the cutoff are closed and later reports are open", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert report(conn, "2026-11-01")["status"] == "closed"
      assert report(conn, "2026-11-15")["status"] == "closed"
      assert report(conn, "2026-11-30")["status"] == "closed"
      assert report(conn, "2026-12-01")["status"] == "open"
      assert report(conn, "2027-01-01")["status"] == "open"
    end

    test "a closed day without movements is a complete published report", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert report(conn, "2026-11-15") == %{
               "date" => "2026-11-15",
               "status" => "closed",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{"cash" => [], "credit" => zero_credit()}
             }
    end

    test "published reports are byte-for-byte stable across later operations and later closes",
         %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      early = raw_report(conn, "2026-11-02")
      cutoff = raw_report(conn, "2026-11-30")

      # Later operations, including one whose natural date is already closed.
      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-old",
                   "occurred_on" => "2026-11-15",
                   "amount_cents" => 1_000
                 })
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-dec",
                   "occurred_on" => "2026-12-05",
                   "amount_cents" => 700
                 })
               ])

      assert [_] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-12-31"})
               ])

      december = raw_report(conn, "2026-12-05")

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-jan",
                   "occurred_on" => "2027-01-05",
                   "amount_cents" => 400
                 })
               ])

      assert raw_report(conn, "2026-11-02") == early
      assert raw_report(conn, "2026-11-30") == cutoff
      assert raw_report(conn, "2026-12-05") == december

      assert Jason.decode!(early)["data"]["status"] == "closed"
      assert Jason.decode!(december)["data"]["status"] == "closed"

      # The published December day keeps the movement it was published with.
      assert cash_entry(report(conn, "2026-12-05"), "ams-canal")["movements"]["received_cents"] ==
               700
    end

    test "the published value is exactly the report the day had when it closed", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])

      assert [_] =
               run(conn, [payment_op(%{"occurred_on" => "2026-11-10", "amount_cents" => 1_000})])

      open_read = report(conn, "2026-11-10")
      assert open_read["status"] == "open"

      assert [_] = run(conn, [close_op()])

      assert report(conn, "2026-11-10") == Map.put(open_read, "status", "closed")
    end

    test "a second close publishes only the newly closed days", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])

      assert [_] =
               run(conn, [payment_op(%{"occurred_on" => "2026-11-10", "amount_cents" => 1_000})])

      assert [_] = run(conn, [close_op()])
      first_cutoff = raw_report(conn, "2026-11-30")

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-old",
                   "occurred_on" => "2026-11-20",
                   "amount_cents" => 500
                 })
               ])

      assert [_] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-12-31"})
               ])

      # The earlier close's published days are untouched.
      assert raw_report(conn, "2026-11-30") == first_cutoff

      # The newly closed day carries the late movement posted there.
      december_first = report(conn, "2026-12-01")
      assert december_first["status"] == "closed"
      assert late_cash_entry(december_first, "ams-canal")["movements"]["received_cents"] == 500
    end
  end

  describe "posting after a close" do
    test "an operation immediately before a close posts into the period being closed", %{
      conn: conn
    } do
      assert [_, _, _, _] =
               run(conn, [
                 open_op(),
                 start_op(),
                 payment_op(%{"occurred_on" => "2026-11-15"}),
                 close_op()
               ])

      inside = report(conn, "2026-11-15")
      assert inside["status"] == "closed"
      assert cash_entry(inside, "ams-canal")["movements"]["received_cents"] == 5_000
      assert inside["late_adjustments"]["cash"] == []
      assert inside["late_adjustments"]["credit"] == zero_credit()
    end

    test "an old-dated operation immediately after a close posts on the first open day", %{
      conn: conn
    } do
      assert [_, _, _, _] =
               run(conn, [
                 open_op(),
                 start_op(),
                 close_op(),
                 payment_op(%{"operation_id" => "op-pay-old", "occurred_on" => "2026-11-15"})
               ])

      inside = report(conn, "2026-11-15")
      assert inside["status"] == "closed"
      assert inside["cash"] == []
      assert inside["late_adjustments"]["cash"] == []

      first_open = report(conn, "2026-12-01")
      assert first_open["status"] == "open"

      ams = cash_entry(first_open, "ams-canal")
      assert ams["opening_held_cents"] == 0
      assert ams["movements"]["received_cents"] == 0
      assert ams["closing_held_cents"] == 5_000

      assert late_cash_entry(first_open, "ams-canal")["movements"] == %{
               "received_cents" => 5_000,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert first_open["late_adjustments"]["credit"] == zero_credit()
    end

    test "an operation keeps the posting date chosen when it commits", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert [_] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-old", "occurred_on" => "2026-11-15"})
               ])

      # A later close never moves the movement again.
      assert [_] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-12-31"})
               ])

      first_open = report(conn, "2026-12-01")
      assert first_open["status"] == "closed"
      assert late_cash_entry(first_open, "ams-canal")["movements"]["received_cents"] == 5_000
      assert cash_entry(first_open, "ams-canal")["closing_held_cents"] == 5_000

      next = report(conn, "2026-12-02")
      assert cash_entry(next, "ams-canal")["opening_held_cents"] == 5_000
      assert cash_entry(next, "ams-canal")["movements"]["received_cents"] == 0
      assert next["late_adjustments"]["cash"] == []

      # And the rule applies to the new cutoff immediately.
      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-old-2",
                   "occurred_on" => "2026-12-10",
                   "amount_cents" => 1_000
                 })
               ])

      assert [_] =
               run(conn, [
                 close_op(%{"operation_id" => "op-close-3", "period_end_on" => "2027-01-31"})
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-old-3",
                   "occurred_on" => "2026-12-20",
                   "amount_cents" => 500
                 })
               ])

      new_first_open = report(conn, "2027-02-01")
      assert late_cash_entry(new_first_open, "ams-canal")["movements"]["received_cents"] == 500

      kept = report(conn, "2026-12-01")
      assert late_cash_entry(kept, "ams-canal")["movements"]["received_cents"] == 5_000
    end

    test "an operation whose occurred_on is already open keeps that date", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert [_] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-open", "occurred_on" => "2026-12-10"})
               ])

      on_its_date = report(conn, "2026-12-10")
      assert cash_entry(on_its_date, "ams-canal")["movements"]["received_cents"] == 5_000
      assert on_its_date["late_adjustments"]["cash"] == []

      first_open = report(conn, "2026-12-01")
      assert first_open["cash"] == []
      assert first_open["late_adjustments"]["cash"] == []
    end

    test "the posting rule changes only finance reporting", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert [applied] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-old", "occurred_on" => "2026-11-15"})
               ])

      assert applied["status"] == "applied"
      assert applied["outstanding_deposit_cents"] == 14_500

      # Group and ledger retain their current-state meanings.
      assert group(conn, "group-81")["deposit_paid_cents"] == 5_000
      assert ledger(conn)["cash_held_cents"] == 5_000

      stored = stored_result(conn, "op-pay-old")
      assert stored["status"] == "applied"
      assert stored["amount_cents"] == 5_000
    end
  end

  describe "late adjustments" do
    test "ordinary and late movements sum to the day's total movement", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert [_, _] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-old",
                   "occurred_on" => "2026-11-10",
                   "amount_cents" => 1_000
                 }),
                 payment_op(%{
                   "operation_id" => "op-pay-new",
                   "occurred_on" => "2026-12-01",
                   "amount_cents" => 500
                 })
               ])

      first_open = report(conn, "2026-12-01")
      ams = cash_entry(first_open, "ams-canal")
      assert ams["opening_held_cents"] == 0
      assert ams["movements"]["received_cents"] == 500
      assert ams["closing_held_cents"] == 1_500

      late = late_cash_entry(first_open, "ams-canal")
      assert late["movements"]["received_cents"] == 1_000

      # The day's total movement is the ordinary value plus the late value.
      assert ams["closing_held_cents"] ==
               ams["opening_held_cents"] +
                 ams["movements"]["received_cents"] + late["movements"]["received_cents"]
    end

    test "moved credit movements appear in the always-present credit late adjustments", %{
      conn: conn
    } do
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      # An old-dated cancellation converts cash and issues credit after the
      # close; both effects post on the first open day as late adjustments.
      assert [_, _, _] =
               run(conn, [
                 open_op(%{
                   "operation_id" => "op-open-fund",
                   "group_id" => "group-fund",
                   "property_id" => "fund-canal",
                   "occurred_on" => "2026-11-05"
                 }),
                 payment_op(%{
                   "operation_id" => "op-pay-fund",
                   "group_id" => "group-fund",
                   "amount_cents" => 2_000,
                   "occurred_on" => "2026-11-05"
                 }),
                 cancel_op(%{
                   "operation_id" => "op-cancel-fund",
                   "group_id" => "group-fund",
                   "occurred_on" => "2026-11-06",
                   "refund_method" => "hotel_credit"
                 })
               ])

      first_open = report(conn, "2026-12-01")

      assert first_open["credit"]["opening_liability_cents"] == 0
      assert first_open["credit"]["movements"] == zero_credit()
      assert first_open["credit"]["closing_liability_cents"] == 2_200

      assert first_open["late_adjustments"]["credit"] == %{
               "issued_cents" => 2_200,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      fund = late_cash_entry(first_open, "fund-canal")
      assert fund["movements"]["received_cents"] == 2_000
      assert fund["movements"]["converted_to_credit_cents"] == 2_000

      # The property's ordinary entry is all zero, so only the late entry
      # shows it.
      assert cash_entry(first_open, "fund-canal") == nil
    end

    test "a zero-net signed adjustment does not disappear", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 100})])
      assert [cancelled] = run(conn, [cancel_op()])
      assert cancelled["refunded_cents"] == 100
      assert [_] = run(conn, [close_op()])

      # Charging back the refunded cash after the close reverses the refund
      # and reports the chargeback on the first open day.
      assert [charged_back] = run(conn, [chargeback_op()])
      assert charged_back["status"] == "applied"
      assert charged_back["charged_back_cents"] == 100

      first_open = report(conn, "2026-12-01")

      late = late_cash_entry(first_open, "ams-canal")

      assert late["movements"] == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => -100,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 100
             }

      # The net balance effect is zero, but the signed classifications are
      # kept; the ordinary entry is all zero and therefore omitted.
      assert cash_entry(first_open, "ams-canal") == nil
      assert first_open["credit"]["closing_liability_cents"] == 0
    end

    test "late cash entries order by property_id and omit all-zero properties", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])

      assert [_] =
               run(conn, [
                 open_op(%{
                   "operation_id" => "op-open-third",
                   "group_id" => "group-third",
                   "property_id" => "utc-canal",
                   "rooms" => [%{"room_id" => "room-e", "nightly_rate_cents" => 9_000}]
                 })
               ])

      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 1_000})])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-92",
                   "group_id" => "group-92",
                   "amount_cents" => 800
                 })
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-third",
                   "group_id" => "group-third",
                   "amount_cents" => 600
                 })
               ])

      assert [_] = run(conn, [close_op()])

      # Old-dated payments to two of the three properties, submitted in the
      # opposite of the expected order.
      assert [_, _] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-92-old",
                   "group_id" => "group-92",
                   "occurred_on" => "2026-11-12",
                   "amount_cents" => 300
                 }),
                 payment_op(%{
                   "operation_id" => "op-pay-old",
                   "occurred_on" => "2026-11-10",
                   "amount_cents" => 200
                 })
               ])

      first_open = report(conn, "2026-12-01")

      assert Enum.map(first_open["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "rot-canal"]

      assert late_cash_entry(first_open, "ams-canal")["movements"]["received_cents"] == 200
      assert late_cash_entry(first_open, "rot-canal")["movements"]["received_cents"] == 300
      assert late_cash_entry(first_open, "utc-canal") == nil
    end
  end

  describe "reading after a close" do
    test "availability and validation rules are unchanged", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [close_op()])

      assert report_error(conn, "2026-10-31", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      assert report_error(conn, nil, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      assert report_error(conn, "not-a-date", 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    test "a close does not change groups or the ledger", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])
      assert [_] = run(conn, [start_op()])

      ledger_before = ledger(conn)
      group_before = group(conn, "group-81")

      assert [_] = run(conn, [close_op()])

      assert ledger(conn) == ledger_before
      assert group(conn, "group-81") == group_before
    end
  end
end
