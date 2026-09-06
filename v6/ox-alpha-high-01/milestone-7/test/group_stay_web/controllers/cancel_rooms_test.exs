defmodule GroupStayWeb.CancelRoomsTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  # The default group has rooms room-a (15_000/night) and room-b (17_500/night)
  # for three nights: deposits 9_000 and 10_500, 19_500 in total. It is
  # refundable through 2026-11-26.

  describe "cancel_rooms" do
    test "settles only the selected rooms' allocated cash", %{conn: conn} do
      open_group(conn)

      run_batch(conn, [payment_operation("op-pay-1", 6_000), payment_operation("op-pay-2", 8_000)])

      result = cancel_rooms(conn, "op-cr", "2026-12-01", ["room-b"])

      assert result == %{
               "operation_id" => "op-cr",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 0,
               "retained_cents" => 5_000,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      # Only room-b's allocation settled; pay-2 keeps its room-a portion.
      assert statement(conn, "op-pay-1") |> Map.take(~w(held_cents retained_cents)) == %{
               "held_cents" => 6_000,
               "retained_cents" => 0
             }

      assert statement(conn, "op-pay-2") |> Map.take(~w(held_cents retained_cents)) == %{
               "held_cents" => 3_000,
               "retained_cents" => 5_000
             }

      group = group_json(conn, "group-81")

      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 45_000
      assert group["deposit_due_cents"] == 9_000
      assert group["cash_paid_cents"] == 9_000
      assert group["deposit_paid_cents"] == 9_000
      assert group["outstanding_deposit_cents"] == 0

      assert [
               %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
             ] = group["rooms"]

      ledger = ledger_json(conn)
      assert ledger["cash_held_cents"] == 9_000
      assert ledger["cash_retained_cents"] == 5_000
    end

    test "a refundable hotel-credit settlement computes one bonus on the combined cash", %{
      conn: conn
    } do
      open_group(conn)

      run_batch(conn, [payment_operation("op-pay-1", 4_000), payment_operation("op-pay-2", 5_000)])

      operation =
        cancel_rooms_operation(["room-a"], "hotel_credit")
        |> Map.put("operation_id", "op-cr")
        |> Map.put("occurred_on", "2026-11-20")

      assert [%{"status" => "applied"} = result] = run_batch(conn, [operation])

      assert result["cancelled_room_ids"] == ["room-a"]
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      # 110% of the combined 9_000, rounded half up once.
      assert result["credit_issued_cents"] == 9_900

      assert lots(conn) == [{"op-cr", 9_900}]

      group = group_json(conn, "group-81")
      assert group["status"] == "active"
      assert group["deposit_due_cents"] == 10_500
      assert group["cash_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 10_500

      # Entitlements telescope across the two contributing payments in funding
      # order: 110% of 4_000 = 4_400 for the first, the remaining 5_500 for the
      # second. A chargeback moves the payment's cash and revokes its
      # entitlement from the lot.
      charge_back_result = charge_back(conn, "op-chb-2", "op-pay-2")
      assert charge_back_result["charged_back_cents"] == 5_000
      assert lots(conn) == [{"op-cr", 4_400}]

      charge_back_result = charge_back(conn, "op-chb-1", "op-pay-1")
      assert charge_back_result["charged_back_cents"] == 4_000
      assert lots(conn) == []
    end

    test "rejects identifiers that are not distinct active rooms of the group", %{conn: conn} do
      open_group(conn)

      results =
        run_batch(conn, [
          cancel_rooms_operation(["room-a", "room-a"]) |> Map.put("operation_id", "op-dup"),
          cancel_rooms_operation(["room-z"]) |> Map.put("operation_id", "op-unknown"),
          cancel_rooms_operation([])
          |> Map.put("op-empty", true)
          |> Map.put("operation_id", "op-empty"),
          cancel_rooms_operation("room-a") |> Map.put("operation_id", "op-not-list")
        ])

      assert Enum.all?(results, fn result ->
               result["status"] == "rejected" and result["code"] == "invalid_rooms"
             end)

      # A missing list is missing data needed to apply the operation.
      results =
        run_batch(conn, [
          %{
            "operation_id" => "op-missing",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-11-20"
          }
        ])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results

      assert group_json(conn, "group-81")["revision"] == 1
    end

    test "an already-cancelled room cannot be cancelled again", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])
      cancel_rooms(conn, "op-cr-1", "2026-12-01", ["room-b"])

      results =
        run_batch(conn, [cancel_rooms_operation(["room-b"]) |> Map.put("operation_id", "op-cr-2")])

      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] = results
      assert group_json(conn, "group-81")["revision"] == 3
    end

    test "cancelling every room cancels the group and reports rooms in original order", %{
      conn: conn
    } do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 10_000)])

      result = cancel_rooms(conn, "op-cr", "2026-12-01", ["room-b", "room-a"])

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
      assert result["retained_cents"] == 10_000

      group = group_json(conn, "group-81")

      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 10_000

      assert Enum.all?(group["rooms"], &(&1["status"] == "cancelled"))

      ledger = ledger_json(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_retained_cents"] == 10_000

      results = run_batch(conn, [payment_operation("op-repay", 100)])
      assert [%{"status" => "rejected", "code" => "group_not_active"}] = results
    end

    test "cancel_group afterwards settles only the remaining active rooms", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 19_500)])
      cancel_rooms(conn, "op-cr", "2026-12-01", ["room-a"])

      result = cancel(conn, "op-cancel", "2026-12-02")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 10_500
      assert result["credit_issued_cents"] == 0

      assert group_json(conn, "group-81")["status"] == "cancelled"

      ledger = ledger_json(conn)
      assert ledger["cash_retained_cents"] == 19_500
      assert ledger["cash_held_cents"] == 0
    end

    test "hotel credit is not available for a non-refundable room settlement", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 5_000)])

      operation =
        cancel_rooms_operation(["room-a"], "hotel_credit")
        |> Map.put("operation_id", "op-cr")
        |> Map.put("occurred_on", "2026-12-01")

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
               run_batch(conn, [operation])

      group = group_json(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert Enum.all?(group["rooms"], &(&1["status"] == "active"))
    end

    test "retries return the stored result verbatim", %{conn: conn} do
      open_group(conn)
      run_batch(conn, [payment_operation("op-pay", 5_000)])

      operation = cancel_rooms_operation(["room-a"]) |> Map.put("operation_id", "op-cr")

      assert [%{"status" => "applied"} = first] = run_batch(conn, [operation])
      assert [%{"status" => "applied"} = second] = run_batch(conn, [operation])
      assert first == second

      assert group_json(conn, "group-81")["revision"] == 3

      changed = operation |> Map.put("occurred_on", "2026-11-20")

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               run_batch(conn, [changed])
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp open_group(conn, overrides \\ %{}) do
    assert [%{"status" => "applied"}] = run_batch(conn, [open_operation(overrides)])
    :ok
  end

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn, group_id) do
    %{"data" => group} = conn |> get_group(group_id) |> json_response(200)
    group
  end

  defp ledger_json(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
  end

  defp guest_credit_json(conn, guest_id) do
    %{"data" => data} = conn |> get_guest_credit(guest_id) |> json_response(200)
    data
  end

  defp lots(conn) do
    Enum.map(guest_credit_json(conn, "guest-22")["lots"], fn lot ->
      {lot["source_operation_id"], lot["remaining_cents"]}
    end)
  end

  defp statement(conn, payment_operation_id) do
    %{"data" => data} = conn |> get_payment(payment_operation_id) |> json_response(200)
    data
  end

  defp payment_operation(operation_id, amount_cents),
    do: %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }

  defp cancel_rooms_operation(room_ids, refund_method \\ "cash") do
    %{
      "type" => "cancel_rooms",
      "occurred_on" => "2026-12-01",
      "group_id" => "group-81",
      "room_ids" => room_ids,
      "refund_method" => refund_method
    }
  end

  defp cancel_rooms(conn, operation_id, occurred_on, room_ids) do
    operation =
      cancel_rooms_operation(room_ids)
      |> Map.put("operation_id", operation_id)
      |> Map.put("occurred_on", occurred_on)

    assert [%{"status" => "applied"} = result] = run_batch(conn, [operation])
    result
  end

  defp charge_back(conn, operation_id, target_id) do
    assert [%{"status" => "applied"} = result] =
             run_batch(conn, [
               %{
                 "operation_id" => operation_id,
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-11-21",
                 "payment_operation_id" => target_id
               }
             ])

    result
  end

  defp cancel(conn, operation_id, occurred_on) do
    assert [%{"status" => "applied"} = result] =
             run_batch(conn, [
               %{
                 "operation_id" => operation_id,
                 "type" => "cancel_group",
                 "occurred_on" => occurred_on,
                 "group_id" => "group-81"
               }
             ])

    result
  end
end
