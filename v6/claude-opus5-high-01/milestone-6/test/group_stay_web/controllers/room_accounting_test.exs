defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # The default group holds room-a (3 x 15_000, a 9000 deposit) and room-b
  # (3 x 17_500, a 10_500 deposit).
  describe "rooms in a group read" do
    test "report the deposit they require and nothing paid yet", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15_000,
                   "status" => "active",
                   "deposit_due_cents" => 9000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ]
             } = read_group(conn, "group-81")
    end

    test "cash fills one room's deposit before the next", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      assert %{
               "cash_paid_cents" => 10_000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 1000}
               ]
             } = read_group(conn, "group-81")
    end

    test "later funding continues where the previous operation stopped", %{conn: conn} do
      submit(conn, [
        open_group_op(),
        payment_op(),
        payment_op(%{operation_id: "op-pay-2", amount_cents: 9500})
      ])

      assert %{
               "cash_paid_cents" => 19_500,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 10_500}
               ]
             } = read_group(conn, "group-81")
    end

    test "credit fills the rooms cash has not reached", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a"}),
        payment_op(%{operation_id: "op-b", group_id: "group-a", amount_cents: 10_000}),
        cancel_op(%{
          operation_id: "cancel-17",
          group_id: "group-a",
          occurred_on: "2026-11-26",
          refund_method: "hotel_credit"
        }),
        open_group_op(%{occurred_on: "2026-11-27"}),
        payment_op(%{occurred_on: "2026-11-28", amount_cents: 5000}),
        credit_op(%{occurred_on: "2026-11-28", amount_cents: 11_000})
      ])

      assert %{
               "cash_paid_cents" => 5000,
               "credit_paid_cents" => 11_000,
               "outstanding_deposit_cents" => 3500,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "cash_paid_cents" => 5000,
                   "credit_paid_cents" => 4000
                 },
                 %{
                   "room_id" => "room-b",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 7000
                 }
               ]
             } = read_group(conn, "group-81")
    end
  end
end
