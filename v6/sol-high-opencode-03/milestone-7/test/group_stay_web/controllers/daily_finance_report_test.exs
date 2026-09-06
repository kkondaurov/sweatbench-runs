defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "starts reporting in operation order and validates report availability" do
    before_start = cash_operation("pay-before", "alpha", 1_000, "2026-10-08", 1)
    start = start_operation("start", "2026-10-05")
    after_start = cash_operation("pay-after", "alpha", 500, "2026-10-03", 2)

    assert [_, _, started, paid] =
             submit([
               open_operation("open-alpha", "alpha", "ams-canal"),
               before_start,
               start,
               after_start
             ])

    assert started == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-10-05"
           }

    assert paid["status"] == "applied"

    assert report("2026-10-05") == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(%{"received_cents" => 500}),
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => credit_movements(),
               "closing_liability_cents" => 0
             },
             "late_adjustments" => late_adjustments()
           }

    assert report("2026-10-05") == report("2026-10-05")
    assert submit([start]) == [started]

    assert [already_started] = submit([start_operation("other-start", "2026-10-06")])
    assert already_started["code"] == "reporting_already_started"

    assert json_response(get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-04"), 404) ==
             %{"error" => %{"code" => "report_not_available"}}

    for path <- [
          "/api/v1/finance/daily-report",
          "/api/v1/finance/daily-report?date=bad-date"
        ] do
      assert json_response(get(build_conn(), path), 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end
  end

  test "rejects invalid reporting starts durably" do
    missing = %{"operation_id" => "missing", "type" => "start_finance_reporting"}
    invalid = start_operation("invalid", "2026-02-30")

    assert [missing_result, invalid_result] = submit([missing, invalid])
    assert missing_result["code"] == "invalid_reporting_date"
    assert invalid_result["code"] == "invalid_reporting_date"
    assert submit([invalid]) == [invalid_result]

    assert json_response(get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-05"), 404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "attributes transfers, settlements, and chargeback reclassification by property" do
    assert [_, _, _, _] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open-source", "source", "zurich"),
               open_operation("open-destination", "destination", "amsterdam"),
               cash_operation("pay", "source", 1_500, "2026-10-02", 1)
             ])

    assert [_, cancelled] =
             submit([
               transfer_operation("transfer", "source", "destination", 1_000, "2026-10-03", 2, 1),
               cancel_operation("refund", "destination", "2026-10-04", 2)
             ])

    assert cancelled["refunded_cents"] == 1_000

    assert [charged_back] =
             submit([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               }
             ])

    assert charged_back["charged_back_cents"] == 1_500

    assert report("2026-10-03")["cash"] == [
             %{
               "property_id" => "amsterdam",
               "opening_held_cents" => 0,
               "movements" => cash_movements(%{"transferred_in_cents" => 1_000}),
               "closing_held_cents" => 1_000
             },
             %{
               "property_id" => "zurich",
               "opening_held_cents" => 1_500,
               "movements" => cash_movements(%{"transferred_out_cents" => 1_000}),
               "closing_held_cents" => 500
             }
           ]

    assert report("2026-10-05")["cash"] == [
             %{
               "property_id" => "amsterdam",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{
                   "refunded_cents" => -1_000,
                   "charged_back_cents" => 1_000
                 }),
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "zurich",
               "opening_held_cents" => 500,
               "movements" => cash_movements(%{"charged_back_cents" => 500}),
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports reductions where transferred cash is held and does not duplicate retries" do
    assert [_, _, _, _] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open-source", "source", "zurich"),
               open_operation("open-destination", "destination", "amsterdam"),
               cash_operation("pay", "source", 1_500, "2026-10-02", 1)
             ])

    assert [_] =
             submit([
               transfer_operation(
                 "transfer",
                 "source",
                 "destination",
                 1_000,
                 "2026-10-03",
                 2,
                 1
               )
             ])

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-04",
      "payment_operation_id" => "pay",
      "amount_cents" => 700,
      "expected_revision" => 3
    }

    assert [result] = submit([reduction])
    report = report("2026-10-04")
    assert submit([reduction]) == [result]
    assert report("2026-10-04") == report

    assert report["cash"] == [
             %{
               "property_id" => "amsterdam",
               "opening_held_cents" => 1_000,
               "movements" => cash_movements(%{"reduced_cents" => 700}),
               "closing_held_cents" => 300
             },
             %{
               "property_id" => "zurich",
               "opening_held_cents" => 500,
               "movements" => cash_movements(%{}),
               "closing_held_cents" => 500
             }
           ]

    missing_date = Map.merge(reduction, %{"operation_id" => "undated", "expected_revision" => 4})
    missing_date = Map.delete(missing_date, "occurred_on")
    assert [rejected] = submit([missing_date])
    assert rejected["code"] == "invalid_operation"
    assert report("2026-10-01")["cash"] == []
  end

  test "reports credit issuance, application, consumption, and automatic expiry" do
    assert [_, _, _, issued, _, applied, consumed] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open-source", "source", "source-property"),
               cash_operation("pay-source", "source", 1_000, "2026-10-02", 1),
               cancel_operation("issue", "source", "2026-10-02", 2, "hotel_credit"),
               open_operation("open-target", "target", "target-property", "advance_purchase"),
               credit_operation("apply", "target", 500, "2026-10-03", 1),
               cancel_operation("consume", "target", "2026-10-04", 2)
             ])

    assert issued["credit_issued_cents"] == 1_100
    assert applied["status"] == "applied"
    assert consumed["status"] == "applied"

    assert report("2026-10-02")["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(%{"issued_cents" => 1_100}),
             "closing_liability_cents" => 1_100
           }

    assert report("2026-10-03")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(),
             "closing_liability_cents" => 1_100
           }

    assert report("2026-10-04")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(%{"consumed_cents" => 500}),
             "closing_liability_cents" => 600
           }

    assert report("2027-10-03")["credit"] == %{
             "opening_liability_cents" => 600,
             "movements" => credit_movements(%{"expired_cents" => 600}),
             "closing_liability_cents" => 0
           }
  end

  test "reports entitlement revocation and later shortfall absorption" do
    assert [_, _, _, _, _, _] =
             submit([
               start_operation("start", "2026-10-01"),
               open_operation("open-source", "source", "source-property"),
               cash_operation("pay-source", "source", 1_000, "2026-10-02", 1),
               cancel_operation("issue", "source", "2026-10-02", 2, "hotel_credit"),
               open_operation("open-target", "target", "target-property"),
               credit_operation("apply", "target", 1_000, "2026-10-03", 1)
             ])

    assert [charged_back, cancelled] =
             submit([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-04",
                 "payment_operation_id" => "pay-source",
                 "expected_revision" => 3
               },
               cancel_operation("restore", "target", "2026-10-05", 2)
             ])

    assert charged_back["status"] == "applied"
    assert cancelled["status"] == "applied"

    assert report("2026-10-04")["credit"] == %{
             "opening_liability_cents" => 1_100,
             "movements" => credit_movements(%{"revoked_cents" => 100}),
             "closing_liability_cents" => 1_000
           }

    assert report("2026-10-05")["credit"] == %{
             "opening_liability_cents" => 1_000,
             "movements" => credit_movements(%{"absorbed_cents" => 1_000}),
             "closing_liability_cents" => 0
           }
  end

  test "a late backdated application reverses only the affected prior expiry" do
    assert [_, _, _, _] =
             submit([
               open_operation("open-source", "source", "source-property"),
               cash_operation("pay-source", "source", 1_000, "2025-01-01", 1),
               cancel_operation("issue", "source", "2025-01-01", 2, "hotel_credit"),
               open_operation("open-target", "target", "target-property")
             ])

    assert [_] = submit([start_operation("start", "2026-10-01")])

    assert [applied] =
             submit([credit_operation("apply-old", "target", 500, "2025-12-31", 1)])

    assert applied["status"] == "applied"

    assert report("2026-10-01")["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(%{"expired_cents" => -500}),
             "closing_liability_cents" => 500
           }
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

  defp open_operation(operation_id, group_id, property_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => property_id,
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => rate_plan,
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

  defp credit_operation(operation_id, group_id, amount, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
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

  defp transfer_operation(
         operation_id,
         source_id,
         destination_id,
         amount,
         occurred_on,
         source_revision,
         destination_revision
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_id,
      "destination_group_id" => destination_id,
      "amount_cents" => amount,
      "expected_revision" => source_revision,
      "destination_expected_revision" => destination_revision
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
      overrides
    )
  end

  defp credit_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end

  defp late_adjustments do
    %{"cash" => [], "credit" => credit_movements()}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
