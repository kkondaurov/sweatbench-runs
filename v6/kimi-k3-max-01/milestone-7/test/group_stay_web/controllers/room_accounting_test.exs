defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  describe "room-level accounting" do
    test "cash fills active room deposits in the rooms' original order", %{conn: conn} do
      # Two flexible rooms: room-a due 9_000, room-b due 10_500.
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000})
      ])

      group = get_group!(fresh_conn(), "group-81")

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 9_000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 1_000,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "new funding operations allocate in operation-processing order", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{
          "refund_method" => "hotel_credit",
          "occurred_on" => "2026-11-01"
        }),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        # Cash fills room-a first; the later credit application continues
        # into room-b.
        record_cash_payment_op(%{
          "operation_id" => "op-cash",
          "group_id" => "group-82",
          "amount_cents" => 9_000
        }),
        apply_hotel_credit_op(%{
          "operation_id" => "op-credit",
          "group_id" => "group-82",
          "amount_cents" => 5_000
        })
      ])

      group = get_group!(fresh_conn(), "group-82")
      [room_a, room_b] = group["rooms"]

      assert room_a["cash_paid_cents"] == 9_000
      assert room_a["credit_paid_cents"] == 0
      assert room_b["cash_paid_cents"] == 0
      assert room_b["credit_paid_cents"] == 5_000
    end

    test "cash on a fully filled first room spills into the next room", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000}),
        record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 10_500})
      ])

      group = get_group!(fresh_conn(), "group-81")
      [room_a, room_b] = group["rooms"]

      assert room_a["cash_paid_cents"] == 9_000
      assert room_b["cash_paid_cents"] == 10_500
      assert group["deposit_paid_cents"] == 19_500
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms in the group's original room order", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      # Supplied out of order; the result follows the group's room order.
      [result] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{"room_ids" => ["room-b", "room-a"]})
        ])

      assert result == %{
               "operation_id" => "op-6001",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a", "room-b"],
               "refunded_cents" => 19_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = get_group!(fresh_conn(), "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_due_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
    end

    test "settling some rooms keeps the others and their allocations", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-20"})
        ])

      assert result["cancelled_room_ids"] == ["room-a"]
      assert result["refunded_cents"] == 9_000

      group = get_group!(fresh_conn(), "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 3

      [room_a, room_b] = group["rooms"]
      assert room_a["status"] == "cancelled"
      assert room_a["deposit_due_cents"] == 9_000
      assert room_a["cash_paid_cents"] == 0
      assert room_b["status"] == "active"
      assert room_b["deposit_due_cents"] == 10_500

      # Totals describe the remaining active rooms.
      assert group["deposit_due_cents"] == 10_500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 10_500
      assert group["lodging_total_cents"] == 52_500
    end

    test "computes the hotel-credit bonus once on the combined cash amount", %{conn: conn} do
      # room-b due is 10_500; bonus on the combined amount once: 1_050,
      # versus 1_050 if computed per room with any room's odd amounts.
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 4_523}),
        record_cash_payment_op(%{"operation_id" => "op-2002", "amount_cents" => 452})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{
            "room_ids" => ["room-a"],
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-11-20"
          })
        ])

      assert result["credit_issued_cents"] == 4_975 + 498

      assert get_credit!(fresh_conn(), "guest-22")["available_cents"] == 4_975 + 498
    end

    test "non-refundable room cancellation retains cash and consumes credit", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500})
      ])

      # 2026-12-09 is inside the 14-day window.
      [result] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{"occurred_on" => "2026-12-09", "room_ids" => ["room-b"]})
        ])

      assert result["retained_cents"] == 10_500
      assert result["refunded_cents"] == 0
    end

    test "rejects unusable room selections", %{conn: conn} do
      apply_batch!(conn, [open_group_op()])

      for {room_ids, index} <-
            Enum.with_index([
              %{},
              [],
              ["room-a", "room-a"],
              ["unknown-room"],
              ["room-a", "unknown-room"],
              [42]
            ]) do
        [result] =
          post_batch!(fresh_conn(), [
            cancel_rooms_op(%{"operation_id" => "op-rooms-#{index}", "room_ids" => room_ids})
          ])

        assert result["code"] == "invalid_rooms", "room_ids=#{inspect(room_ids)}"
      end

      # A missing selection is an invalid operation instead.
      missing_op =
        cancel_rooms_op(%{"operation_id" => "op-rooms-missing"})
        |> Map.delete("room_ids")

      [missing] = post_batch!(fresh_conn(), [missing_op])

      assert missing["code"] == "invalid_operation"

      assert get_group!(fresh_conn(), "group-81")["revision"] == 1
    end

    test "rejects rooms already cancelled in a previous operation", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        cancel_rooms_op(%{"room_ids" => ["room-a"]})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{"operation_id" => "op-again", "room_ids" => ["room-a"]})
        ])

      assert result["code"] == "invalid_rooms"
    end

    test "honors the refund method rules like full cancellation", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 9_000})
      ])

      # Hotel credit for a non-refundable selection is rejected.
      [result] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-12-09",
            "room_ids" => ["room-a"]
          })
        ])

      assert result["code"] == "refund_method_not_available"
      assert get_group!(fresh_conn(), "group-81")["revision"] == 2
    end

    test "rejects missing and inactive groups", %{conn: conn} do
      [missing] = post_batch!(conn, [cancel_rooms_op()])
      assert missing["code"] == "group_not_found"

      apply_batch!(fresh_conn(), [open_group_op(), cancel_group_op()])

      [inactive] =
        post_batch!(fresh_conn(), [
          cancel_rooms_op(%{"operation_id" => "op-6002"})
        ])

      assert inactive["code"] == "group_not_active"
    end

    test "a full cancellation settles the remaining active rooms", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-20"})
      ])

      [result] =
        post_batch!(fresh_conn(), [
          cancel_group_op(%{"occurred_on" => "2026-11-20"})
        ])

      # Only room-b's 10_500 was still held; room-a was settled already.
      assert result["refunded_cents"] == 10_500
      assert result["revision"] == 4

      group = get_group!(fresh_conn(), "group-81")
      assert group["status"] == "cancelled"
    end
  end
end
