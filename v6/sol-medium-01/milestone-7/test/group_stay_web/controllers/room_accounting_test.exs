defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  test "funding fills rooms in original order and selected cancellation changes only those rooms",
       %{conn: conn} do
    post_ops(conn, [open("open-a", "group-a", "guest-a", [10_000, 10_000, 10_000])])

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
             post_ops(conn, [cash("pay-a", "group-a", 2_500)])

    before = group(conn, "group-a")

    assert Enum.map(before["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) ==
             [{2_000, 0}, {500, 0}, {0, 0}]

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-2"],
                 "refunded_cents" => 500,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             post_ops(conn, [
               %{
                 "operation_id" => "cancel-room-2",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-10",
                 "group_id" => "group-a",
                 "room_ids" => ["room-2"]
               }
             ])

    after_cancel = group(conn, "group-a")
    assert after_cancel["status"] == "active"
    assert after_cancel["lodging_total_cents"] == 20_000
    assert after_cancel["deposit_due_cents"] == 4_000
    assert after_cancel["deposit_paid_cents"] == 2_000
    assert after_cancel["outstanding_deposit_cents"] == 2_000

    assert Enum.map(after_cancel["rooms"], &{&1["status"], &1["cash_paid_cents"]}) ==
             [{"active", 2_000}, {"cancelled", 0}, {"active", 0}]

    assert ledger(conn) |> Map.take(["cash_held_cents", "cash_refunded_cents"]) == %{
             "cash_held_cents" => 2_000,
             "cash_refunded_cents" => 500
           }

    assert %{"results" => [%{"code" => "invalid_rooms"}]} =
             post_ops(conn, [
               %{
                 "operation_id" => "cancel-invalid",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-10",
                 "group_id" => "group-a",
                 "room_ids" => ["room-2", "room-2"]
               }
             ])
  end

  test "cancel_rooms returns original room order and rounds one combined credit bonus", %{
    conn: conn
  } do
    post_ops(conn, [open("open-round", "group-round", "guest-round", [25, 25, 25])])
    post_ops(conn, [cash("pay-round", "group-round", 15)])

    operation = %{
      "operation_id" => "cancel-round",
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-10",
      "group_id" => "group-round",
      "room_ids" => ["room-3", "room-1"],
      "refund_method" => "hotel_credit"
    }

    assert %{
             "results" => [
               %{
                 "cancelled_room_ids" => ["room-1", "room-3"],
                 "credit_issued_cents" => 11,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ]
           } = post_ops(conn, [operation])

    assert post_ops(conn, [operation]) == post_ops(conn, [operation])
    assert credit(conn, "guest-round")["available_cents"] == 11
  end

  test "cash reductions compose in reverse fill order and preserve the payment result", %{
    conn: conn
  } do
    post_ops(conn, [open("open-r", "group-r", "guest-r", [10_000, 10_000])])
    original = cash("pay-r", "group-r", 2_500)
    original_result = post_ops(conn, [original])
    post_ops(conn, [cash("pay-r2", "group-r", 1_000)])

    reduction = %{
      "operation_id" => "reduce-r",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => "pay-r",
      "amount_cents" => 700,
      "expected_revision" => 3
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "group-r",
                 "payment_operation_id" => "pay-r",
                 "amount_cents" => 700,
                 "outstanding_deposit_cents" => 1_200,
                 "revision" => 4
               }
             ]
           } = post_ops(conn, [reduction])

    assert Enum.map(group(conn, "group-r")["rooms"], & &1["cash_paid_cents"]) == [1_800, 1_000]
    assert post_ops(conn, [reduction]) == post_ops(conn, [reduction])
    assert post_ops(conn, [original]) == original_result

    assert payment(conn, "pay-r") == %{
             "payment_operation_id" => "pay-r",
             "original_group_id" => "group-r",
             "recorded_cents" => 2_500,
             "held_cents" => 1_800,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 700,
             "charged_back_cents" => 0
           }

    assert ledger(conn)["cash_reduced_cents"] == 700

    assert %{"results" => [%{"code" => "reduction_exceeds_held_cash"}]} =
             post_ops(conn, [
               Map.merge(reduction, %{
                 "operation_id" => "reduce-too-much",
                 "amount_cents" => 1_801,
                 "expected_revision" => 4
               })
             ])
  end

  test "chargeback preserves reductions and reopens active room deposits", %{conn: conn} do
    post_ops(conn, [open("open-cb", "group-cb", "guest-cb", [10_000])])
    post_ops(conn, [cash("pay-cb", "group-cb", 2_000)])

    post_ops(conn, [
      %{
        "operation_id" => "reduce-cb",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "pay-cb",
        "amount_cents" => 500
      }
    ])

    chargeback = %{
      "operation_id" => "charge-cb",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => "pay-cb",
      "expected_revision" => 3
    }

    assert %{"results" => [%{"charged_back_cents" => 1_500, "revision" => 4}]} =
             post_ops(conn, [chargeback])

    assert group(conn, "group-cb")["outstanding_deposit_cents"] == 2_000
    assert payment(conn, "pay-cb")["reduced_cents"] == 500
    assert payment(conn, "pay-cb")["charged_back_cents"] == 1_500
    assert ledger(conn)["cash_charged_back_cents"] == 1_500

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
             post_ops(conn, [
               Map.merge(chargeback, %{"operation_id" => "charge-again", "expected_revision" => 4})
             ])
  end

  test "converted-payment chargeback creates and later absorbs credit shortfall", %{conn: conn} do
    post_ops(conn, [open("open-source", "source", "guest-x", [5_000, 5_000])])
    post_ops(conn, [cash("pay-x1", "source", 1_000), cash("pay-x2", "source", 1_000)])

    post_ops(conn, [
      %{
        "operation_id" => "convert-x",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ])

    post_ops(conn, [open("open-dest", "dest", "guest-x", [11_000])])

    post_ops(conn, [
      %{
        "operation_id" => "apply-x",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-12",
        "group_id" => "dest",
        "amount_cents" => 2_200
      }
    ])

    source_revision = group(conn, "source")["revision"]

    assert %{"results" => [%{"charged_back_cents" => 1_000}]} =
             post_ops(conn, [
               %{
                 "operation_id" => "charge-x1",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-13",
                 "payment_operation_id" => "pay-x1",
                 "expected_revision" => source_revision
               }
             ])

    assert group(conn, "dest")["revision"] == 2

    assert ledger(conn)
           |> Map.take([
             "cash_converted_to_credit_cents",
             "cash_charged_back_cents",
             "credit_liability_cents",
             "credit_shortfall_cents"
           ]) == %{
             "cash_converted_to_credit_cents" => 1_000,
             "cash_charged_back_cents" => 1_000,
             "credit_liability_cents" => 2_200,
             "credit_shortfall_cents" => 1_100
           }

    post_ops(conn, [
      %{
        "operation_id" => "cancel-dest",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-14",
        "group_id" => "dest"
      }
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 1_100
    assert credit(conn, "guest-x")["available_cents"] == 1_100
  end

  test "payment reads distinguish missing and non-payment operations and stale revision wins", %{
    conn: conn
  } do
    post_ops(conn, [open("open-errors", "errors", "guest-errors", [10_000])])
    post_ops(conn, [cash("pay-errors", "errors", 1_000)])

    assert get(recycle(conn), ~p"/api/v1/payments/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}

    assert get(recycle(conn), ~p"/api/v1/payments/open-errors") |> json_response(422) ==
             %{"error" => %{"code" => "payment_not_reconcilable"}}

    assert %{"results" => [%{"code" => "stale_revision", "actual_revision" => 2}]} =
             post_ops(conn, [
               %{
                 "operation_id" => "stale-reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "pay-errors",
                 "amount_cents" => -1,
                 "expected_revision" => 1
               }
             ])
  end

  defp open(operation_id, group_id, guest_id, rates) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" =>
        rates
        |> Enum.with_index(1)
        |> Enum.map(fn {rate, index} ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => rate}
        end)
    }
  end

  defp cash(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp post_ops(conn, operations) do
    conn
    |> recycle()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp group(conn, group_id) do
    get(recycle(conn), "/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, operation_id) do
    get(recycle(conn), "/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id) do
    get(recycle(conn), "/api/v1/guests/#{guest_id}/credit?on=2026-10-15")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    get(recycle(conn), "/api/v1/ledger?on=2026-10-15") |> json_response(200) |> Map.fetch!("data")
  end
end
