defmodule GroupStayWeb.DailyFinanceReportTest do
  @moduledoc """
  Product request 06: the daily finance report.

  `start_finance_reporting` records the durable inception point — the
  opening position snapshot of everything committed before it — and every
  operation processed afterwards posts its finance effects to the
  append-only event log. The daily report chains balances from the
  inception position, shows the day's movements per property and the
  company-wide credit object, derives hotel-credit expiry from the lots'
  current balances, and reconciles with the current ledger views. Reading
  a report never changes anything.
  """

  use GroupStayWeb.ConnCase, async: true

  @guest "guest-22"
  @booked_on "2026-10-03"
  @arrival_on "2027-06-10"
  @departure_on "2027-06-13"
  @starts_on "2027-01-01"

  # Two rooms, three nights at 10000: lodging 60000, flexible deposit 6000
  # per room, 12000 for the group; advance purchase deposits 30000 each.

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
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
        ])
    }
  end

  defp payment_operation(group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-pay-#{group_id}-#{amount_cents}"),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id
    }
    |> maybe_put("refund_method", Keyword.get(opts, :refund_method))
  end

  defp credit_operation(group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-credit-#{group_id}-#{amount_cents}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_operation(source_group_id, destination_group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" =>
        Keyword.get(opts, :operation_id, "op-transfer-#{source_group_id}-#{amount_cents}"),
      "type" => "transfer_deposit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_operation(payment_operation_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-reduce-#{payment_operation_id}"),
      "type" => "reduce_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_operation(payment_operation_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-charge-#{payment_operation_id}"),
      "type" => "charge_back_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id
    }
  end

  defp start_operation(starts_on, operation_id \\ "op-start") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "occurred_on" => @booked_on,
      "starts_on" => starts_on
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

  defp start_reporting!(conn, starts_on \\ @starts_on, operation_id \\ "op-start") do
    apply_op!(conn, start_operation(starts_on, operation_id))
  end

  defp daily_report(date) do
    conn = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp daily_report_error(date) do
    conn = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    {conn.status, json_response(conn, conn.status)}
  end

  defp ledger(on \\ nil) do
    query = if on, do: "?on=#{on}", else: ""
    conn = get(build_conn(), "/api/v1/ledger#{query}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
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

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  describe "start_finance_reporting" do
    test "the first applied start returns exactly the three result fields" do
      conn = build_conn()

      assert start_reporting!(conn, "2027-01-01", "op-start-1") == %{
               "operation_id" => "op-start-1",
               "status" => "applied",
               "starts_on" => "2027-01-01"
             }
    end

    test "a different start is rejected; a retry replays the original result" do
      conn = build_conn()
      started = start_reporting!(conn, "2027-01-01", "op-start-2")

      assert [second] = submit!(conn, [start_operation("2027-02-01", "op-start-3")])
      assert second["code"] == "reporting_already_started"

      assert [retry] = submit!(conn, [start_operation("2027-01-01", "op-start-2")])
      assert retry == started
    end

    test "an invalid or missing starts_on is rejected as invalid_reporting_date" do
      conn = build_conn()

      assert [invalid] = submit!(conn, [start_operation("not-a-date", "op-start-bad")])
      assert invalid["code"] == "invalid_reporting_date"

      assert [missing] =
               submit!(conn, [
                 Map.delete(start_operation("2027-01-01", "op-start-gone"), "starts_on")
               ])

      assert missing["code"] == "invalid_reporting_date"
    end
  end

  describe "the daily report endpoint" do
    test "a missing or invalid date is a 422 invalid_reporting_date" do
      conn = get(build_conn(), "/api/v1/finance/daily-report")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = get(build_conn(), "/api/v1/finance/daily-report?date=2027-1-1")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "before reporting has started every date is a 404 report_not_available" do
      assert daily_report_error("2027-01-01") ==
               {404, %{"error" => %{"code" => "report_not_available"}}}
    end

    test "a date before starts_on is a 404 report_not_available" do
      conn = build_conn()
      start_reporting!(conn, "2027-01-01")

      assert daily_report_error("2026-12-31") ==
               {404, %{"error" => %{"code" => "report_not_available"}}}
    end
  end

  describe "the opening position" do
    test "includes operations already committed, even occurred_on on or after starts_on" do
      conn = build_conn()
      open_group!(conn, "g-opening")

      apply_op!(conn, payment_operation("g-opening", 5000, occurred_on: "2027-01-05"))
      start_reporting!(conn, "2027-01-01")

      report = daily_report("2027-01-01")

      assert report == %{
               "date" => "2027-01-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 5000,
                   "movements" => zero_cash_movements(),
                   "closing_held_cents" => 5000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{"cash" => [], "credit" => zero_credit_movements()}
             }
    end

    test "within one batch, operations before the start open and operations after move" do
      conn = build_conn()

      assert [_open, _before, _start, _after] =
               submit!(conn, [
                 open_operation("g-batch-split"),
                 payment_operation("g-batch-split", 5000,
                   operation_id: "op-split-before",
                   occurred_on: "2027-01-02"
                 ),
                 start_operation("2027-01-01", "op-split-start"),
                 payment_operation("g-batch-split", 3000,
                   operation_id: "op-split-after",
                   occurred_on: "2027-01-02"
                 )
               ])

      # The payment before the start is part of the opening position; the
      # one after posts on the later of occurred_on and starts_on.
      first = daily_report("2027-01-01")
      assert cash_entry(first, "ams-canal")["opening_held_cents"] == 5000
      assert cash_entry(first, "ams-canal")["movements"] == zero_cash_movements()

      second = daily_report("2027-01-02")
      assert cash_entry(second, "ams-canal")["opening_held_cents"] == 5000

      assert cash_entry(second, "ams-canal")["movements"] ==
               %{zero_cash_movements() | "received_cents" => 3000}

      assert cash_entry(second, "ams-canal")["closing_held_cents"] == 8000
    end
  end

  describe "posting dates" do
    test "an operation before starts_on posts on starts_on itself" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-early")

      apply_op!(conn, payment_operation("g-early", 5000, occurred_on: "2026-12-20"))

      report = daily_report("2027-01-01")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 5000

      before = daily_report_error("2026-12-31")
      assert before == {404, %{"error" => %{"code" => "report_not_available"}}}
    end
  end

  describe "cash movements" do
    test "a refundable cancellation posts refunded cash and empties the property" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-refund")

      apply_op!(conn, payment_operation("g-refund", 12_000, occurred_on: "2027-01-02"))
      apply_op!(conn, cancel_operation("g-refund", occurred_on: "2027-01-04"))

      report = daily_report("2027-01-04")
      entry = cash_entry(report, "ams-canal")

      assert entry["opening_held_cents"] == 12_000
      assert entry["movements"] == %{zero_cash_movements() | "refunded_cents" => 12_000}
      assert entry["closing_held_cents"] == 0

      assert ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 12_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "a non-refundable cancellation posts retained cash" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-retain", rate_plan: "advance_purchase")

      apply_op!(conn, payment_operation("g-retain", 5000, occurred_on: "2027-01-02"))
      apply_op!(conn, cancel_operation("g-retain", occurred_on: "2027-01-03"))

      report = daily_report("2027-01-03")
      entry = cash_entry(report, "ams-canal")

      assert entry["movements"] == %{zero_cash_movements() | "retained_cents" => 5000}
      assert entry["closing_held_cents"] == 0
      assert ledger()["cash_retained_cents"] == 5000
    end

    test "a transfer posts transferred-out and transferred-in at both properties" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-tr-src")
      open_group!(conn, "g-tr-dst", property_id: "ber-lakes")

      apply_op!(conn, payment_operation("g-tr-src", 5000, occurred_on: "2027-01-02"))

      apply_op!(
        conn,
        transfer_operation("g-tr-src", "g-tr-dst", 2000, occurred_on: "2027-01-03")
      )

      report = daily_report("2027-01-03")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => %{zero_cash_movements() | "transferred_out_cents" => 2000},
                 "closing_held_cents" => 3000
               },
               %{
                 "property_id" => "ber-lakes",
                 "opening_held_cents" => 0,
                 "movements" => %{zero_cash_movements() | "transferred_in_cents" => 2000},
                 "closing_held_cents" => 2000
               }
             ]

      # The day's transferred-in and transferred-out totals are equal, and
      # the closing balances reconcile with the ledger's current cash held.
      transferred_in =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_in_cents"]) |> Enum.sum()

      transferred_out =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_out_cents"]) |> Enum.sum()

      assert transferred_in == 2000
      assert transferred_out == 2000
      assert ledger()["cash_held_cents"] == 5000
      assert Enum.map(report["cash"], & &1["closing_held_cents"]) |> Enum.sum() == 5000
    end

    test "a reduction posts reduced cash at the property where it was held" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-reduce")

      apply_op!(
        conn,
        payment_operation("g-reduce", 5000, occurred_on: "2027-01-02", operation_id: "op-rd-pay")
      )

      apply_op!(conn, reduce_operation("op-rd-pay", 2000, occurred_on: "2027-01-03"))

      report = daily_report("2027-01-03")
      entry = cash_entry(report, "ams-canal")

      assert entry["opening_held_cents"] == 5000
      assert entry["movements"] == %{zero_cash_movements() | "reduced_cents" => 2000}
      assert entry["closing_held_cents"] == 3000
      assert ledger()["cash_reduced_cents"] == 2000
    end

    test "a charge-back reverses the refund and posts charged-back cash" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-cb")

      apply_op!(
        conn,
        payment_operation("g-cb", 100, occurred_on: "2027-01-02", operation_id: "op-cb-pay")
      )

      apply_op!(conn, cancel_operation("g-cb", occurred_on: "2027-01-03"))

      refund_day = daily_report("2027-01-03")
      assert cash_entry(refund_day, "ams-canal")["movements"]["refunded_cents"] == 100

      apply_op!(conn, charge_back_operation("op-cb-pay", occurred_on: "2027-01-04"))

      report = daily_report("2027-01-04")
      entry = cash_entry(report, "ams-canal")

      assert entry["movements"] == %{
               zero_cash_movements()
               | "refunded_cents" => -100,
                 "charged_back_cents" => 100
             }

      assert entry["opening_held_cents"] == 0
      assert entry["closing_held_cents"] == 0

      assert ledger()["cash_refunded_cents"] == 0
      assert ledger()["cash_charged_back_cents"] == 100
    end
  end

  describe "credit movements" do
    test "a conversion posts converted cash and issues the lot's credit" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-convert")

      apply_op!(
        conn,
        payment_operation("g-convert", 100,
          occurred_on: "2027-01-02",
          operation_id: "op-conv-pay"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-convert", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      report = daily_report("2027-01-05")

      assert cash_entry(report, "ams-canal")["movements"] ==
               %{zero_cash_movements() | "converted_to_credit_cents" => 100}

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{zero_credit_movements() | "issued_cents" => 110},
               "closing_liability_cents" => 110
             }

      assert ledger()["credit_liability_cents"] == 110
    end

    test "unused credit expires the day after expires_on with no operation that day" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-expire")

      apply_op!(
        conn,
        payment_operation("g-expire", 100, occurred_on: "2027-01-02", operation_id: "op-exp-pay")
      )

      apply_op!(
        conn,
        cancel_operation("g-expire", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      # The lot expires_on is 2028-01-06; the movement lands on 2028-01-07.
      expiry_eve = daily_report("2028-01-06")
      assert expiry_eve["credit"]["closing_liability_cents"] == 110

      expiry = daily_report("2028-01-07")
      assert expiry["credit"]["opening_liability_cents"] == 110

      assert expiry["credit"]["movements"] ==
               %{zero_credit_movements() | "expired_cents" => 110}

      assert expiry["credit"]["closing_liability_cents"] == 0
    end

    test "applying hotel credit has no movement column" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-apply")
      open_group!(conn, "g-apply-donor", operation_id: "op-open-g-apply-donor")

      apply_op!(
        conn,
        payment_operation("g-apply-donor", 100,
          occurred_on: "2027-01-02",
          operation_id: "op-apply-donor-pay"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-apply-donor",
          occurred_on: "2027-01-03",
          refund_method: "hotel_credit"
        )
      )

      apply_op!(conn, credit_operation("g-apply", 110, occurred_on: "2027-01-04"))

      report = daily_report("2027-01-04")

      assert report["credit"]["movements"] == zero_credit_movements()
      assert report["credit"]["opening_liability_cents"] == 110
      assert report["credit"]["closing_liability_cents"] == 110
    end

    test "a non-refundable cancellation of credit-funded rooms consumes the credit" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-consume", rate_plan: "advance_purchase")
      open_group!(conn, "g-consume-donor")

      apply_op!(
        conn,
        payment_operation("g-consume-donor", 100,
          occurred_on: "2027-01-02",
          operation_id: "op-consume-donor-pay"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-consume-donor",
          occurred_on: "2027-01-03",
          refund_method: "hotel_credit"
        )
      )

      apply_op!(conn, credit_operation("g-consume", 110, occurred_on: "2027-01-04"))
      apply_op!(conn, cancel_operation("g-consume", occurred_on: "2027-01-05"))

      report = daily_report("2027-01-05")

      assert report["credit"] == %{
               "opening_liability_cents" => 110,
               "movements" => %{zero_credit_movements() | "consumed_cents" => 110},
               "closing_liability_cents" => 0
             }

      assert ledger()["credit_liability_cents"] == 0
    end

    test "a charge-back of converted cash revokes the entitlement's credit" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-revoke")

      apply_op!(
        conn,
        payment_operation("g-revoke", 100,
          occurred_on: "2027-01-02",
          operation_id: "op-revoke-pay"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-revoke", occurred_on: "2027-01-03", refund_method: "hotel_credit")
      )

      apply_op!(conn, charge_back_operation("op-revoke-pay", occurred_on: "2027-01-04"))

      report = daily_report("2027-01-04")

      assert cash_entry(report, "ams-canal")["movements"] == %{
               zero_cash_movements()
               | "converted_to_credit_cents" => -100,
                 "charged_back_cents" => 100
             }

      assert report["credit"] == %{
               "opening_liability_cents" => 110,
               "movements" => %{zero_credit_movements() | "revoked_cents" => 110},
               "closing_liability_cents" => 0
             }

      assert ledger()["credit_liability_cents"] == 0
    end

    test "credit restoring to a shortfalled lot is absorbed" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-absorb-donor")
      open_group!(conn, "g-absorb", rate_plan: "flexible")

      # Convert 100 into a 110-cent lot, spend 50 of it, and charge the
      # payment back: 60 is revoked and 50 becomes unrecovered clawback.
      apply_op!(
        conn,
        payment_operation("g-absorb-donor", 100,
          occurred_on: "2027-01-02",
          operation_id: "op-absorb-pay"
        )
      )

      apply_op!(
        conn,
        cancel_operation("g-absorb-donor",
          occurred_on: "2027-01-03",
          refund_method: "hotel_credit"
        )
      )

      apply_op!(conn, credit_operation("g-absorb", 50, occurred_on: "2027-01-04"))
      apply_op!(conn, charge_back_operation("op-absorb-pay", occurred_on: "2027-01-05"))

      # A refundable cancellation of the group still holding the remaining
      # 50 restores it into the shortfalled lot, where it is absorbed.
      apply_op!(conn, cancel_operation("g-absorb", occurred_on: "2027-01-06"))

      report = daily_report("2027-01-06")

      assert report["credit"]["movements"] ==
               %{zero_credit_movements() | "absorbed_cents" => 50}

      assert report["credit"]["closing_liability_cents"] == 0
      assert ledger()["credit_liability_cents"] == 0
      assert ledger()["credit_shortfall_cents"] == 0
    end

    test "a correction follows transferred cash to the property where it is held" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-follow-src")
      open_group!(conn, "g-follow-dst", property_id: "ber-lakes")

      apply_op!(
        conn,
        payment_operation("g-follow-src", 5000,
          occurred_on: "2027-01-02",
          operation_id: "op-follow-pay"
        )
      )

      apply_op!(
        conn,
        transfer_operation("g-follow-src", "g-follow-dst", 2000, occurred_on: "2027-01-03")
      )

      apply_op!(conn, reduce_operation("op-follow-pay", 1000, occurred_on: "2027-01-04"))

      report = daily_report("2027-01-04")

      # The reduction removed the destination property's most recent
      # funding; the payment's original property is untouched.
      assert cash_entry(report, "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 3000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 3000
             }

      assert cash_entry(report, "ber-lakes") == %{
               "property_id" => "ber-lakes",
               "opening_held_cents" => 2000,
               "movements" => %{zero_cash_movements() | "reduced_cents" => 1000},
               "closing_held_cents" => 1000
             }

      assert ledger()["cash_reduced_cents"] == 1000
    end
  end

  describe "durability and idempotency of movements" do
    test "a rejected operation leaves no movement, and a retry posts once" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-once")

      assert [applied, rejected] =
               submit!(conn, [
                 payment_operation("g-once", 5000,
                   operation_id: "op-once-pay",
                   occurred_on: "2027-01-02"
                 ),
                 payment_operation("g-once", 25_000,
                   operation_id: "op-once-over",
                   occurred_on: "2027-01-02"
                 )
               ])

      assert applied["status"] == "applied"
      assert rejected["code"] == "payment_exceeds_outstanding"

      assert [replay] =
               submit!(conn, [
                 payment_operation("g-once", 5000,
                   operation_id: "op-once-pay",
                   occurred_on: "2027-01-02"
                 )
               ])

      assert replay == applied

      report = daily_report("2027-01-02")
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 5000

      next = daily_report("2027-01-03")
      assert cash_entry(next, "ams-canal")["opening_held_cents"] == 5000
    end

    test "reading reports in any order, or repeatedly, never changes them" do
      conn = build_conn()
      start_reporting!(conn)
      open_group!(conn, "g-order")

      apply_op!(conn, payment_operation("g-order", 5000, occurred_on: "2027-01-02"))

      later_first = daily_report("2027-01-03")
      day = daily_report("2027-01-02")

      assert daily_report("2027-01-02") == day
      assert daily_report("2027-01-03") == later_first
      assert cash_entry(later_first, "ams-canal")["opening_held_cents"] == 5000
    end
  end
end
