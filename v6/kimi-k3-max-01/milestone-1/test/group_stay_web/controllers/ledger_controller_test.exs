defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      data = get_ledger!(conn)

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "holds cash applied to active reservations", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_group_op(%{"operation_id" => "op-2", "group_id" => "group-82"}),
        record_cash_payment_op(%{
          "operation_id" => "op-3",
          "group_id" => "group-82",
          "amount_cents" => 5_000
        })
      ])

      data = get_ledger!(fresh_conn())
      assert data["cash_held_cents"] == 15_000
      assert data["cash_refunded_cents"] == 0
      assert data["cash_retained_cents"] == 0
    end

    test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
      apply_batch!(conn, [open_group_op()])

      data = get_ledger!(fresh_conn())
      assert data["cash_held_cents"] == 0
    end

    test "a refundable cancellation moves held cash to refunded", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"occurred_on" => "2026-11-26"})
      ])

      data = get_ledger!(fresh_conn())

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 19_500,
               "cash_retained_cents" => 0
             }
    end

    test "a non-refundable cancellation moves held cash to retained", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"occurred_on" => "2026-12-09"})
      ])

      data = get_ledger!(fresh_conn())

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 19_500
             }
    end

    test "cancellation only moves the cash that was actually paid", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 4_000}),
        cancel_group_op(%{"occurred_on" => "2026-12-09"})
      ])

      data = get_ledger!(fresh_conn())
      assert data["cash_held_cents"] == 0
      assert data["cash_retained_cents"] == 4_000
    end

    test "partial cancellations keep other groups' cash held", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 10_000}),
        open_group_op(%{"operation_id" => "op-2", "group_id" => "group-82"}),
        record_cash_payment_op(%{
          "operation_id" => "op-3",
          "group_id" => "group-82",
          "amount_cents" => 6_000
        }),
        cancel_group_op(%{"operation_id" => "op-4", "group_id" => "group-82"})
      ])

      data = get_ledger!(fresh_conn())
      assert data["cash_held_cents"] == 10_000
      assert data["cash_refunded_cents"] == 6_000
      assert data["cash_retained_cents"] == 0
    end
  end
end
