defmodule GroupStayWeb.ChargeBackPaymentTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # The default group is flexible, booked 2026-10-03 and arriving 2026-12-10, so
  # 2026-11-26 is its last refundable day.
  @refundable_on "2026-11-26"
  @too_late_on "2026-11-27"

  setup %{conn: conn} do
    submit(conn, [open_group_op(), payment_op()])
    :ok
  end

  describe "charge_back_payment" do
    test "takes held cash off the rooms and reopens the deposit", %{conn: conn} do
      assert %{
               "operation_id" => "op-charge-back",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             } = submit_one(conn, charge_back_op())

      assert %{
               "status" => "active",
               "cash_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 0},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             } = read_group(conn, "group-81")

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 10_000} = read_ledger(conn)
    end

    test "reclassifies cash that was already refunded", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @refundable_on}))

      assert %{"charged_back_cents" => 10_000, "outstanding_deposit_cents" => 0, "revision" => 4} =
               submit_one(conn, charge_back_op())

      assert %{
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 10_000
             } = read_ledger(conn)
    end

    test "reclassifies cash the hotel retained", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @too_late_on}))

      assert %{"charged_back_cents" => 10_000} = submit_one(conn, charge_back_op())

      assert %{"cash_retained_cents" => 0, "cash_charged_back_cents" => 10_000} =
               read_ledger(conn)
    end

    test "leaves cash already recorded as reduced alone", %{conn: conn} do
      submit_one(conn, reduce_op(%{amount_cents: 2500}))

      assert %{"charged_back_cents" => 7500} = submit_one(conn, charge_back_op())

      assert %{
               "cash_held_cents" => 0,
               "cash_reduced_cents" => 2500,
               "cash_charged_back_cents" => 7500
             } = read_ledger(conn)
    end

    test "reverses held and converted cash from the same payment together", %{conn: conn} do
      # room-a holds 9000 of the payment and room-b the other 1000.
      submit_one(
        conn,
        cancel_rooms_op(%{
          occurred_on: @refundable_on,
          room_ids: ["room-a"],
          refund_method: "hotel_credit"
        })
      )

      assert %{"available_cents" => 9900} = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{"charged_back_cents" => 10_000, "outstanding_deposit_cents" => 10_500} =
               submit_one(conn, charge_back_op())

      assert %{
               "held_cents" => 0,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 10_000
             } = read_payment(conn, "op-pay")

      assert %{"available_cents" => 0} = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = read_ledger(conn, on: @refundable_on)
    end

    test "works whether the group is active or cancelled", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @refundable_on}))

      assert %{"status" => "applied"} = submit_one(conn, charge_back_op())
      assert %{"status" => "cancelled", "revision" => 4} = read_group(conn, "group-81")
    end

    test "is remembered like any other operation", %{conn: conn} do
      first = submit_one(conn, charge_back_op())

      assert submit_one(conn, charge_back_op()) == first
      assert read_operation(conn, "op-charge-back") == first
      assert %{"revision" => 3} = read_group(conn, "group-81")
    end
  end

  describe "charge_back_payment and converted credit" do
    setup %{conn: conn} do
      submit_one(
        conn,
        cancel_op(%{
          operation_id: "cancel-17",
          occurred_on: @refundable_on,
          refund_method: "hotel_credit"
        })
      )

      :ok
    end

    test "revokes the credit the reversed cash bought", %{conn: conn} do
      assert %{"available_cents" => 11_000} = read_credit(conn, "guest-22", on: @refundable_on)

      assert %{"charged_back_cents" => 10_000} = submit_one(conn, charge_back_op())

      assert %{"available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-22", on: @refundable_on)

      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 10_000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = read_ledger(conn, on: @refundable_on)
    end

    test "leaves a shortfall when the credit has already been spent", %{conn: conn} do
      submit(conn, [
        open_group_op(%{
          operation_id: "op-open-2",
          group_id: "group-82",
          occurred_on: "2026-11-27",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        }),
        credit_op(%{
          operation_id: "op-credit",
          group_id: "group-82",
          occurred_on: "2026-11-28",
          amount_cents: 11_000
        })
      ])

      assert %{"charged_back_cents" => 10_000, "revision" => 4} =
               submit_one(conn, charge_back_op())

      # The credit is still funding group-82, so the lot cannot give it back.
      assert %{
               "credit_liability_cents" => 11_000,
               "credit_shortfall_cents" => 11_000,
               "cash_charged_back_cents" => 10_000
             } = read_ledger(conn, on: "2026-11-28")

      assert %{"available_cents" => 0} = read_credit(conn, "guest-22", on: "2026-11-28")

      # group-82 is untouched by the chargeback.
      assert %{"status" => "active", "revision" => 2, "credit_paid_cents" => 11_000} =
               read_group(conn, "group-82")
    end

    test "absorbs the clawback out of credit that comes back later", %{conn: conn} do
      submit(conn, [
        open_group_op(%{
          operation_id: "op-open-2",
          group_id: "group-82",
          occurred_on: "2026-11-27",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        }),
        credit_op(%{
          operation_id: "op-credit",
          group_id: "group-82",
          occurred_on: "2026-11-28",
          amount_cents: 8000
        }),
        charge_back_op()
      ])

      # 3000 of the lot was still there to take back, so 8000 is unrecovered.
      assert %{"credit_liability_cents" => 8000, "credit_shortfall_cents" => 8000} =
               read_ledger(conn, on: "2026-11-28")

      assert %{"status" => "applied", "refunded_cents" => 0} =
               submit_one(
                 conn,
                 cancel_op(%{
                   operation_id: "cancel-82",
                   group_id: "group-82",
                   occurred_on: "2027-01-27"
                 })
               )

      # The restored 8000 extinguishes the clawback before anything is available.
      assert %{"available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-22", on: "2027-01-27")

      assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} =
               read_ledger(conn, on: "2027-01-27")
    end

    test "a non-refundable settlement clears the shortfall by itself", %{conn: conn} do
      submit(conn, [
        open_group_op(%{
          operation_id: "op-open-2",
          group_id: "group-82",
          occurred_on: "2026-11-27",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        }),
        credit_op(%{
          operation_id: "op-credit",
          group_id: "group-82",
          occurred_on: "2026-11-28",
          amount_cents: 11_000
        }),
        charge_back_op(),
        cancel_op(%{
          operation_id: "cancel-82",
          group_id: "group-82",
          occurred_on: "2027-01-28"
        })
      ])

      assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} =
               read_ledger(conn, on: "2027-01-28")
    end
  end

  describe "charge_back_payment and shared credit lots" do
    setup %{conn: conn} do
      # Two payments of 1005 convert together into one lot of 2211.
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a", guest_id: "guest-a"}),
        payment_op(%{operation_id: "pay-1", group_id: "group-a", amount_cents: 1005}),
        payment_op(%{operation_id: "pay-2", group_id: "group-a", amount_cents: 1005}),
        cancel_op(%{
          operation_id: "cancel-a",
          group_id: "group-a",
          occurred_on: @refundable_on,
          refund_method: "hotel_credit"
        })
      ])

      assert %{"available_cents" => 2211} = read_credit(conn, "guest-a", on: @refundable_on)

      :ok
    end

    test "entitlements telescope to the lot instead of rounding twice", %{conn: conn} do
      # 1005 alone is worth 1106, so a second bonus on the same cash would
      # over-claw the lot. The later payment is only entitled to 1105.
      assert %{"charged_back_cents" => 1005} =
               submit_one(conn, charge_back_op(%{payment_operation_id: "pay-2"}))

      assert %{"available_cents" => 1106} = read_credit(conn, "guest-a", on: @refundable_on)

      assert %{"charged_back_cents" => 1005} =
               submit_one(
                 conn,
                 charge_back_op(%{operation_id: "op-cb-2", payment_operation_id: "pay-1"})
               )

      assert %{"available_cents" => 0} = read_credit(conn, "guest-a", on: @refundable_on)
    end

    test "only the excess over the clawback becomes available again", %{conn: conn} do
      submit(conn, [
        open_group_op(%{
          operation_id: "op-open-2",
          group_id: "group-82",
          guest_id: "guest-a",
          occurred_on: "2026-11-27",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        }),
        credit_op(%{
          operation_id: "op-credit",
          group_id: "group-82",
          occurred_on: "2026-11-28",
          amount_cents: 2000
        }),
        # pay-1 is entitled to 1106 of the lot, of which only 211 is still there.
        charge_back_op(%{payment_operation_id: "pay-1"})
      ])

      assert %{"credit_liability_cents" => 2000, "credit_shortfall_cents" => 895} =
               read_ledger(conn, on: "2026-11-28")

      submit_one(
        conn,
        cancel_op(%{
          operation_id: "cancel-82",
          group_id: "group-82",
          occurred_on: "2027-01-27"
        })
      )

      # The 2000 comes back, 895 of it extinguishes the clawback first.
      assert %{
               "available_cents" => 1105,
               "lots" => [%{"source_operation_id" => "cancel-a", "remaining_cents" => 1105}]
             } = read_credit(conn, "guest-a", on: "2027-01-27")

      assert %{"credit_liability_cents" => 1105, "credit_shortfall_cents" => 0} =
               read_ledger(conn, on: "2027-01-27")
    end

    test "the earlier payment keeps its own share when it is reversed first",
         %{conn: conn} do
      assert %{"charged_back_cents" => 1005} =
               submit_one(conn, charge_back_op(%{payment_operation_id: "pay-1"}))

      assert %{"available_cents" => 1105} = read_credit(conn, "guest-a", on: @refundable_on)
    end
  end

  describe "charge_back_payment rejections" do
    test "rejects an identifier nothing was recorded under", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "operation_not_found",
               "payment_operation_id" => "op-none"
             } = submit_one(conn, charge_back_op(%{payment_operation_id: "op-none"}))
    end

    test "rejects an operation that is not an applied cash payment", %{conn: conn} do
      assert %{"code" => "payment_not_chargeable"} =
               submit_one(conn, charge_back_op(%{payment_operation_id: "op-open"}))
    end

    test "rejects a payment that has already been charged back", %{conn: conn} do
      submit_one(conn, charge_back_op())

      assert %{"code" => "payment_not_chargeable", "group_id" => "group-81"} =
               submit_one(conn, charge_back_op(%{operation_id: "op-cb-2"}))

      assert %{"cash_charged_back_cents" => 10_000} = read_ledger(conn)
      assert %{"revision" => 3} = read_group(conn, "group-81")
    end

    test "rejects a payment that has been fully reduced", %{conn: conn} do
      submit_one(conn, reduce_op(%{amount_cents: 10_000}))

      assert %{"code" => "payment_not_chargeable"} = submit_one(conn, charge_back_op())
    end

    test "rejects a stale revision of the payment's group", %{conn: conn} do
      assert %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2} =
               submit_one(conn, charge_back_op(%{expected_revision: 1}))

      assert %{"cash_paid_cents" => 10_000, "revision" => 2} = read_group(conn, "group-81")
    end

    test "rejects an operation that cannot name its target", %{conn: conn} do
      assert %{"code" => "invalid_operation"} =
               submit_one(conn, Map.delete(charge_back_op(), "payment_operation_id"))
    end
  end
end
