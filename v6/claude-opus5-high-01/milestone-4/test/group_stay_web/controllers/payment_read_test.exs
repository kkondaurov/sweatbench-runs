defmodule GroupStayWeb.PaymentReadTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  @refundable_on "2026-11-26"

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition of a payment, including the zero ones", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      assert %{"data" => data} =
               conn |> get("/api/v1/payments/op-pay") |> json_response(200)

      assert data == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 10_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "splits one payment across everything that happened to it", %{conn: conn} do
      submit(conn, [
        open_group_op(),
        payment_op(),
        # 1000 of the payment is corrected away, leaving 9000 on room-a.
        reduce_op(%{amount_cents: 1000}),
        # room-a is refunded, room-b keeps nothing of this payment.
        cancel_rooms_op(%{occurred_on: @refundable_on, room_ids: ["room-a"]})
      ])

      assert %{
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 9000,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             } = read_payment(conn, "op-pay")

      assert %{"cash_refunded_cents" => 9000, "cash_reduced_cents" => 1000} = read_ledger(conn)

      submit_one(conn, charge_back_op())

      assert %{
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 9000
             } = read_payment(conn, "op-pay")
    end

    test "agrees with the group and ledger views while a payment is split", %{conn: conn} do
      submit(conn, [
        open_group_op(),
        payment_op(%{operation_id: "pay-1", amount_cents: 9000}),
        payment_op(%{operation_id: "pay-2", amount_cents: 10_500}),
        cancel_rooms_op(%{
          occurred_on: @refundable_on,
          room_ids: ["room-a"],
          refund_method: "hotel_credit"
        })
      ])

      assert %{"held_cents" => 0, "converted_to_credit_cents" => 9000} =
               read_payment(conn, "pay-1")

      assert %{"held_cents" => 10_500, "converted_to_credit_cents" => 0} =
               read_payment(conn, "pay-2")

      assert %{"cash_paid_cents" => 10_500, "rooms" => [_room_a, %{"cash_paid_cents" => 10_500}]} =
               read_group(conn, "group-81")

      assert %{"cash_held_cents" => 10_500, "cash_converted_to_credit_cents" => 9000} =
               read_ledger(conn, on: @refundable_on)
    end

    test "a payment nothing was recorded under is a 404", %{conn: conn} do
      assert %{"error" => %{"code" => "operation_not_found"}} =
               conn |> get("/api/v1/payments/op-none") |> json_response(404)
    end

    test "an operation that is not an applied cash payment is a 422", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
               conn |> get("/api/v1/payments/op-open") |> json_response(422)
    end

    test "a rejected payment is a 422", %{conn: conn} do
      submit(conn, [
        open_group_op(),
        payment_op(%{operation_id: "op-too-big", amount_cents: 100_000})
      ])

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
               conn |> get("/api/v1/payments/op-too-big") |> json_response(422)
    end

    test "reading a statement changes nothing", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      before = read_group(conn, "group-81")
      assert %{"held_cents" => 10_000} = read_payment(conn, "op-pay")
      assert read_group(conn, "group-81") == before
    end
  end
end
