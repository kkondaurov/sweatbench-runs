defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  test "allocates by room, cancels selected rooms, reduces cash, and reconciles payments" do
    assert [_, first, second] =
             submit([
               open_operation("open", "group", 3),
               cash_operation("pay-1", "group", 2_500, 1),
               cash_operation("pay-2", "group", 2_500, 2)
             ])

    assert first["revision"] == 2
    assert second["revision"] == 3

    assert room_balances("group") == [
             {"room-1", "active", 2_000, 2_000, 0},
             {"room-2", "active", 2_000, 2_000, 0},
             {"room-3", "active", 2_000, 1_000, 0}
           ]

    assert [reduced] =
             submit([
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-1",
                 "amount_cents" => 700,
                 "expected_revision" => 3
               }
             ])

    assert reduced == %{
             "operation_id" => "reduce",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group",
             "amount_cents" => 700,
             "outstanding_deposit_cents" => 1_700,
             "revision" => 4
           }

    assert room_balances("group") == [
             {"room-1", "active", 2_000, 1_800, 0},
             {"room-2", "active", 2_000, 1_500, 0},
             {"room-3", "active", 2_000, 1_000, 0}
           ]

    assert [cancelled] =
             submit([
               %{
                 "operation_id" => "cancel-selected",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group",
                 "room_ids" => ["room-3", "room-1"],
                 "expected_revision" => 4
               }
             ])

    assert cancelled == %{
             "operation_id" => "cancel-selected",
             "status" => "applied",
             "group_id" => "group",
             "cancelled_room_ids" => ["room-1", "room-3"],
             "refunded_cents" => 2_800,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 5
           }

    group = get_group("group")

    assert group
           |> Map.take([
             "status",
             "lodging_total_cents",
             "deposit_due_cents",
             "deposit_paid_cents",
             "cash_paid_cents",
             "outstanding_deposit_cents"
           ]) == %{
             "status" => "active",
             "lodging_total_cents" => 10_000,
             "deposit_due_cents" => 2_000,
             "deposit_paid_cents" => 1_500,
             "cash_paid_cents" => 1_500,
             "outstanding_deposit_cents" => 500
           }

    assert payment("pay-1") == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "group",
             "recorded_cents" => 2_500,
             "held_cents" => 0,
             "refunded_cents" => 1_800,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 700,
             "charged_back_cents" => 0
           }

    assert payment("pay-2") == %{
             "payment_operation_id" => "pay-2",
             "original_group_id" => "group",
             "recorded_cents" => 2_500,
             "held_cents" => 1_500,
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    ledger = ledger()
    assert ledger["cash_held_cents"] == 1_500
    assert ledger["cash_refunded_cents"] == 2_800
    assert ledger["cash_reduced_cents"] == 700
  end

  test "chargeback revokes converted entitlement and restoration clears shortfall first" do
    assert [_, _, _, converted] =
             submit([
               open_operation("open-source", "source", 2),
               cash_operation("pay-a", "source", 1_000, 1),
               cash_operation("pay-b", "source", 1_000, 2),
               %{
                 "operation_id" => "convert",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "source",
                 "room_ids" => ["room-2", "room-1"],
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 3
               }
             ])

    assert converted["credit_issued_cents"] == 2_200

    assert [_, applied] =
             submit([
               open_operation("open-target", "target", 1),
               credit_operation("apply", "target", 1_500, 1)
             ])

    assert applied["status"] == "applied"

    assert [charged_back] =
             submit([
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-a",
                 "expected_revision" => 4
               }
             ])

    assert charged_back == %{
             "operation_id" => "chargeback",
             "status" => "applied",
             "payment_operation_id" => "pay-a",
             "group_id" => "source",
             "charged_back_cents" => 1_000,
             "outstanding_deposit_cents" => 0,
             "revision" => 5
           }

    assert payment("pay-a")["charged_back_cents"] == 1_000
    assert payment("pay-a")["converted_to_credit_cents"] == 0
    assert get_group("target")["revision"] == 2
    assert ledger()["credit_shortfall_cents"] == 400
    assert ledger()["credit_liability_cents"] == 1_500

    assert [restored] =
             submit([
               %{
                 "operation_id" => "cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-06",
                 "group_id" => "target",
                 "expected_revision" => 2
               }
             ])

    assert restored["status"] == "applied"
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 1_100

    assert credit("guest-22") == %{
             "guest_id" => "guest-22",
             "available_cents" => 1_100,
             "lots" => [
               %{
                 "source_operation_id" => "convert",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2027-10-05"
               }
             ]
           }
  end

  test "new operations preserve validation, revision, and durable retry behavior" do
    assert [_, _, invalid_rooms, stale] =
             submit([
               open_operation("open", "group", 2),
               cash_operation("pay", "group", 500, 1),
               %{
                 "operation_id" => "bad-rooms",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group",
                 "room_ids" => ["room-1", "room-1"],
                 "expected_revision" => 2
               },
               %{
                 "operation_id" => "stale-reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay",
                 "amount_cents" => -1,
                 "expected_revision" => 1
               }
             ])

    assert invalid_rooms["code"] == "invalid_rooms"
    assert stale["code"] == "stale_revision"

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "amount_cents" => 500,
      "expected_revision" => 2
    }

    assert [original] = submit([reduction])
    assert original["revision"] == 3
    assert submit([reduction]) == [original]

    assert submit([cash_operation("pay", "group", 500, 3)]) |> hd() |> Map.fetch!("code") ==
             "operation_id_conflict"

    assert get_group("group")["revision"] == 3

    assert json_response(get(build_conn(), "/api/v1/payments/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert json_response(get(build_conn(), "/api/v1/payments/open"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  test "one payment reconciles every disposition and chargeback reclassifies the remainder" do
    assert [_, _] =
             submit([
               open_operation("open", "group", 5),
               cash_operation("pay", "group", 10_000, 1)
             ])

    assert [%{"status" => "applied"}] =
             submit([
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 200,
                 "expected_revision" => 2
               }
             ])

    assert [%{"refunded_cents" => 2_000}] =
             submit([cancel_rooms_operation("refund", "group", ["room-1"], 3)])

    assert [%{"credit_issued_cents" => 2_200}] =
             submit([
               cancel_rooms_operation("convert", "group", ["room-2"], 4)
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert [%{"revision" => 6}] =
             submit([
               %{
                 "operation_id" => "move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-06",
                 "group_id" => "group",
                 "new_arrival_on" => "2026-10-20",
                 "expected_revision" => 5
               }
             ])

    assert [%{"retained_cents" => 2_000}] =
             submit([
               cancel_rooms_operation("retain", "group", ["room-3"], 6)
               |> Map.put("occurred_on", "2026-10-07")
             ])

    assert payment("pay") == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group",
             "recorded_cents" => 10_000,
             "held_cents" => 3_800,
             "refunded_cents" => 2_000,
             "retained_cents" => 2_000,
             "converted_to_credit_cents" => 2_000,
             "reduced_cents" => 200,
             "charged_back_cents" => 0
           }

    assert [charged] =
             submit([
               %{
                 "operation_id" => "charge",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 7
               }
             ])

    assert charged["charged_back_cents"] == 9_800
    assert charged["outstanding_deposit_cents"] == 4_000

    assert payment("pay") == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group",
             "recorded_cents" => 10_000,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 200,
             "charged_back_cents" => 9_800
           }

    ledger = ledger()
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_reduced_cents"] == 200
    assert ledger["cash_charged_back_cents"] == 9_800
    assert ledger["credit_liability_cents"] == 0
  end

  defp submit(operations) do
    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    json_response(conn, 200)["results"]
  end

  defp get_group(group_id) do
    json_response(get(build_conn(), "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp payment(operation_id) do
    json_response(get(build_conn(), "/api/v1/payments/#{operation_id}"), 200)["data"]
  end

  defp ledger do
    json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-06"), 200)["data"]
  end

  defp credit(guest_id) do
    json_response(get(build_conn(), "/api/v1/guests/#{guest_id}/credit?on=2026-10-06"), 200)[
      "data"
    ]
  end

  defp room_balances(group_id) do
    get_group(group_id)["rooms"]
    |> Enum.map(fn room ->
      {room["room_id"], room["status"], room["deposit_due_cents"], room["cash_paid_cents"],
       room["credit_paid_cents"]}
    end)
  end

  defp open_operation(operation_id, group_id, room_count) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.map(1..room_count, fn index ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => 10_000}
        end)
    }
  end

  defp cash_operation(operation_id, group_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp credit_operation(operation_id, group_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_rooms_operation(operation_id, group_id, room_ids, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "room_ids" => room_ids,
      "expected_revision" => expected_revision
    }
  end
end
