defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
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

  defp payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, operation_id, date, method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => date,
      "group_id" => group_id
    }

    if method, do: Map.put(operation, "refund_method", method), else: operation
  end

  test "allocates funding by room order and settles selected rooms without changing others", %{
    conn: conn
  } do
    assert [_, _, result] =
             post_operations(conn, [
               open("open", "group"),
               payment("group", "pay", 10_000),
               %{
                 "operation_id" => "cancel-room",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group",
                 "room_ids" => ["room-b"]
               }
             ])

    assert result == %{
             "operation_id" => "cancel-room",
             "status" => "applied",
             "group_id" => "group",
             "cancelled_room_ids" => ["room-b"],
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    group = conn |> get(~p"/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")
    [room_a, room_b] = group["rooms"]
    assert room_a["cash_paid_cents"] == 9_000
    assert room_a["status"] == "active"
    assert room_b["cash_paid_cents"] == 0
    assert room_b["status"] == "cancelled"
    assert group["deposit_due_cents"] == 9_000
    assert group["deposit_paid_cents"] == 9_000
    assert group["outstanding_deposit_cents"] == 0
    assert group["status"] == "active"

    statement =
      conn |> get(~p"/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")

    assert statement["held_cents"] == 9_000
    assert statement["refunded_cents"] == 1_000
  end

  test "returns cancelled room identifiers in original order and cancels the group", %{conn: conn} do
    assert [_, result] =
             post_operations(conn, [
               open("open", "group"),
               %{
                 "operation_id" => "cancel-rooms",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group",
                 "room_ids" => ["room-b", "room-a"]
               }
             ])

    assert result["cancelled_room_ids"] == ["room-a", "room-b"]
    group = conn |> get(~p"/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["lodging_total_cents"] == 0
    assert group["deposit_due_cents"] == 0
  end

  test "reduces held cash in reverse fill order and reconciles every disposition", %{conn: conn} do
    assert [_, _, reduced] =
             post_operations(conn, [
               open("open", "group"),
               payment("group", "pay", 10_000),
               %{
                 "operation_id" => "reduce",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "pay",
                 "amount_cents" => 1_500,
                 "expected_revision" => 2
               }
             ])

    assert reduced["group_id"] == "group"
    assert reduced["outstanding_deposit_cents"] == 11_000
    assert reduced["revision"] == 3

    group = conn |> get(~p"/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")
    assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [8_500, 0]

    assert conn |> get(~p"/api/v1/payments/pay") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "pay",
               "original_group_id" => "group",
               "recorded_cents" => 10_000,
               "held_cents" => 8_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_500,
               "charged_back_cents" => 0
             }
           }

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 8_500
    assert ledger["cash_reduced_cents"] == 1_500

    assert [original] = post_operations(conn, [payment("group", "pay", 10_000)])
    assert original["amount_cents"] == 10_000
    assert original["outstanding_deposit_cents"] == 9_500
  end

  test "chargeback reclassifies settled cash and rejects non-payments", %{conn: conn} do
    assert [_, _, _, charged] =
             post_operations(conn, [
               open("open", "group"),
               payment("group", "pay", 5_000),
               cancel("group", "cancel", "2026-11-26"),
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-12-01",
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               }
             ])

    assert charged["charged_back_cents"] == 5_000
    assert charged["revision"] == 4
    assert charged["outstanding_deposit_cents"] == 0

    statement = conn |> get(~p"/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")
    assert statement["refunded_cents"] == 0
    assert statement["charged_back_cents"] == 5_000

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 5_000

    assert conn |> get(~p"/api/v1/payments/open") |> json_response(422) ==
             %{"error" => %{"code" => "payment_not_reconcilable"}}

    assert conn |> get(~p"/api/v1/payments/missing") |> json_response(404) ==
             %{"error" => %{"code" => "operation_not_found"}}
  end

  test "converted-credit chargeback reports shortfall until applied credit returns", %{conn: conn} do
    later =
      open("open-later", "later", %{
        "occurred_on" => "2026-11-26",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

    use_credit = %{
      "operation_id" => "use-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-26",
      "group_id" => "later",
      "amount_cents" => 5_500
    }

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-12-01",
      "payment_operation_id" => "pay"
    }

    assert [_, _, _, _, _, charged] =
             post_operations(conn, [
               open("open", "source"),
               payment("source", "pay", 5_000),
               cancel("source", "issue", "2026-11-26", "hotel_credit"),
               later,
               use_credit,
               chargeback
             ])

    assert charged["charged_back_cents"] == 5_000
    assert charged["group_id"] == "source"

    ledger =
      conn |> get(~p"/api/v1/ledger?on=2026-12-01") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 5_500
    assert ledger["credit_shortfall_cents"] == 5_500

    later_before =
      conn |> get(~p"/api/v1/groups/later") |> json_response(200) |> Map.fetch!("data")

    assert later_before["revision"] == 2

    assert [%{"status" => "applied"}] =
             post_operations(conn, [cancel("later", "return", "2026-12-01")])

    ledger =
      conn |> get(~p"/api/v1/ledger?on=2026-12-01") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
    assert ledger["credit_shortfall_cents"] == 0
  end

  test "computes one combined room-cancellation bonus and telescoping payment entitlements", %{
    conn: conn
  } do
    tiny =
      open("open", "group", %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15}
        ]
      })

    assert [_, _, _, cancelled, charged] =
             post_operations(conn, [
               tiny,
               payment("group", "pay-1", 3),
               payment("group", "pay-2", 3),
               %{
                 "operation_id" => "issue",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group",
                 "room_ids" => ["room-a", "room-b"],
                 "refund_method" => "hotel_credit"
               },
               %{
                 "operation_id" => "chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-11-27",
                 "payment_operation_id" => "pay-2"
               }
             ])

    assert cancelled["credit_issued_cents"] == 7
    assert charged["charged_back_cents"] == 3

    credit =
      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=2026-11-27")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 3

    ledger =
      conn |> get(~p"/api/v1/ledger?on=2026-11-27") |> json_response(200) |> Map.fetch!("data")

    assert ledger["cash_converted_to_credit_cents"] == 3
    assert ledger["cash_charged_back_cents"] == 3
  end

  test "room cancellation and reductions are durably rejected without state changes", %{
    conn: conn
  } do
    assert [_, invalid_rooms, missing, wrong_type] =
             post_operations(conn, [
               open("open", "group"),
               %{
                 "operation_id" => "bad-rooms",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group",
                 "room_ids" => ["room-a", "room-a"]
               },
               %{
                 "operation_id" => "missing-payment",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "missing",
                 "amount_cents" => 1
               },
               %{
                 "operation_id" => "wrong-type",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "open"
               }
             ])

    assert invalid_rooms["code"] == "invalid_rooms"
    assert missing["code"] == "operation_not_found"
    assert wrong_type["code"] == "payment_not_chargeable"

    assert [replayed] =
             post_operations(conn, [
               %{
                 "operation_id" => "bad-rooms",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group",
                 "room_ids" => ["room-a", "room-a"]
               }
             ])

    assert replayed == invalid_rooms
  end
end
