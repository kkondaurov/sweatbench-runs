defmodule GroupStayWeb.PeriodCloseTest do
  @moduledoc """
  Product request 07: the finance period close.

  `close_finance_period` closes the books through a cutoff: every report
  through the cutoff is published and returns `status: "closed"`,
  byte-for-byte stable across later operations, later closes, and
  restarts. Operations processed after a close post their complete finance
  effect on the first open day — max(occurred_on, starts_on, the day
  after the latest cutoff at commit) — and show up in the daily report's
  `late_adjustments` block, keeping the signed classifications even when
  their net balance effect is zero.
  """

  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Finance.ClosedReport
  alias GroupStay.Repo

  @guest "guest-22"
  @booked_on "2026-10-03"
  @arrival_on "2027-06-10"
  @departure_on "2027-06-13"
  @starts_on "2027-01-01"
  @cutoff "2027-01-10"
  @first_open_day "2027-01-11"

  # Two rooms, three nights at 10000: flexible deposit 12000 for the group.

  defp open_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, @guest),
      "property_id" => Keyword.get(opts, :property_id, "ams-canal"),
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
      ]
    }
  end

  defp payment_operation(group_id, amount_cents, opts) do
    %{
      "operation_id" => Keyword.fetch!(opts, :operation_id),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, opts) do
    %{
      "operation_id" => Keyword.fetch!(opts, :operation_id),
      "type" => "cancel_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id
    }
    |> maybe_put("refund_method", Keyword.get(opts, :refund_method))
  end

  defp charge_back_operation(payment_operation_id, opts) do
    %{
      "operation_id" => Keyword.fetch!(opts, :operation_id),
      "type" => "charge_back_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id
    }
  end

  defp start_operation(operation_id, starts_on \\ @starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "occurred_on" => @booked_on,
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "occurred_on" => period_end_on,
      "period_end_on" => period_end_on
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp apply_op!(conn, operation) do
    [result] = submit!(conn, [operation])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp open_group!(conn, group_id, opts \\ []) do
    apply_op!(conn, open_operation(group_id, opts))
  end

  defp start_reporting!(conn) do
    apply_op!(conn, start_operation("op-start"))
  end

  defp close_period!(conn, period_end_on, operation_id) do
    apply_op!(conn, close_operation(operation_id, period_end_on))
  end

  defp daily_report(date) do
    conn = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp report_body(date) do
    conn = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    assert conn.status == 200
    response(conn, 200)
  end

  defp cash_entry(report, property_id),
    do: Enum.find(report["cash"], &(&1["property_id"] == property_id))

  defp late_cash_entry(report, property_id),
    do: Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))

  describe "closing through a date" do
    test "a close before reporting has started is rejected as invalid_period" do
      conn = build_conn()

      assert [rejected] = submit!(conn, [close_operation("op-close-early", "2027-01-05")])

      assert rejected == %{
               "operation_id" => "op-close-early",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "a cutoff before starts_on is rejected as invalid_period" do
      conn = build_conn()
      start_reporting!(conn)

      assert [rejected] = submit!(conn, [close_operation("op-close-before", "2026-12-31")])
      assert rejected["code"] == "invalid_period"
    end

    test "a missing or invalid period_end_on is rejected as invalid_period" do
      conn = build_conn()
      start_reporting!(conn)

      assert [missing] =
               submit!(conn, [
                 Map.delete(close_operation("op-close-none", @cutoff), "period_end_on")
               ])

      assert missing["code"] == "invalid_period"

      assert [invalid] =
               submit!(conn, [
                 close_operation("op-close-bad", "January 10th")
                 |> Map.put("occurred_on", @cutoff)
               ])

      assert invalid["code"] == "invalid_period"
    end

    test "the applied result contains exactly the three fields, and the cutoff may be starts_on" do
      conn = build_conn()
      start_reporting!(conn)

      assert close_period!(conn, @starts_on, "op-close-start") == %{
               "operation_id" => "op-close-start",
               "status" => "applied",
               "period_end_on" => @starts_on
             }

      assert daily_report(@starts_on)["status"] == "closed"
      assert daily_report("2027-01-02")["status"] == "open"
    end

    test "reports through the cutoff are closed and later reports stay open" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-status")

      apply_op!(
        conn,
        payment_operation("g-status", 5000,
          operation_id: "op-status-pay",
          occurred_on: "2027-01-02"
        )
      )

      close_period!(conn, @cutoff, "op-close-1")

      assert daily_report("2027-01-02")["status"] == "closed"
      assert daily_report(@cutoff)["status"] == "closed"
      assert daily_report(@first_open_day)["status"] == "open"
    end
  end

  describe "durable replay and conflict rules of closes" do
    test "an identical retry replays the exact stored result" do
      conn = build_conn()
      start_reporting!(conn)
      closed = close_period!(conn, @cutoff, "op-close-retry")

      assert [replay] = submit!(conn, [close_operation("op-close-retry", @cutoff)])
      assert replay == closed
    end

    test "different content under the same operation_id conflicts" do
      conn = build_conn()
      start_reporting!(conn)
      close_period!(conn, @cutoff, "op-close-conflict")

      assert [conflict] = submit!(conn, [close_operation("op-close-conflict", "2027-01-20")])
      assert conflict["code"] == "operation_id_conflict"
    end

    test "a different operation with the same or an earlier cutoff is rejected" do
      conn = build_conn()
      start_reporting!(conn)
      close_period!(conn, @cutoff, "op-close-first")

      assert [same] = submit!(conn, [close_operation("op-close-same", @cutoff)])
      assert same["code"] == "invalid_period"

      assert [earlier] = submit!(conn, [close_operation("op-close-earlier", "2027-01-05")])
      assert earlier["code"] == "invalid_period"

      # A strictly later cutoff still applies.
      assert close_period!(conn, "2027-01-20", "op-close-later")["period_end_on"] == "2027-01-20"

      # A retry of a rejected close replays its stored rejection.
      assert [replay] = submit!(conn, [close_operation("op-close-same", @cutoff)])
      assert replay == same
    end
  end

  describe "published reports stay byte-for-byte stable" do
    test "later operations and later closes never rewrite a published day" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-stable")

      apply_op!(
        conn,
        payment_operation("g-stable", 5000,
          operation_id: "op-stable-pay",
          occurred_on: "2027-01-02"
        )
      )

      close_period!(conn, @cutoff, "op-stable-close-1")

      frozen_day = "2027-01-02"
      before_body = report_body(frozen_day)

      # An old-dated operation lands on the first open day instead.
      apply_op!(
        conn,
        payment_operation("g-stable", 1000,
          operation_id: "op-stable-late",
          occurred_on: "2027-01-03"
        )
      )

      assert report_body(frozen_day) == before_body

      # A later close publishes more days without touching the old ones.
      close_period!(conn, "2027-01-20", "op-stable-close-2")
      assert report_body(frozen_day) == before_body

      # The published day's data value is stored durably.
      stored = Repo.get_by(ClosedReport, report_on: ~D[2027-01-02])
      assert stored != nil
      assert Jason.decode!(stored.data) == daily_report(frozen_day)
    end

    test "a published day keeps its derived expiry even after the lot balance moves" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-freeze-expiry")

      # Converted before starts_on: issued posts on starts_on and the lot
      # expires on 2027-12-21, expiring the following day.
      apply_op!(
        conn,
        payment_operation("g-freeze-expiry", 100,
          operation_id: "op-freeze-pay",
          occurred_on: "2026-12-20"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-freeze-expiry",
          operation_id: "op-freeze-cancel",
          occurred_on: "2026-12-21",
          refund_method: "hotel_credit"
        )
      )

      close_period!(conn, "2028-01-01", "op-freeze-close")

      # The lot expires_on is 2027-12-22; the expiry movement lands on the
      # following day, inside the closed period.
      expiry_day = "2027-12-23"
      frozen_body = report_body(expiry_day)
      assert daily_report(expiry_day)["credit"]["movements"]["expired_cents"] == 110

      # A charge-back empties the lot, so a fresh computation would show no
      # expiry — but the published day never moves.
      apply_op!(
        conn,
        charge_back_operation("op-freeze-pay",
          operation_id: "op-freeze-charge",
          occurred_on: "2027-01-04"
        )
      )

      assert report_body(expiry_day) == frozen_body
      assert daily_report(expiry_day)["credit"]["movements"]["expired_cents"] == 110

      # The clawed-back credit posts as a late adjustment on the first
      # open day after the close.
      late = daily_report("2028-01-02")
      assert late["status"] == "open"
      assert late["late_adjustments"]["credit"]["revoked_cents"] == 110
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts its complete effect on the first open day" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-late")

      apply_op!(
        conn,
        payment_operation("g-late", 5000, operation_id: "op-late-pay", occurred_on: "2027-01-02")
      )

      close_period!(conn, @cutoff, "op-late-close")

      apply_op!(
        conn,
        payment_operation("g-late", 1000,
          operation_id: "op-late-late",
          occurred_on: "2027-01-03"
        )
      )

      report = daily_report(@first_open_day)
      entry = cash_entry(report, "ams-canal")

      assert report["status"] == "open"
      assert entry["opening_held_cents"] == 5000

      # The ordinary movements stay empty; the late block carries the day.
      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 6000

      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 1000

      # The closed day was not rewritten: no movement arrived there.
      closed_day = daily_report("2027-01-03")
      assert closed_day["status"] == "closed"
      assert cash_entry(closed_day, "ams-canal")["movements"]["received_cents"] == 0
    end

    test "within one batch: before a close posts inside the period, after posts on the first open day" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-sequence")

      assert [_inside, _close, _after] =
               submit!(conn, [
                 payment_operation("g-sequence", 2000,
                   operation_id: "op-seq-inside",
                   occurred_on: "2027-01-03"
                 ),
                 close_operation("op-seq-close", @cutoff),
                 payment_operation("g-sequence", 1000,
                   operation_id: "op-seq-after",
                   occurred_on: "2027-01-04"
                 )
               ])

      # The payment before the close is inside the published period.
      inside = daily_report("2027-01-03")
      assert inside["status"] == "closed"
      assert cash_entry(inside, "ams-canal")["movements"]["received_cents"] == 2000

      # The old-dated payment after the close lands on the first open day.
      after_report = daily_report(@first_open_day)
      assert after_report["status"] == "open"
      assert late_cash_entry(after_report, "ams-canal")["movements"]["received_cents"] == 1000
      assert cash_entry(after_report, "ams-canal")["closing_held_cents"] == 3000
    end

    test "an operation keeps the posting date it chose when it committed" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-keep")

      close_period!(conn, @cutoff, "op-keep-close-1")

      apply_op!(
        conn,
        payment_operation("g-keep", 4000,
          operation_id: "op-keep-pay",
          occurred_on: "2027-01-12"
        )
      )

      report = daily_report("2027-01-12")
      assert report["status"] == "open"
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 4000

      # A later close publishes that day as it stood, movement included.
      close_period!(conn, "2027-01-15", "op-keep-close-2")

      frozen = daily_report("2027-01-12")
      assert frozen["status"] == "closed"
      assert Map.put(frozen, "status", "open") == report
    end
  end

  describe "identifying late adjustments" do
    test "the day's total movement is the ordinary value plus the late value" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-mix")
      open_group!(conn, "g-mix-2")

      close_period!(conn, @cutoff, "op-mix-close")

      # An old-dated payment and its refundable cancellation — both pushed
      # to the first open day — alongside an ordinary same-day payment on
      # another group at the same property.
      assert [_late_pay, _late_cancel, _ordinary] =
               submit!(conn, [
                 payment_operation("g-mix", 2000,
                   operation_id: "op-mix-late-pay",
                   occurred_on: "2026-12-28"
                 ),
                 cancel_operation("g-mix",
                   operation_id: "op-mix-late-cancel",
                   occurred_on: "2026-12-29"
                 ),
                 payment_operation("g-mix-2", 4000,
                   operation_id: "op-mix-ordinary",
                   occurred_on: @first_open_day
                 )
               ])

      report = daily_report(@first_open_day)
      entry = cash_entry(report, "ams-canal")

      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 4000
      assert entry["movements"]["refunded_cents"] == 0

      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2000
      assert late_cash_entry(report, "ams-canal")["movements"]["refunded_cents"] == 2000

      # Closing = opening + the ordinary and the late totals together.
      assert entry["closing_held_cents"] == 0 + (4000 + 2000) - 2000
    end

    test "signed classifications survive even when their net effect is zero" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-signed")

      apply_op!(
        conn,
        payment_operation("g-signed", 100,
          operation_id: "op-signed-pay",
          occurred_on: "2027-01-02"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-signed",
          operation_id: "op-signed-cancel",
          occurred_on: "2027-01-03"
        )
      )

      close_period!(conn, @cutoff, "op-signed-close")

      apply_op!(
        conn,
        charge_back_operation("op-signed-pay",
          operation_id: "op-signed-charge",
          occurred_on: "2027-01-04"
        )
      )

      report = daily_report(@first_open_day)
      late = late_cash_entry(report, "ams-canal")

      assert late["movements"]["refunded_cents"] == -100
      assert late["movements"]["charged_back_cents"] == 100

      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 0

      assert entry["movements"] == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert entry["closing_held_cents"] == 0
    end

    test "the cash array is ordered by property_id and omits untouched properties" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-late-ams")
      open_group!(conn, "g-late-ber", property_id: "ber-lakes")
      open_group!(conn, "g-late-untouched", property_id: "cdg-frames")

      close_period!(conn, @cutoff, "op-late-close")

      assert [_ber, _ams] =
               submit!(conn, [
                 payment_operation("g-late-ber", 100,
                   operation_id: "op-late-ber-pay",
                   occurred_on: "2026-12-28"
                 ),
                 payment_operation("g-late-ams", 100,
                   operation_id: "op-late-ams-pay",
                   occurred_on: "2026-12-28"
                 )
               ])

      report = daily_report(@first_open_day)

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "ber-lakes"]

      # The credit object is always present, even with nothing late.
      assert report["late_adjustments"]["credit"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
    end

    test "credit movements moved by a close appear in the late credit object" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-late-credit")

      apply_op!(
        conn,
        payment_operation("g-late-credit", 100,
          operation_id: "op-late-credit-pay",
          occurred_on: "2027-01-02"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-late-credit",
          operation_id: "op-late-credit-cancel",
          occurred_on: "2027-01-03",
          refund_method: "hotel_credit"
        )
      )

      close_period!(conn, @cutoff, "op-late-credit-close")

      apply_op!(
        conn,
        charge_back_operation("op-late-credit-pay",
          operation_id: "op-late-credit-charge",
          occurred_on: "2027-01-04"
        )
      )

      report = daily_report(@first_open_day)

      assert report["late_adjustments"]["credit"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 110,
               "absorbed_cents" => 0
             }

      # The ordinary credit movements of the day stay empty; the closing
      # liability uses both.
      assert report["credit"]["movements"]["revoked_cents"] == 0
      assert report["credit"]["opening_liability_cents"] == 110
      assert report["credit"]["closing_liability_cents"] == 0

      # The closed conversion day keeps its published figures, cash and
      # credit alike.
      conversion_day = daily_report("2027-01-03")
      assert conversion_day["status"] == "closed"
      assert conversion_day["credit"]["movements"]["issued_cents"] == 110

      assert cash_entry(conversion_day, "ams-canal")["movements"]["converted_to_credit_cents"] ==
               100
    end
  end
end
