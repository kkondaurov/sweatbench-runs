defmodule GroupStayWeb.CancelRoomsTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # The default group is flexible, booked 2026-10-03 and arriving 2026-12-10, so
  # 2026-11-26 is its last refundable day. room-a needs a 9000 deposit and room-b
  # a 10_500 one; the default payment of 10_000 therefore fills room-a and puts
  # 1000 on room-b.
  @refundable_on "2026-11-26"
  @too_late_on "2026-11-27"

  setup %{conn: conn} do
    submit(conn, [open_group_op(), payment_op()])
    :ok
  end

  describe "cancel_rooms" do
    test "settles only the named rooms and leaves the group active", %{conn: conn} do
      assert %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 9000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             } = submit_one(conn, cancel_rooms_op(%{occurred_on: @refundable_on}))

      assert %{
               "status" => "active",
               "lodging_total_cents" => 52_500,
               "deposit_due_cents" => 10_500,
               "cash_paid_cents" => 1000,
               "deposit_paid_cents" => 1000,
               "outstanding_deposit_cents" => 9500,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "status" => "active", "cash_paid_cents" => 1000}
               ]
             } = read_group(conn, "group-81")

      assert %{"cash_held_cents" => 1000, "cash_refunded_cents" => 9000} = read_ledger(conn)
    end

    test "retains the cash of a room cancelled too late", %{conn: conn} do
      assert %{"refunded_cents" => 0, "retained_cents" => 9000} =
               submit_one(conn, cancel_rooms_op(%{occurred_on: @too_late_on}))

      assert %{"cash_held_cents" => 1000, "cash_retained_cents" => 9000} = read_ledger(conn)
    end

    test "cancels the group once no active room is left", %{conn: conn} do
      submit_one(conn, cancel_rooms_op(%{occurred_on: @refundable_on}))

      assert %{
               "status" => "applied",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 1000,
               "revision" => 4
             } =
               submit_one(
                 conn,
                 cancel_rooms_op(%{
                   operation_id: "op-cancel-rooms-2",
                   occurred_on: @refundable_on,
                   room_ids: ["room-b"]
                 })
               )

      assert %{"status" => "cancelled", "outstanding_deposit_cents" => 0} =
               read_group(conn, "group-81")

      assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 10_000} = read_ledger(conn)
    end

    test "returns the cancelled rooms in the group's own order", %{conn: conn} do
      assert %{"cancelled_room_ids" => ["room-a", "room-b"]} =
               submit_one(
                 conn,
                 cancel_rooms_op(%{occurred_on: @refundable_on, room_ids: ["room-b", "room-a"]})
               )

      assert %{"status" => "cancelled"} = read_group(conn, "group-81")
    end

    test "takes the credit bonus once on the rooms' combined cash", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a", guest_id: "guest-a"}),
        payment_op(%{operation_id: "op-b", group_id: "group-a", amount_cents: 9005}),
        payment_op(%{operation_id: "op-c", group_id: "group-a", amount_cents: 5})
      ])

      # 9010 of cash across both rooms: one bonus of 901, not 901 plus 1.
      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 9911,
               "cancelled_room_ids" => ["room-a", "room-b"]
             } =
               submit_one(
                 conn,
                 cancel_rooms_op(%{
                   group_id: "group-a",
                   occurred_on: @refundable_on,
                   refund_method: "hotel_credit",
                   room_ids: ["room-a", "room-b"]
                 })
               )

      assert %{"available_cents" => 9911} = read_credit(conn, "guest-a", on: @refundable_on)
    end

    test "returns the credit that funded a cancelled room to its own lot", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a"}),
        payment_op(%{operation_id: "op-b", group_id: "group-a", amount_cents: 10_000}),
        cancel_op(%{
          operation_id: "cancel-17",
          group_id: "group-a",
          occurred_on: @refundable_on,
          refund_method: "hotel_credit"
        }),
        credit_op(%{operation_id: "op-credit", occurred_on: "2026-10-05", amount_cents: 9500})
      ])

      # 9500 of the 11_000 lot funds room-b, which room-a's cash does not reach.
      assert %{"credit_paid_cents" => 9500} = read_group(conn, "group-81")
      assert %{"available_cents" => 1500} = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{"refunded_cents" => 1000, "credit_issued_cents" => 0} =
               submit_one(
                 conn,
                 cancel_rooms_op(%{occurred_on: @refundable_on, room_ids: ["room-b"]})
               )

      # The 9500 goes back to the lot it came from; only the cash is refunded.
      assert %{
               "available_cents" => 11_000,
               "lots" => [%{"source_operation_id" => "cancel-17", "remaining_cents" => 11_000}]
             } = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{
               "status" => "active",
               "cash_paid_cents" => 9000,
               "credit_paid_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000, "credit_paid_cents" => 0},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1000, "credit_paid_cents" => 9500}
               ]
             } = read_group(conn, "group-81")
    end

    test "consumes the credit of a room cancelled too late", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a"}),
        payment_op(%{operation_id: "op-b", group_id: "group-a", amount_cents: 10_000}),
        cancel_op(%{
          operation_id: "cancel-17",
          group_id: "group-a",
          occurred_on: @refundable_on,
          refund_method: "hotel_credit"
        }),
        credit_op(%{operation_id: "op-credit", occurred_on: "2026-10-05", amount_cents: 9500})
      ])

      submit_one(
        conn,
        cancel_rooms_op(%{occurred_on: @too_late_on, room_ids: ["room-b"]})
      )

      # The applied 9500 is consumed; only the 1500 the lot never lent survives.
      assert %{
               "available_cents" => 1500,
               "lots" => [%{"source_operation_id" => "cancel-17", "remaining_cents" => 1500}]
             } = read_credit(conn, "guest-22", on: @too_late_on)

      assert %{"credit_liability_cents" => 1500} = read_ledger(conn, on: @too_late_on)
    end

    test "leaves the other rooms and their allocations alone", %{conn: conn} do
      submit_one(conn, cancel_rooms_op(%{occurred_on: @refundable_on, room_ids: ["room-b"]}))

      assert %{
               "deposit_due_cents" => 9000,
               "cash_paid_cents" => 9000,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 1000}
               ]
             } = read_group(conn, "group-81")

      assert %{"cash_held_cents" => 9000, "cash_refunded_cents" => 1000} = read_ledger(conn)
    end
  end

  describe "cancel_rooms rejections" do
    test "rejects a room the group does not hold", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "invalid_rooms", "group_id" => "group-81"} =
               submit_one(conn, cancel_rooms_op(%{room_ids: ["room-a", "room-z"]}))

      assert %{"revision" => 2, "rooms" => [%{"status" => "active"}, %{"status" => "active"}]} =
               read_group(conn, "group-81")
    end

    test "rejects a repeated room identifier", %{conn: conn} do
      assert %{"code" => "invalid_rooms"} =
               submit_one(conn, cancel_rooms_op(%{room_ids: ["room-a", "room-a"]}))
    end

    test "rejects an already cancelled room", %{conn: conn} do
      submit_one(conn, cancel_rooms_op(%{occurred_on: @refundable_on}))

      assert %{"code" => "invalid_rooms"} =
               submit_one(
                 conn,
                 cancel_rooms_op(%{operation_id: "op-2", occurred_on: @refundable_on})
               )
    end

    test "rejects an empty or missing selection", %{conn: conn} do
      assert %{"code" => "invalid_rooms"} =
               submit_one(conn, cancel_rooms_op(%{room_ids: []}))

      assert %{"code" => "invalid_rooms"} =
               submit_one(conn, cancel_rooms_op(%{operation_id: "op-2", room_ids: "room-a"}))

      assert %{"code" => "invalid_rooms"} =
               submit_one(
                 conn,
                 Map.delete(cancel_rooms_op(%{operation_id: "op-3"}), "room_ids")
               )
    end

    test "rejects a missing group before looking at the rooms", %{conn: conn} do
      assert %{"code" => "group_not_found"} =
               submit_one(conn, cancel_rooms_op(%{group_id: "group-none", room_ids: []}))
    end

    test "rejects a cancelled group", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @too_late_on}))

      assert %{"code" => "group_not_active"} =
               submit_one(conn, cancel_rooms_op(%{occurred_on: @too_late_on}))
    end

    test "refuses hotel credit for a non-refundable settlement", %{conn: conn} do
      assert %{"code" => "refund_method_not_available"} =
               submit_one(
                 conn,
                 cancel_rooms_op(%{occurred_on: @too_late_on, refund_method: "hotel_credit"})
               )

      assert %{"status" => "active", "revision" => 2} = read_group(conn, "group-81")
    end

    test "rejects a stale revision before the rooms", %{conn: conn} do
      assert %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2} =
               submit_one(
                 conn,
                 cancel_rooms_op(%{expected_revision: 1, room_ids: ["room-z"]})
               )

      assert %{"revision" => 2} = read_group(conn, "group-81")
    end
  end

  describe "cancel_group after some rooms are gone" do
    test "settles only the rooms that are still active", %{conn: conn} do
      submit_one(conn, cancel_rooms_op(%{occurred_on: @refundable_on}))

      assert %{"status" => "applied", "refunded_cents" => 1000, "retained_cents" => 0} =
               submit_one(conn, cancel_op(%{occurred_on: @refundable_on}))

      assert %{"status" => "cancelled"} = read_group(conn, "group-81")
      assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 10_000} = read_ledger(conn)
    end
  end
end
