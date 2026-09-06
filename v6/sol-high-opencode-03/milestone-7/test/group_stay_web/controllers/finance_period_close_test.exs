defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  test "validates closes and durably replays the applied result" do
    close = close_operation("close", "2026-10-05")

    assert [before_start] = submit([close])
    assert before_start["code"] == "invalid_period"
    assert submit([close]) == [before_start]

    assert [_] = submit([start_operation("start", "2026-10-05")])

    assert [missing, invalid, before_inception, no_following_day] =
             submit([
               %{"operation_id" => "missing", "type" => "close_finance_period"},
               close_operation("invalid", "2026-02-30"),
               close_operation("early", "2026-10-04"),
               close_operation("last-date", "9999-12-31")
             ])

    assert Enum.all?(
             [missing, invalid, before_inception, no_following_day],
             &(&1["code"] == "invalid_period")
           )

    applied_close = close_operation("applied-close", "2026-10-05")

    assert [applied] = submit([applied_close])

    assert applied == %{
             "operation_id" => "applied-close",
             "status" => "applied",
             "period_end_on" => "2026-10-05"
           }

    assert submit([applied_close]) == [applied]

    assert [same, earlier] =
             submit([
               close_operation("same", "2026-10-05"),
               close_operation("earlier", "2026-10-04")
             ])

    assert same["code"] == "invalid_period"
    assert earlier["code"] == "invalid_period"

    assert [conflict] = submit([close_operation("applied-close", "2026-10-06")])
    assert conflict["code"] == "operation_id_conflict"

    assert report("2026-10-05")["status"] == "closed"
    assert report("2026-10-06")["status"] == "open"
  end

  test "uses operation order around closes and keeps published data stable" do
    assert [_, _, _, closed, late_payment] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open", "alpha", "ams-canal"),
               cash_operation("pay-before", "alpha", 1_000, "2026-10-02", 1),
               close_operation("close-2", "2026-10-02"),
               cash_operation("pay-late", "alpha", 500, "2026-10-01", 2)
             ])

    assert closed["status"] == "applied"
    assert late_payment["status"] == "applied"

    published = report("2026-10-02")
    first_open = report("2026-10-03")

    assert published["status"] == "closed"
    assert published["cash"] == [cash_entry("ams-canal", 0, %{received_cents: 1_000}, 1_000)]
    assert published["late_adjustments"] == late_adjustments()

    assert first_open["status"] == "open"
    assert first_open["cash"] == [cash_entry("ams-canal", 1_000, %{}, 1_500)]

    assert first_open["late_adjustments"] ==
             late_adjustments([
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{received_cents: 500})
               }
             ])

    assert [ordinary_payment, _later_close, late_chargeback] =
             submit([
               cash_operation("pay-open", "alpha", 500, "2026-10-04", 3),
               close_operation("close-3", "2026-10-03"),
               %{
                 "operation_id" => "chargeback-late",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-01",
                 "payment_operation_id" => "pay-before",
                 "expected_revision" => 4
               }
             ])

    assert ordinary_payment["status"] == "applied"
    assert late_chargeback["status"] == "applied"
    assert report("2026-10-02") == published
    assert report("2026-10-03") == Map.put(first_open, "status", "closed")

    assert report("2026-10-04") == %{
             "date" => "2026-10-04",
             "status" => "open",
             "cash" => [cash_entry("ams-canal", 1_500, %{received_cents: 500}, 1_000)],
             "credit" => credit_entry(0, %{}, 0),
             "late_adjustments" =>
               late_adjustments([
                 %{
                   "property_id" => "ams-canal",
                   "movements" => cash_movements(%{charged_back_cents: 1_000})
                 }
               ])
           }
  end

  test "keeps signed late cash classifications and reports late credit movements" do
    assert [_, _, _, _, _, _] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open-refund", "refund", "amsterdam"),
               cash_operation("pay-refund", "refund", 100, "2026-10-02", 1),
               cancel_operation("refund", "refund", "2026-10-02", 2),
               open_operation("open-credit", "credit", "zurich"),
               cash_operation("pay-credit", "credit", 1_000, "2026-10-02", 1)
             ])

    assert [_, _] =
             submit([
               cancel_operation("issue", "credit", "2026-10-02", 2, "hotel_credit"),
               close_operation("close", "2026-10-02")
             ])

    assert [refund_chargeback, credit_chargeback] =
             submit([
               chargeback_operation("chargeback-refund", "pay-refund", "2026-10-01", 3),
               chargeback_operation("chargeback-credit", "pay-credit", "2026-10-01", 3)
             ])

    assert refund_chargeback["status"] == "applied"
    assert credit_chargeback["status"] == "applied"

    day = report("2026-10-03")

    assert day["cash"] == [
             cash_entry("amsterdam", 0, %{}, 0),
             cash_entry("zurich", 0, %{}, 0)
           ]

    assert day["credit"] == credit_entry(1_100, %{}, 0)

    assert day["late_adjustments"] ==
             late_adjustments(
               [
                 %{
                   "property_id" => "amsterdam",
                   "movements" => cash_movements(%{refunded_cents: -100, charged_back_cents: 100})
                 },
                 %{
                   "property_id" => "zurich",
                   "movements" =>
                     cash_movements(%{
                       converted_to_credit_cents: -1_000,
                       charged_back_cents: 1_000
                     })
                 }
               ],
               %{revoked_cents: 1_100}
             )
  end

  test "does not rewrite a closed automatic credit expiry" do
    assert [_, _, _, _, _] =
             submit([
               open_operation("open-source", "source", "source-property"),
               cash_operation("pay-source", "source", 1_000, "2025-01-01", 1),
               cancel_operation("issue", "source", "2025-01-01", 2, "hotel_credit"),
               open_operation("open-target", "target", "target-property"),
               start_operation("start", "2026-01-01")
             ])

    assert [_] = submit([close_operation("close", "2026-01-02")])
    published = report("2026-01-02")

    assert published["credit"] == credit_entry(1_100, %{expired_cents: 1_100}, 0)

    assert [applied] =
             submit([
               %{
                 "operation_id" => "apply-late",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2025-12-31",
                 "group_id" => "target",
                 "amount_cents" => 500,
                 "expected_revision" => 1
               }
             ])

    assert applied["status"] == "applied"
    assert report("2026-01-02") == published

    assert report("2026-01-03")["credit"] == credit_entry(0, %{}, 500)

    assert report("2026-01-03")["late_adjustments"] ==
             late_adjustments([], %{expired_cents: -500})
  end

  test "balances late transfers by property in sorted order" do
    assert [_, _, _, _, _] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open-source", "source", "zurich"),
               open_operation("open-destination", "destination", "amsterdam"),
               cash_operation("pay", "source", 1_000, "2026-10-01", 1),
               close_operation("close", "2026-10-01")
             ])

    assert [transferred] =
             submit([
               %{
                 "operation_id" => "transfer-late",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-01",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 500,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               }
             ])

    assert transferred["status"] == "applied"
    day = report("2026-10-02")

    assert day["cash"] == [
             cash_entry("amsterdam", 0, %{}, 500),
             cash_entry("zurich", 1_000, %{}, 500)
           ]

    assert day["late_adjustments"] ==
             late_adjustments([
               %{
                 "property_id" => "amsterdam",
                 "movements" => cash_movements(%{transferred_in_cents: 500})
               },
               %{
                 "property_id" => "zurich",
                 "movements" => cash_movements(%{transferred_out_cents: 500})
               }
             ])
  end

  defp submit(operations) do
    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    json_response(conn, 200)["results"]
  end

  defp report(date) do
    json_response(get(build_conn(), "/api/v1/finance/daily-report?date=#{date}"), 200)["data"]
  end

  defp start_operation(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_operation(operation_id, group_id, property_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash_operation(operation_id, group_id, amount, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, expected_revision, method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
    |> maybe_put("refund_method", method)
  end

  defp chargeback_operation(operation_id, payment_operation_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp cash_entry(property_id, opening, movement_overrides, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => cash_movements(movement_overrides),
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, movement_overrides, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movement_overrides),
      "closing_liability_cents" => closing
    }
  end

  defp cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      stringify_keys(overrides)
    )
  end

  defp credit_movements(overrides) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      stringify_keys(overrides)
    )
  end

  defp late_adjustments(cash \\ [], credit_overrides \\ %{}) do
    %{"cash" => cash, "credit" => credit_movements(credit_overrides)}
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
