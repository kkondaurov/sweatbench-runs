defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  @booked_on "2026-10-03"
  @arrival_on "2026-12-10"
  # Refundable until arrival minus the flex-14 window.
  @refundable_on "2026-11-26"
  @non_refundable_on "2026-11-27"

  describe "close_finance_period application and rejection" do
    test "rejects with invalid_period before reporting has started", %{conn: conn} do
      result = only_result(submit(conn, [close_op("op-close", "2026-10-31")]))

      assert result == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "rejects a missing or malformed period_end_on and a date before starts_on", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])

      missing =
        only_result(
          submit(conn, [%{"operation_id" => "op-close", "type" => "close_finance_period"}])
        )

      assert missing["code"] == "invalid_period"

      assert only_result(submit(conn, [close_op("op-close-2", "not-a-date")]))["code"] ==
               "invalid_period"

      assert only_result(submit(conn, [close_op("op-close-3", "2026-09-30")]))["code"] ==
               "invalid_period"

      # Nothing was closed; the day is still open.
      assert report(conn, "2026-10-05")["status"] == "open"
    end

    test "applies with exactly the close result and enforces strictly later cutoffs", %{
      conn: conn
    } do
      submit(conn, [start_op("op-start", "2026-10-01")])

      result = only_result(submit(conn, [close_op("op-close", "2026-10-10")]))

      assert result == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-10-10"
             }

      # The same or an earlier cutoff is rejected for a different operation.
      assert only_result(submit(conn, [close_op("op-close-same", "2026-10-10")]))["code"] ==
               "invalid_period"

      assert only_result(submit(conn, [close_op("op-close-earlier", "2026-10-09")]))["code"] ==
               "invalid_period"

      # A strictly later cutoff applies.
      assert only_result(submit(conn, [close_op("op-close-2", "2026-10-20")]))["status"] ==
               "applied"
    end

    test "a retried close replays its stored result; a changed payload conflicts", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01"), close_op("op-close", "2026-10-10")])

      replay = only_result(submit(conn, [close_op("op-close", "2026-10-10")]))

      assert replay == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-10-10"
             }

      conflict = only_result(submit(conn, [close_op("op-close", "2026-10-11")]))

      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"

      # Only the original cutoff is published.
      assert report(conn, "2026-10-11")["status"] == "open"
    end

    test "the close addresses no group and takes no revision guard", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])

      result =
        only_result(
          submit(conn, [
            %{
              "operation_id" => "op-close",
              "type" => "close_finance_period",
              "period_end_on" => "2026-10-10",
              "group_id" => "missing-group",
              "expected_revision" => 7
            }
          ])
        )

      assert result["status"] == "applied"
      assert Map.keys(result) == ["operation_id", "period_end_on", "status"]
    end
  end

  describe "published reports" do
    test "reports through the cutoff are closed; later ones are open", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-a")

      assert report(conn, "2026-10-05")["status"] == "open"

      submit(conn, [close_op("op-close", "2026-10-10")])

      assert report(conn, "2026-10-01")["status"] == "closed"
      assert report(conn, "2026-10-10")["status"] == "closed"
      assert report(conn, "2026-10-11")["status"] == "open"
    end

    test "closed reports stay byte-for-byte stable across later operations and closes", %{
      conn: conn
    } do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 10_000, occurred_on: "2026-10-05")])
      submit(conn, [payment_op("op-pay-2", "group-a", 5_000, occurred_on: "2026-10-06")])

      submit(conn, [close_op("op-close", "2026-10-10")])

      frozen = %{
        "2026-10-05" => report(conn, "2026-10-05"),
        "2026-10-06" => report(conn, "2026-10-06"),
        "2026-10-10" => report(conn, "2026-10-10")
      }

      # A late old-dated operation and a further close must not move them.
      submit(conn, [reduce_op("op-reduce", "op-pay", 2_000, "2026-10-04")])
      submit(conn, [close_op("op-close-2", "2026-10-15")])

      for {date, frozen_report} <- frozen do
        assert report(conn, date) == frozen_report
      end
    end
  end

  describe "posting after a close" do
    test "an operation immediately before a close posts into the period being closed", %{
      conn: conn
    } do
      submit(conn, [
        start_op("op-start", "2026-10-01"),
        open_op("group-a"),
        payment_op("op-pay", "group-a", 7_000, occurred_on: "2026-10-08"),
        close_op("op-close", "2026-10-10")
      ])

      day = report(conn, "2026-10-08")

      assert day["status"] == "closed"
      assert cash_entry(day, "ams-canal")["movements"]["received_cents"] == 7_000
      assert day["late_adjustments"] == %{"cash" => [], "credit" => zero_late_credit()}
    end

    test "an old-dated operation immediately after the close posts on the first open day", %{
      conn: conn
    } do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 10_000, occurred_on: "2026-10-05")])

      submit(conn, [close_op("op-close", "2026-10-10")])

      # The reduction is dated inside the closed period but posts on the
      # first open day after the cutoff.
      result = only_result(submit(conn, [reduce_op("op-reduce", "op-pay", 2_000, "2026-10-04")]))
      assert result["status"] == "applied"

      first_open = report(conn, "2026-10-11")
      assert first_open["status"] == "open"

      assert cash_entry(first_open, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 8_000
             }

      assert first_open["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{zero_cash_movements() | "reduced_cents" => 2_000}
                 }
               ],
               "credit" => zero_late_credit()
             }

      # The operation keeps its posting date; a later close never moves it.
      submit(conn, [close_op("op-close-2", "2026-10-20")])

      still_first_open = report(conn, "2026-10-11")
      assert still_first_open["status"] == "closed"
      assert cash_entry(still_first_open, "ams-canal")["closing_held_cents"] == 8_000
      assert cash_entry(still_first_open, "ams-canal")["movements"] == zero_cash_movements()

      assert still_first_open["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_cash_movements() | "reduced_cents" => 2_000}
               }
             ]

      # An operation dated in the open period keeps its own date and is not
      # a late adjustment.
      submit(conn, [payment_op("op-pay-2", "group-a", 1_000, occurred_on: "2026-10-21")])
      open_day = report(conn, "2026-10-21")

      assert cash_entry(open_day, "ams-canal")["movements"]["received_cents"] == 1_000
      assert open_day["late_adjustments"]["cash"] == []
    end

    test "late adjustments keep signed classifications, sort by property, omit zeros", %{
      conn: conn
    } do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-src")
      open_group!(conn, "group-dst", property_id: "rtm-harbor")

      # Payments and a full refund, entirely inside the period being closed.
      open_group!(conn, "group-refund")
      submit(conn, [payment_op("op-pay-src", "group-src", 10_000, occurred_on: "2026-10-05")])
      submit(conn, [payment_op("op-pay-r", "group-refund", 19_500, occurred_on: "2026-10-05")])
      submit(conn, [cancel_op("op-cancel-r", "group-refund", @refundable_on)])

      submit(conn, [close_op("op-close", "2026-12-01")])

      # After the close, old-dated corrections post on the first open day:
      # a transfer between properties, a reduction following transferred
      # cash, and a chargeback reversing the earlier refund.
      submit(conn, [
        transfer_op("op-transfer", "group-src", "group-dst", 4_000, "2026-10-04"),
        reduce_op("op-reduce", "op-pay-src", 1_500, "2026-10-04"),
        charge_back_op("op-chb", "op-pay-r", "2026-10-04")
      ])

      day = report(conn, "2026-12-02")

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   zero_cash_movements()
                   | "transferred_out_cents" => 4_000,
                     "refunded_cents" => -19_500,
                     "charged_back_cents" => 19_500
                 }
               },
               %{
                 "property_id" => "rtm-harbor",
                 "movements" => %{
                   zero_cash_movements()
                   | "transferred_in_cents" => 4_000,
                     # The reduction follows the transferred cash to the
                     # property where it is held now.
                     "reduced_cents" => 1_500
                 }
               }
             ]

      assert day["late_adjustments"]["credit"] == zero_late_credit()

      # The zero-net reversal survives: refunded -19500 and charged back
      # +19500 are both shown even though they cancel in the balance.
      [ams_late, _rtm_late] = day["late_adjustments"]["cash"]

      assert ams_late["movements"]["refunded_cents"] == -19_500
      assert ams_late["movements"]["charged_back_cents"] == 19_500

      # Ordinary columns carry none of the moved movements; opening and
      # closing balances include them.
      assert cash_entry(day, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 10_000 - 4_000 + 19_500 - 19_500
             }

      assert cash_entry(day, "rtm-harbor") == %{
               "property_id" => "rtm-harbor",
               "opening_held_cents" => 0,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 2_500
             }
    end

    test "credit moved by a close appears in the late-adjustment credit object", %{conn: conn} do
      issue_credit!(conn, "op-seed", "group-seed", 10_000, @refundable_on)
      submit(conn, [start_op("op-start", "2026-10-01")])

      open_group!(conn, "group-user")
      submit(conn, [apply_credit_op("op-apply", "group-user", 4_000)])
      submit(conn, [close_op("op-close", "2026-12-01")])

      # The consuming cancellation is dated before the cutoff but commits
      # after it, so its liability movement posts on the first open day.
      result =
        only_result(submit(conn, [cancel_op("op-cancel", "group-user", @non_refundable_on)]))

      assert result["status"] == "applied"

      day = report(conn, "2026-12-02")

      assert day["credit"]["movements"]["consumed_cents"] == 0

      assert day["credit"]["opening_liability_cents"] == 11_000
      assert day["credit"]["closing_liability_cents"] == 7_000

      assert day["late_adjustments"] == %{
               "cash" => [],
               "credit" => %{zero_late_credit() | "consumed_cents" => 4_000}
             }
    end

    test "an all-zero late day reports empty adjustments and reconciles with ordinary columns", %{
      conn: conn
    } do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 10_000, occurred_on: "2026-10-05")])
      submit(conn, [close_op("op-close", "2026-10-10")])

      # Nothing commits after the close; the first open day is untouched.
      day = report(conn, "2026-10-11")

      assert day["late_adjustments"] == %{"cash" => [], "credit" => zero_late_credit()}

      # The day carries the closed period's holdings forward with no
      # ordinary or late movement of its own.
      assert day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10_000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 10_000
               }
             ]

      entry = cash_entry(report(conn, "2026-10-05"), "ams-canal")

      assert entry["movements"]["received_cents"] == 10_000

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + Enum.sum(Map.values(entry["movements"]))
    end
  end

  # Helpers

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(response) do
    [result] = response["results"]
    result
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=" <> date)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cash_entry(report_data, property_id) do
    Enum.find(report_data["cash"], &(&1["property_id"] == property_id))
  end

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

  defp zero_late_credit do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp start_op(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_op(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_op(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-" <> group_id),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => Keyword.get(opts, :property_id, "ams-canal"),
      "arrival_on" => @arrival_on,
      "departure_on" => "2026-12-13",
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
    }
  end

  defp open_group!(conn, group_id, opts \\ []) do
    assert only_result(submit(conn, [open_op(group_id, opts)]))["status"] == "applied"
  end

  defp payment_op(operation_id, group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(operation_id, source_group_id, destination_group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp reduce_op(operation_id, payment_operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_op(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  # Cancels a freshly paid flexible group with hotel credit so guest-22 ends
  # up with a credit lot worth round(cash * 110%) expiring 366 days later.
  defp issue_credit!(conn, operation_id, group_id, cash_cents, occurred_on) do
    open_group!(conn, group_id)
    submit(conn, [payment_op("op-pay-" <> group_id, group_id, cash_cents)])

    result = only_result(submit(conn, [credit_cancel_op(operation_id, group_id, occurred_on)]))
    assert result["status"] == "applied"
    result
  end

  defp credit_cancel_op(operation_id, group_id, occurred_on) do
    cancel_op(operation_id, group_id, occurred_on)
    |> Map.put("refund_method", "hotel_credit")
  end
end
