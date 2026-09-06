defmodule GroupStayWeb.ApplyHotelCreditTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # Cancelling group-81 on its last refundable day converts its 10_000 cash into a
  # lot of 11_000 that is available through 2027-11-26 and expires 2027-11-27.
  @lot_expires_on "2027-11-27"
  @lot_last_day "2027-11-26"

  setup %{conn: conn} do
    submit(conn, [
      open_group_op(),
      payment_op(),
      cancel_op(%{
        operation_id: "cancel-17",
        occurred_on: "2026-11-26",
        refund_method: "hotel_credit"
      }),
      open_group_op(%{
        operation_id: "op-open-2",
        group_id: "group-82",
        occurred_on: "2026-11-27",
        arrival_on: "2027-02-10",
        departure_on: "2027-02-13"
      })
    ])

    :ok
  end

  defp credit(overrides) do
    credit_op(Map.merge(%{group_id: "group-82", occurred_on: "2026-11-28"}, overrides))
  end

  describe "apply_hotel_credit" do
    test "redeems credit into the outstanding deposit", %{conn: conn} do
      assert %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-82",
               "amount_cents" => 11_000,
               "outstanding_deposit_cents" => 8500,
               "revision" => 2
             } = submit_one(conn, credit(%{amount_cents: 11_000}))

      assert %{
               "deposit_paid_cents" => 11_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 11_000,
               "outstanding_deposit_cents" => 8500
             } = read_group(conn, "group-82")

      assert %{"available_cents" => 0, "lots" => []} = read_credit(conn, "guest-22")
    end

    test "leaves the credit liability unchanged and adds no cash", %{conn: conn} do
      submit_one(conn, credit(%{amount_cents: 11_000}))

      assert %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             } = read_ledger(conn)
    end

    test "spends part of a lot and leaves the rest available", %{conn: conn} do
      submit_one(conn, credit(%{amount_cents: 4000}))

      assert %{
               "available_cents" => 7000,
               "lots" => [%{"source_operation_id" => "cancel-17", "remaining_cents" => 7000}]
             } = read_credit(conn, "guest-22")

      assert %{"credit_paid_cents" => 4000} = read_group(conn, "group-82")
    end

    test "credit and cash both fund the same deposit", %{conn: conn} do
      submit(conn, [
        credit(%{amount_cents: 11_000}),
        payment_op(%{operation_id: "op-pay-2", group_id: "group-82", amount_cents: 8500})
      ])

      assert %{
               "deposit_paid_cents" => 19_500,
               "cash_paid_cents" => 8500,
               "credit_paid_cents" => 11_000,
               "outstanding_deposit_cents" => 0
             } = read_group(conn, "group-82")

      assert %{"cash_held_cents" => 8500, "credit_liability_cents" => 11_000} = read_ledger(conn)
    end

    test "cannot exceed the outstanding deposit", %{conn: conn} do
      submit_one(conn, payment_op(%{operation_id: "op-pay-2", group_id: "group-82"}))

      assert %{
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding",
               "group_id" => "group-82"
             } = submit_one(conn, credit(%{amount_cents: 9501}))

      assert %{"credit_paid_cents" => 0, "revision" => 2} = read_group(conn, "group-82")
      assert %{"available_cents" => 11_000} = read_credit(conn, "guest-22")
    end

    test "rejects more credit than the guest holds", %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "insufficient_credit",
               "group_id" => "group-82"
             } = submit_one(conn, credit(%{amount_cents: 11_001}))

      assert %{"credit_paid_cents" => 0, "revision" => 1} = read_group(conn, "group-82")
      assert %{"available_cents" => 11_000} = read_credit(conn, "guest-22")
    end

    test "another guest's credit is not usable", %{conn: conn} do
      submit_one(
        conn,
        open_group_op(%{
          operation_id: "op-open-3",
          group_id: "group-83",
          guest_id: "guest-99",
          occurred_on: "2026-11-27"
        })
      )

      assert %{"status" => "rejected", "code" => "insufficient_credit"} =
               submit_one(conn, credit(%{group_id: "group-83", amount_cents: 100}))
    end

    test "expiry is evaluated on the operation date", %{conn: conn} do
      assert %{"status" => "applied"} =
               submit_one(
                 conn,
                 credit(%{amount_cents: 11_000, occurred_on: @lot_last_day})
               )
    end

    test "expired credit cannot be applied", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "insufficient_credit"} =
               submit_one(
                 conn,
                 credit(%{amount_cents: 11_000, occurred_on: @lot_expires_on})
               )

      assert %{"credit_paid_cents" => 0, "revision" => 1} = read_group(conn, "group-82")
    end

    test "rejects amounts that are not usable as a payment", %{conn: conn} do
      for amount <- [0, -100, "100", 100.5, nil] do
        assert %{"status" => "rejected", "code" => "invalid_amount"} =
                 submit_one(conn, credit(%{amount_cents: amount})),
               "expected invalid_amount for #{inspect(amount)}"
      end

      assert %{"status" => "rejected", "code" => "invalid_amount"} =
               submit_one(conn, Map.delete(credit(%{}), "amount_cents"))
    end

    test "rejects a missing, cancelled, or unidentified group", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "group_not_found"} =
               submit_one(conn, credit(%{group_id: "group-none"}))

      assert %{"status" => "rejected", "code" => "group_not_active"} =
               submit_one(conn, credit(%{group_id: "group-81"}))

      assert %{"status" => "rejected", "code" => "invalid_operation"} =
               submit_one(conn, Map.delete(credit(%{}), "group_id"))
    end

    test "follows the revision contract", %{conn: conn} do
      assert %{"status" => "applied", "revision" => 2} =
               submit_one(conn, credit(%{amount_cents: 1000, expected_revision: 1}))

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "expected_revision" => 1,
               "actual_revision" => 2
             } = submit_one(conn, credit(%{amount_cents: 1000, expected_revision: 1}))

      assert %{"credit_paid_cents" => 1000, "revision" => 2} = read_group(conn, "group-82")
    end

    test "compares revisions before the credit balance", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "stale_revision"} =
               submit_one(conn, credit(%{amount_cents: 999_999, expected_revision: 7}))
    end
  end

  describe "lot ordering" do
    setup %{conn: conn} do
      # Two more lots for guest-22: one expiring before cancel-17's lot, and one
      # expiring on the same day but with a later source operation identifier.
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a"}),
        payment_op(%{operation_id: "op-a-pay", group_id: "group-a", amount_cents: 1000}),
        cancel_op(%{
          operation_id: "cancel-01",
          group_id: "group-a",
          occurred_on: "2026-11-25",
          refund_method: "hotel_credit"
        }),
        open_group_op(%{operation_id: "op-b", group_id: "group-b"}),
        payment_op(%{operation_id: "op-b-pay", group_id: "group-b", amount_cents: 2000}),
        cancel_op(%{
          operation_id: "cancel-99",
          group_id: "group-b",
          occurred_on: "2026-11-26",
          refund_method: "hotel_credit"
        })
      ])

      :ok
    end

    test "lists lots by expiry, then by source operation", %{conn: conn} do
      assert %{
               "available_cents" => 14_300,
               "lots" => [
                 %{"source_operation_id" => "cancel-01", "remaining_cents" => 1100},
                 %{"source_operation_id" => "cancel-17", "remaining_cents" => 11_000},
                 %{"source_operation_id" => "cancel-99", "remaining_cents" => 2200}
               ]
             } = read_credit(conn, "guest-22")
    end

    test "consumes lots by earliest expiry, then by source operation", %{conn: conn} do
      submit_one(conn, credit(%{amount_cents: 12_500}))

      assert %{
               "available_cents" => 1800,
               "lots" => [%{"source_operation_id" => "cancel-99", "remaining_cents" => 1800}]
             } = read_credit(conn, "guest-22")
    end
  end
end
