defmodule GroupStayWeb.TransferDepositTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # Both groups are flexible, booked 2026-10-03 and arriving 2026-12-10, so
  # 2026-11-26 is the last refundable day for either of them.
  @refundable_on "2026-11-26"
  @too_late_on "2026-11-27"

  # `op-pay` records 10_000 against group-81: 9000 fills room-a and the
  # remaining 1000 lands on room-b. group-92 belongs to the same guest and owes
  # the same 19_500 deposit.
  setup %{conn: conn} do
    submit(conn, [open_group_op(), payment_op(), destination_op()])
    :ok
  end

  defp destination_op(overrides \\ %{}) do
    open_group_op(
      Map.merge(%{operation_id: "op-open-92", group_id: "group-92"}, Map.new(overrides))
    )
  end

  describe "transfer_deposit" do
    test "moves held cash onto the destination's rooms", %{conn: conn} do
      assert %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 5000,
               "source_outstanding_deposit_cents" => 14_500,
               "destination_outstanding_deposit_cents" => 14_500,
               "source_revision" => 3,
               "destination_revision" => 2
             } = submit_one(conn, transfer_op())

      # The 1000 on room-b was allocated last, so it leaves first.
      assert %{
               "cash_paid_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 5000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = read_group(conn, "group-81")

      assert %{
               "cash_paid_cents" => 5000,
               "deposit_paid_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 5000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = read_group(conn, "group-92")
    end

    test "settles or revalues nothing", %{conn: conn} do
      before = read_ledger(conn)

      submit_one(conn, transfer_op())

      assert read_ledger(conn) == before
      assert %{"cash_held_cents" => 10_000} = before
    end

    test "moves the whole of the source's held funding", %{conn: conn} do
      assert %{
               "status" => "applied",
               "source_outstanding_deposit_cents" => 19_500,
               "destination_outstanding_deposit_cents" => 9500
             } = submit_one(conn, transfer_op(%{amount_cents: 10_000}))

      assert %{"cash_paid_cents" => 0, "outstanding_deposit_cents" => 19_500} =
               read_group(conn, "group-81")

      assert %{
               "cash_paid_cents" => 10_000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1000}
               ]
             } = read_group(conn, "group-92")
    end

    test "moves funding back and forth", %{conn: conn} do
      submit(conn, [
        transfer_op(),
        transfer_op(%{
          operation_id: "op-transfer-back",
          source_group_id: "group-92",
          destination_group_id: "group-81",
          amount_cents: 5000
        })
      ])

      assert %{"cash_paid_cents" => 10_000, "revision" => 4} = read_group(conn, "group-81")
      assert %{"cash_paid_cents" => 0, "revision" => 3} = read_group(conn, "group-92")
      assert %{"cash_held_cents" => 10_000} = read_ledger(conn)
    end

    test "is remembered like any other operation", %{conn: conn} do
      first = submit_one(conn, transfer_op())

      assert submit_one(conn, transfer_op()) == first
      assert read_operation(conn, "op-transfer") == first

      assert %{"cash_paid_cents" => 5000, "revision" => 3} = read_group(conn, "group-81")
      assert %{"cash_paid_cents" => 5000, "revision" => 2} = read_group(conn, "group-92")
    end
  end

  describe "transfer_deposit and the order funding moves in" do
    # Three payments fund group-81 in full: op-pay takes room-a and 1000 of
    # room-b, then pay-1 and pay-2 fill the rest of room-b behind it.
    setup %{conn: conn} do
      submit(conn, [
        payment_op(%{operation_id: "pay-1", amount_cents: 5000}),
        payment_op(%{operation_id: "pay-2", amount_cents: 4500})
      ])

      :ok
    end

    test "draws the most recent allocation first, whatever it paid for", %{conn: conn} do
      # 12_000 empties pay-2 and pay-1, then reaches back into op-pay.
      assert %{"status" => "applied"} = submit_one(conn, transfer_op(%{amount_cents: 12_000}))

      assert %{"held_by_group" => [%{"group_id" => "group-92", "amount_cents" => 4500}]} =
               read_payment(conn, "pay-2")

      assert %{"held_by_group" => [%{"group_id" => "group-92", "amount_cents" => 5000}]} =
               read_payment(conn, "pay-1")

      assert %{
               "held_cents" => 10_000,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 7500},
                 %{"group_id" => "group-92", "amount_cents" => 2500}
               ]
             } = read_payment(conn, "op-pay")

      assert %{"cash_paid_cents" => 7500} = read_group(conn, "group-81")
    end

    test "fills the destination in room order, in the order units were drawn", %{conn: conn} do
      submit_one(conn, transfer_op(%{amount_cents: 12_000}))

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 3000}
               ]
             } = read_group(conn, "group-92")

      # pay-2 was drawn first, so its 4500 opens room-a rather than trailing the
      # older funding into room-b.
      assert %{"status" => "applied", "group_id" => "group-81"} =
               submit_one(conn, reduce_op(%{payment_operation_id: "pay-2", amount_cents: 4500}))

      assert %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 4500},
                 %{"room_id" => "room-b", "cash_paid_cents" => 3000}
               ]
             } = read_group(conn, "group-92")

      assert %{"cash_paid_cents" => 7500} = read_group(conn, "group-81")
    end
  end

  describe "transfer_deposit and hotel credit" do
    # A cancelled reservation leaves guest-22 holding an 11_000 lot, 8000 of
    # which is applied to group-81 on top of the 10_000 of cash it already has.
    setup %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-open-a", group_id: "group-a"}),
        payment_op(%{operation_id: "pay-a", group_id: "group-a"}),
        cancel_op(%{
          operation_id: "cancel-17",
          group_id: "group-a",
          occurred_on: @refundable_on,
          refund_method: "hotel_credit"
        }),
        credit_op(%{occurred_on: @refundable_on, amount_cents: 8000})
      ])

      :ok
    end

    test "moves credit with its lot and leaves its expiry paused", %{conn: conn} do
      before = read_ledger(conn, on: @refundable_on)

      assert %{"status" => "applied", "amount_cents" => 8000} =
               submit_one(conn, transfer_op(%{amount_cents: 8000}))

      assert read_ledger(conn, on: @refundable_on) == before
      assert %{"credit_liability_cents" => 11_000} = before

      assert %{"credit_paid_cents" => 0, "cash_paid_cents" => 10_000} =
               read_group(conn, "group-81")

      assert %{"credit_paid_cents" => 8000, "cash_paid_cents" => 0} =
               read_group(conn, "group-92")

      # Still applied, so none of it is available to spend again.
      assert %{"available_cents" => 3000} = read_credit(conn, "guest-22", on: @refundable_on)
    end

    test "restores transferred credit to its original lot and expiry", %{conn: conn} do
      submit(conn, [
        transfer_op(%{amount_cents: 8000}),
        cancel_op(%{
          operation_id: "cancel-92",
          group_id: "group-92",
          occurred_on: @refundable_on
        })
      ])

      # The lot was issued by the 2026-11-26 cancellation, so it still expires
      # on 2027-11-27, and it never receives a second bonus.
      assert %{
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 11_000,
                   "expires_on" => "2027-11-27"
                 }
               ]
             } = read_credit(conn, "guest-22", on: @refundable_on)
    end

    test "consumes transferred credit on a non-refundable settlement", %{conn: conn} do
      submit(conn, [
        transfer_op(%{amount_cents: 8000}),
        cancel_op(%{
          operation_id: "cancel-92",
          group_id: "group-92",
          occurred_on: @too_late_on
        })
      ])

      assert %{"available_cents" => 3000} = read_credit(conn, "guest-22", on: @too_late_on)

      assert %{"credit_liability_cents" => 3000} = read_ledger(conn, on: @too_late_on)
    end

    test "draws credit before cash when the credit was allocated last", %{conn: conn} do
      # group-81 holds 10_000 of cash and then 8000 of credit.
      submit_one(conn, transfer_op(%{amount_cents: 9000}))

      assert %{"cash_paid_cents" => 9000, "credit_paid_cents" => 0} =
               read_group(conn, "group-81")

      assert %{"cash_paid_cents" => 1000, "credit_paid_cents" => 8000} =
               read_group(conn, "group-92")
    end
  end

  describe "transfer_deposit and later settlement" do
    test "settles transferred cash under the destination's policy", %{conn: conn} do
      submit(conn, [
        transfer_op(),
        # group-92 is still refundable on this date, but group-81 is not.
        cancel_op(%{
          operation_id: "cancel-92",
          group_id: "group-92",
          occurred_on: @too_late_on
        })
      ])

      assert %{"cash_retained_cents" => 5000, "cash_held_cents" => 5000} = read_ledger(conn)

      assert %{"retained_cents" => 5000, "held_cents" => 5000} = read_payment(conn, "op-pay")
    end

    test "gives the destination's bonus on the cash settled there", %{conn: conn} do
      submit(conn, [
        transfer_op(),
        cancel_op(%{
          operation_id: "cancel-92",
          group_id: "group-92",
          occurred_on: @refundable_on,
          refund_method: "hotel_credit"
        })
      ])

      assert %{"credit_issued_cents" => 5500} = read_operation(conn, "cancel-92")

      assert %{"converted_to_credit_cents" => 5000, "held_cents" => 5000} =
               read_payment(conn, "op-pay")
    end
  end

  describe "transfer_deposit and corrections that span groups" do
    setup %{conn: conn} do
      submit_one(conn, transfer_op())
      :ok
    end

    test "a reduction follows the payment into the destination first", %{conn: conn} do
      assert %{
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 4000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 4
             } = submit_one(conn, reduce_op(%{amount_cents: 4000}))

      # The transferred allocations are the most recent, so they go first.
      assert %{"cash_paid_cents" => 5000, "revision" => 4} = read_group(conn, "group-81")
      assert %{"cash_paid_cents" => 1000, "revision" => 3} = read_group(conn, "group-92")

      assert %{
               "held_cents" => 6000,
               "reduced_cents" => 4000,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 5000},
                 %{"group_id" => "group-92", "amount_cents" => 1000}
               ]
             } = read_payment(conn, "op-pay")
    end

    test "a chargeback reverses the payment in every group it reaches", %{conn: conn} do
      assert %{
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             } = submit_one(conn, charge_back_op())

      assert %{"cash_paid_cents" => 0, "outstanding_deposit_cents" => 19_500, "revision" => 4} =
               read_group(conn, "group-81")

      assert %{"cash_paid_cents" => 0, "outstanding_deposit_cents" => 19_500, "revision" => 3} =
               read_group(conn, "group-92")

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000} = read_ledger(conn)

      assert %{"held_cents" => 0, "held_by_group" => []} = read_payment(conn, "op-pay")
    end

    test "a reduction guards only the group its request names", %{conn: conn} do
      # group-92 is at revision 2; the guard is compared against group-81.
      assert %{"status" => "applied", "revision" => 4} =
               submit_one(conn, reduce_op(%{amount_cents: 4000, expected_revision: 3}))

      assert %{"revision" => 3} = read_group(conn, "group-92")
    end

    test "advances the addressed group even when its cash has all moved on", %{conn: conn} do
      submit_one(
        conn,
        transfer_op(%{operation_id: "op-transfer-2", amount_cents: 5000})
      )

      assert %{"cash_paid_cents" => 0, "revision" => 4} = read_group(conn, "group-81")

      assert %{
               "status" => "applied",
               "group_id" => "group-81",
               "outstanding_deposit_cents" => 19_500,
               "revision" => 5
             } = submit_one(conn, reduce_op(%{amount_cents: 1000}))

      assert %{"cash_paid_cents" => 9000, "revision" => 4} = read_group(conn, "group-92")
    end

    test "does not rewrite the payment it moved", %{conn: conn} do
      assert %{
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9500,
               "revision" => 2
             } = read_operation(conn, "op-pay")
    end
  end

  describe "transfer_deposit rejections" do
    test "rejects a source group that does not exist", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-none"
             } =
               submit_one(
                 conn,
                 transfer_op(%{
                   source_group_id: "group-none",
                   destination_group_id: "group-also-none"
                 })
               )
    end

    test "rejects a destination group that does not exist", %{conn: conn} do
      assert %{"code" => "group_not_found", "group_id" => "group-none"} =
               submit_one(conn, transfer_op(%{destination_group_id: "group-none"}))
    end

    test "rejects a transfer to the same group", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "invalid_transfer"} =
               submit_one(conn, transfer_op(%{destination_group_id: "group-81"}))

      assert %{"revision" => 2} = read_group(conn, "group-81")
    end

    test "rejects a transfer between two guests", %{conn: conn} do
      submit_one(
        conn,
        destination_op(%{operation_id: "op-open-93", group_id: "group-93", guest_id: "guest-99"})
      )

      assert %{"code" => "invalid_transfer"} =
               submit_one(conn, transfer_op(%{destination_group_id: "group-93"}))
    end

    test "rejects a source that is no longer active", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @refundable_on}))

      assert %{"code" => "group_not_active", "group_id" => "group-81"} =
               submit_one(conn, transfer_op())
    end

    test "rejects a destination that is no longer active", %{conn: conn} do
      submit_one(
        conn,
        cancel_op(%{
          operation_id: "cancel-92",
          group_id: "group-92",
          occurred_on: @refundable_on
        })
      )

      assert %{"code" => "group_not_active", "group_id" => "group-92"} =
               submit_one(conn, transfer_op())
    end

    test "rejects a non-positive amount", %{conn: conn} do
      for {amount, index} <- Enum.with_index([0, -1, "500", 500.0]) do
        assert %{"status" => "rejected", "code" => "invalid_amount"} =
                 submit_one(
                   conn,
                   transfer_op(%{operation_id: "op-transfer-#{index}", amount_cents: amount})
                 ),
               "expected invalid_amount for #{inspect(amount)}"
      end

      assert %{"revision" => 2} = read_group(conn, "group-81")
    end

    test "rejects more than the source is holding", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} =
               submit_one(conn, transfer_op(%{amount_cents: 10_001}))

      assert %{"cash_paid_cents" => 10_000, "revision" => 2} = read_group(conn, "group-81")
      assert %{"cash_paid_cents" => 0, "revision" => 1} = read_group(conn, "group-92")
    end

    test "unpaid deposit is not held funding", %{conn: conn} do
      submit_one(conn, reduce_op(%{amount_cents: 10_000}))

      assert %{"code" => "transfer_exceeds_held_funding"} =
               submit_one(conn, transfer_op(%{amount_cents: 1}))
    end

    test "rejects more than the destination still owes", %{conn: conn} do
      submit(conn, [
        payment_op(%{operation_id: "op-pay-2", amount_cents: 9500}),
        payment_op(%{operation_id: "op-pay-92", group_id: "group-92", amount_cents: 15_000})
      ])

      assert %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"} =
               submit_one(conn, transfer_op(%{amount_cents: 4501}))

      assert %{"status" => "applied"} =
               submit_one(
                 conn,
                 transfer_op(%{operation_id: "op-transfer-2", amount_cents: 4500})
               )
    end

    test "rejects a stale source revision", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             } = submit_one(conn, transfer_op(%{expected_revision: 1}))

      assert %{"cash_paid_cents" => 10_000, "revision" => 2} = read_group(conn, "group-81")
      assert %{"revision" => 1} = read_group(conn, "group-92")
    end

    test "rejects a stale destination revision", %{conn: conn} do
      assert %{
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 2,
               "actual_revision" => 1
             } =
               submit_one(
                 conn,
                 transfer_op(%{expected_revision: 2, destination_expected_revision: 2})
               )
    end

    test "applies when both revisions match", %{conn: conn} do
      assert %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2} =
               submit_one(
                 conn,
                 transfer_op(%{expected_revision: 2, destination_expected_revision: 1})
               )
    end

    test "checks the source revision before the destination's", %{conn: conn} do
      assert %{"code" => "stale_revision", "group_id" => "group-81"} =
               submit_one(
                 conn,
                 transfer_op(%{expected_revision: 1, destination_expected_revision: 2})
               )
    end

    test "resolves both groups before comparing revisions", %{conn: conn} do
      assert %{"code" => "group_not_found", "group_id" => "group-none"} =
               submit_one(
                 conn,
                 transfer_op(%{destination_group_id: "group-none", expected_revision: 1})
               )
    end

    test "rejects an operation that cannot name both groups", %{conn: conn} do
      for key <- ["source_group_id", "destination_group_id"] do
        operation = transfer_op(%{operation_id: "op-transfer-#{key}"})

        assert %{"status" => "rejected", "code" => "invalid_operation"} =
                 submit_one(conn, Map.delete(operation, key)),
               "expected invalid_operation without #{key}"
      end
    end

    test "rejects an unusable revision guard", %{conn: conn} do
      assert %{"code" => "invalid_operation"} =
               submit_one(conn, transfer_op(%{destination_expected_revision: "1"}))
    end

    test "remembers a rejection like any other operation", %{conn: conn} do
      first = submit_one(conn, transfer_op(%{amount_cents: 10_001}))

      assert %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} = first
      assert read_operation(conn, "op-transfer") == first
    end
  end
end
