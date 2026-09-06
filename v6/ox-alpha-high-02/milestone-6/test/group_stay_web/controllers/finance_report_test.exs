defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  @booked_on "2026-10-03"
  @arrival_on "2026-12-10"
  # Refundable until arrival minus the flex-14 window.
  @refundable_on "2026-11-26"
  @non_refundable_on "2026-11-27"

  describe "start_finance_reporting" do
    test "applies with exactly the inception result", %{conn: conn} do
      result =
        only_result(submit(conn, [start_op("op-start", "2026-10-06")]))

      assert result == %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => "2026-10-06"
             }
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      missing =
        only_result(
          submit(conn, [%{"operation_id" => "op-start", "type" => "start_finance_reporting"}])
        )

      assert missing["code"] == "invalid_reporting_date"

      invalid = only_result(submit(conn, [start_op("op-start-2", "not-a-date")]))
      assert invalid["code"] == "invalid_reporting_date"

      # Neither attempt started reporting.
      assert conn
             |> get("/api/v1/finance/daily-report?date=2026-10-06")
             |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "rejects a different start once reporting began", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-06")])

      result = only_result(submit(conn, [start_op("op-start-later", "2026-10-07")]))

      assert result["status"] == "rejected"
      assert result["code"] == "reporting_already_started"
    end

    test "a retried start replays its stored result; changed payloads conflict", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-06")])

      replay =
        only_result(
          submit(conn, [
            %{
              "operation_id" => "op-start",
              "type" => "start_finance_reporting",
              "starts_on" => "2026-10-06"
            }
          ])
        )

      assert replay == %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => "2026-10-06"
             }

      conflict = only_result(submit(conn, [start_op("op-start", "2026-10-07")]))
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"

      # Reporting still runs on the original start date.
      assert report(conn, "2026-10-07")["date"] == "2026-10-07"
    end
  end

  describe "GET /api/v1/finance/daily-report availability" do
    test "a missing or invalid date is a 422", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-06")])

      assert conn |> get("/api/v1/finance/daily-report") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert conn |> get("/api/v1/finance/daily-report?date=nope") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "before reporting starts, and before starts_on, the report is unavailable", %{conn: conn} do
      assert conn
             |> get("/api/v1/finance/daily-report?date=2026-10-06")
             |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}

      submit(conn, [start_op("op-start", "2026-10-06")])

      assert conn
             |> get("/api/v1/finance/daily-report?date=2026-10-05")
             |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end
  end

  describe "the opening position" do
    test "freezes every committed operation, even one dated on or after starts_on", %{conn: conn} do
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 10_000, occurred_on: "2026-10-20")])
      submit(conn, [start_op("op-start", "2026-10-06")])

      assert report(conn, "2026-10-06")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10_000,
                 "movements" => zero_cash_movements(),
                 "closing_held_cents" => 10_000
               }
             ]

      assert report(conn, "2026-10-20")["credit"]["movements"]["issued_cents"] == 0
    end

    test "operations before the start in one batch open; later ones move", %{conn: conn} do
      submit(conn, [
        open_op("group-a"),
        payment_op("op-pay", "group-a", 10_000, occurred_on: "2026-10-05"),
        start_op("op-start", "2026-10-06"),
        payment_op("op-pay-2", "group-a", 2_500, occurred_on: "2026-10-06")
      ])

      assert report(conn, "2026-10-06")["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10_000,
                 "movements" => %{zero_cash_movements() | "received_cents" => 2_500},
                 "closing_held_cents" => 12_500
               }
             ]
    end
  end

  describe "reading one day" do
    test "received cash moves and later submissions rewrite an earlier open report", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 5_000, occurred_on: "2026-10-07")])

      assert cash_entry(report(conn, "2026-10-07"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{zero_cash_movements() | "received_cents" => 5_000},
               "closing_held_cents" => 5_000
             }

      assert cash_entry(report(conn, "2026-10-08"), "ams-canal")["opening_held_cents"] == 5_000

      # A later submission posts onto its own occurred_on and changes the
      # earlier open report.
      submit(conn, [payment_op("op-pay-2", "group-a", 2_500, occurred_on: "2026-10-07")])

      assert cash_entry(report(conn, "2026-10-07"), "ams-canal")["movements"]["received_cents"] ==
               7_500

      assert cash_entry(report(conn, "2026-10-07"), "ams-canal")["closing_held_cents"] == 7_500
      assert cash_entry(report(conn, "2026-10-08"), "ams-canal")["opening_held_cents"] == 7_500
    end

    test "an all-zero day omits the property entirely", %{conn: conn} do
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 10_000, occurred_on: "2026-10-05")])
      submit(conn, [start_op("op-start", "2026-10-06")])
      submit(conn, [cancel_op("op-cancel", "group-a", @refundable_on)])

      assert cash_entry(report(conn, @refundable_on), "ams-canal")["movements"]["refunded_cents"] ==
               10_000

      # By the next day opening, closing and every movement are zero.
      day_after = Date.to_iso8601(Date.add(~D[2026-11-26], 1))

      assert report(conn, day_after)["cash"] == []
    end

    test "transfers balance across properties on the day", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-src")
      open_group!(conn, "group-dst", property_id: "rtm-harbor")

      submit(conn, [payment_op("op-pay", "group-src", 12_000, occurred_on: "2026-10-07")])
      submit(conn, [transfer_op("op-transfer", "group-src", "group-dst", 5_000, "2026-10-08")])

      ams = cash_entry(report(conn, "2026-10-08"), "ams-canal")
      rtm = cash_entry(report(conn, "2026-10-08"), "rtm-harbor")

      assert ams["movements"]["transferred_out_cents"] == 5_000
      assert ams["closing_held_cents"] == 7_000
      assert rtm["movements"]["transferred_in_cents"] == 5_000
      assert rtm["closing_held_cents"] == 5_000

      # Openings carry the holdings forward.
      assert cash_entry(report(conn, "2026-10-09"), "ams-canal")["opening_held_cents"] == 7_000
      assert cash_entry(report(conn, "2026-10-09"), "rtm-harbor")["opening_held_cents"] == 5_000
    end

    test "a reduction follows the cash and a rejected operation moves nothing", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-a")
      submit(conn, [payment_op("op-pay", "group-a", 6_000, occurred_on: "2026-10-05")])

      # Rejected: overpayment leaves no movement anywhere.
      over =
        only_result(
          submit(conn, [payment_op("op-over", "group-a", 99_999, occurred_on: "2026-10-05")])
        )

      assert over["status"] == "rejected"

      assert cash_entry(report(conn, "2026-10-05"), "ams-canal")["movements"]["received_cents"] ==
               6_000

      submit(conn, [reduce_op("op-reduce", "op-pay", 2_000, "2026-10-06")])

      assert cash_entry(report(conn, "2026-10-06"), "ams-canal")["movements"]["reduced_cents"] ==
               2_000

      assert cash_entry(report(conn, "2026-10-06"), "ams-canal")["closing_held_cents"] == 4_000

      # A durable retry of the applied payment does not report it twice.
      submit(conn, [payment_op("op-pay", "group-a", 6_000, occurred_on: "2026-10-05")])

      assert cash_entry(report(conn, "2026-10-05"), "ams-canal")["movements"]["received_cents"] ==
               6_000
    end

    test "a correction follows transferred cash to the property that holds it", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-src")
      open_group!(conn, "group-dst", property_id: "rtm-harbor")

      submit(conn, [payment_op("op-pay", "group-src", 6_000, occurred_on: "2026-10-05")])
      submit(conn, [transfer_op("op-transfer", "group-src", "group-dst", 4_000, "2026-10-06")])

      # The reduction lands where the cash is held now, not on the payment's
      # original property.
      submit(conn, [reduce_op("op-reduce", "op-pay", 1_500, "2026-10-07")])

      assert cash_entry(report(conn, "2026-10-07"), "ams-canal")["movements"]["reduced_cents"] ==
               0

      assert cash_entry(report(conn, "2026-10-07"), "rtm-harbor")["movements"]["reduced_cents"] ==
               1_500

      assert cash_entry(report(conn, "2026-10-07"), "rtm-harbor")["closing_held_cents"] == 2_500

      # A chargeback of the remainder is booked on the holding property too.
      submit(conn, [charge_back_op("op-chb", "op-pay", "2026-10-08")])

      chb_day_ams = cash_entry(report(conn, "2026-10-08"), "ams-canal")
      chb_day_rtm = cash_entry(report(conn, "2026-10-08"), "rtm-harbor")

      assert chb_day_ams["movements"]["charged_back_cents"] == 2_000
      assert chb_day_rtm["movements"]["charged_back_cents"] == 2_500
      assert chb_day_rtm["closing_held_cents"] == 0

      # Company-wide the charged-back total equals the recorded payment.
      assert Enum.sum(
               Enum.map(report(conn, "2026-10-08")["cash"], fn entry ->
                 entry["movements"]["charged_back_cents"]
               end)
             ) == 4_500
    end

    test "refunds, retentions, conversions and chargeback reversals keep the identity", %{
      conn: conn
    } do
      submit(conn, [start_op("op-start", "2026-10-01")])

      # Refunded
      open_group!(conn, "group-refund")
      submit(conn, [payment_op("op-pay-r", "group-refund", 19_500, occurred_on: "2026-10-05")])
      submit(conn, [cancel_op("op-cancel-r", "group-refund", @refundable_on)])

      refund_day = cash_entry(report(conn, @refundable_on), "ams-canal")

      assert refund_day["movements"]["refunded_cents"] == 19_500
      assert refund_day["closing_held_cents"] == 0
      assert refund_day["opening_held_cents"] == 19_500

      # Retained
      open_group!(conn, "group-retained")
      submit(conn, [payment_op("op-pay-t", "group-retained", 19_500, occurred_on: "2026-10-05")])
      submit(conn, [cancel_op("op-cancel-t", "group-retained", @non_refundable_on)])

      # Converted with hotel credit issued at the standard bonus
      open_group!(conn, "group-converted")
      submit(conn, [payment_op("op-pay-c", "group-converted", 10_000, occurred_on: "2026-10-05")])
      submit(conn, [credit_cancel_op("op-cancel-c", "group-converted", @refundable_on)])

      # The refundable settlement day: refunds and the conversion move,
      # the retained group still holds its cash.
      refund_day = cash_entry(report(conn, @refundable_on), "ams-canal")

      assert refund_day["opening_held_cents"] == 49_000
      # Both payments were posted when they occurred, back in October.
      assert refund_day["movements"]["received_cents"] == 0
      assert refund_day["movements"]["refunded_cents"] == 19_500
      assert refund_day["movements"]["converted_to_credit_cents"] == 10_000
      assert refund_day["movements"]["retained_cents"] == 0
      assert refund_day["closing_held_cents"] == 19_500

      credit = report(conn, @refundable_on)["credit"]

      assert credit["movements"]["issued_cents"] == 11_000
      assert credit["opening_liability_cents"] == 0
      assert credit["closing_liability_cents"] == 11_000

      # The non-refundable day: retention moves. Reversing the earlier
      # refund reports negative refunded together with positive charged back.
      submit(conn, [charge_back_op("op-chb", "op-pay-r", @non_refundable_on)])

      reversal_day = cash_entry(report(conn, @non_refundable_on), "ams-canal")

      assert reversal_day["opening_held_cents"] == 19_500
      assert reversal_day["movements"]["retained_cents"] == 19_500
      assert reversal_day["movements"]["refunded_cents"] == -19_500
      assert reversal_day["movements"]["charged_back_cents"] == 19_500
      assert reversal_day["closing_held_cents"] == 0

      # Reports reconcile with the current views.
      ledger_data = ledger(conn)

      assert ledger_data["cash_held_cents"] == 0
      assert ledger_data["cash_refunded_cents"] == 0
      assert ledger_data["cash_retained_cents"] == 19_500
      assert ledger_data["cash_converted_to_credit_cents"] == 10_000
      assert ledger_data["cash_charged_back_cents"] == 19_500
    end

    test "unused credit expires on the day after expires_on without any operation", %{conn: conn} do
      submit(conn, [start_op("op-start", "2026-10-01")])
      open_group!(conn, "group-lot")
      submit(conn, [payment_op("op-pay", "group-lot", 10_000, occurred_on: "2026-10-05")])
      submit(conn, [credit_cancel_op("op-issue", "group-lot", @refundable_on)])

      expires_on = Date.add(~D[2026-11-26], 366)
      expiry_day = Date.to_iso8601(Date.add(expires_on, 1))
      last_valid_day = Date.to_iso8601(expires_on)

      assert report(conn, last_valid_day)["credit"]["closing_liability_cents"] == 11_000
      assert report(conn, last_valid_day)["credit"]["movements"]["expired_cents"] == 0

      expiry_report = report(conn, expiry_day)["credit"]

      assert expiry_report["opening_liability_cents"] == 11_000
      assert expiry_report["movements"]["expired_cents"] == 11_000
      assert expiry_report["closing_liability_cents"] == 0
    end

    test "credit issued before reporting starts still expires on its day", %{conn: conn} do
      # The lot exists before reporting begins, and nothing touches it after.
      issue_credit!(conn, "op-seed", "group-seed", 10_000, @refundable_on)
      submit(conn, [start_op("op-start", "2026-10-01")])

      expires_on = Date.add(~D[2026-11-26], 366)
      expiry_day = Date.to_iso8601(Date.add(expires_on, 1))
      last_valid_day = Date.to_iso8601(expires_on)

      assert report(conn, last_valid_day)["credit"]["closing_liability_cents"] == 11_000

      credit = report(conn, expiry_day)["credit"]

      assert credit["opening_liability_cents"] == 11_000
      assert credit["movements"]["expired_cents"] == 11_000
      assert credit["closing_liability_cents"] == 0
    end

    test "consumed credit leaves through the consumed column", %{conn: conn} do
      issue_credit!(conn, "op-seed", "group-seed", 10_000, @refundable_on)
      submit(conn, [start_op("op-start", "2026-10-01")])

      open_group!(conn, "group-user")
      submit(conn, [apply_credit_op("op-apply", "group-user", 4_000)])
      submit(conn, [cancel_op("op-cancel", "group-user", @non_refundable_on)])

      credit = report(conn, @non_refundable_on)["credit"]

      assert credit["movements"]["issued_cents"] == 0
      assert credit["movements"]["consumed_cents"] == 4_000
      assert credit["opening_liability_cents"] == 11_000
      assert credit["closing_liability_cents"] == 7_000
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

  defp start_op(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
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

  defp credit_cancel_op(operation_id, group_id, occurred_on) do
    cancel_op(operation_id, group_id, occurred_on)
    |> Map.put("refund_method", "hotel_credit")
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

  defp ledger(conn), do: conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
end
