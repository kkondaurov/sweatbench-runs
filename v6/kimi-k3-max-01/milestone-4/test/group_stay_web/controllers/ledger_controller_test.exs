defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      data = get_ledger!(conn)

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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
               "cash_retained_cents" => 19_500,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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

  describe "GET /api/v1/ledger credit totals" do
    test "hotel-credit cancellations convert cash into credit liability", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"})
      ])

      data = get_ledger!(fresh_conn())

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 19_500,
               "credit_liability_cents" => 21_450
             }
    end

    test "conversions are cumulative across cancellations", %{conn: _conn} do
      for group_id <- ["group-81", "group-82"] do
        apply_batch!(fresh_conn(), [
          open_group_op(%{"operation_id" => "op-open-#{group_id}", "group_id" => group_id}),
          record_cash_payment_op(%{
            "operation_id" => "op-pay-#{group_id}",
            "group_id" => group_id,
            "amount_cents" => 10_000
          }),
          cancel_group_op(%{
            "operation_id" => "op-cancel-#{group_id}",
            "group_id" => group_id,
            "refund_method" => "hotel_credit"
          })
        ])
      end

      data = get_ledger!(fresh_conn())
      assert data["cash_converted_to_credit_cents"] == 20_000
      assert data["credit_liability_cents"] == 22_000
    end

    test "applying credit does not change the liability", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"})
      ])

      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 21_450

      apply_batch!(fresh_conn(), [apply_hotel_credit_op(%{"amount_cents" => 19_500})])

      data = get_ledger!(fresh_conn())
      assert data["credit_liability_cents"] == 21_450
      # Applying credit is not cash: the cash totals are untouched.
      assert data["cash_held_cents"] == 0
      assert data["cash_converted_to_credit_cents"] == 19_500
    end

    test "expiry reduces the liability as of the requested date", %{conn: conn} do
      # The lot is available through 2027-11-01 and expires on 2027-11-02;
      # 19_500 of it funds group-82 with its expiry paused.
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 19_500})
      ])

      assert get_ledger!(fresh_conn(), "2027-11-01")["credit_liability_cents"] == 21_450
      assert get_ledger!(fresh_conn(), "2027-11-02")["credit_liability_cents"] == 19_500
    end

    test "non-refundable consumption reduces the liability", %{conn: conn} do
      apply_batch!(conn, [
        open_group_op(),
        record_cash_payment_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{"refund_method" => "hotel_credit"}),
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 19_500}),
        cancel_group_op(%{
          "operation_id" => "op-cancel-82",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-09"
        })
      ])

      assert get_ledger!(fresh_conn())["credit_liability_cents"] == 1_950
    end
  end
end
