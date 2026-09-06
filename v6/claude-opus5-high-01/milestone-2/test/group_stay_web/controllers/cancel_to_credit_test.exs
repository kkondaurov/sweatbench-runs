defmodule GroupStayWeb.CancelToCreditTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  # The default group is flexible, booked 2026-10-03 and arriving 2026-12-10, so
  # 2026-11-26 is the last refundable day under its flex-14 policy.
  @refundable_on "2026-11-26"
  @too_late_on "2026-11-27"

  describe "cancel_group with refund_method: hotel_credit" do
    setup %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])
      :ok
    end

    test "turns the cash into a credit lot worth 110%", %{conn: conn} do
      assert %{
               "operation_id" => "cancel-17",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             } =
               submit_one(
                 conn,
                 cancel_op(%{
                   operation_id: "cancel-17",
                   occurred_on: @refundable_on,
                   refund_method: "hotel_credit"
                 })
               )

      assert %{
               "guest_id" => "guest-22",
               "available_cents" => 11_000,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 11_000,
                   # Available through 2027-11-26, the 365th day after cancellation.
                   "expires_on" => "2027-11-27"
                 }
               ]
             } = read_credit(conn, "guest-22", on: @refundable_on)
    end

    test "moves the cash out of held and into converted, not refunded or retained",
         %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @refundable_on, refund_method: "hotel_credit"}))

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 11_000
             } = read_ledger(conn, on: @refundable_on)
    end

    test "rounds the 10% bonus up on an exact half cent", %{conn: conn} do
      submit(conn, [
        open_group_op(%{operation_id: "op-a", group_id: "group-a", guest_id: "guest-a"}),
        payment_op(%{operation_id: "op-b", group_id: "group-a", amount_cents: 1005})
      ])

      assert %{"credit_issued_cents" => 1106} =
               submit_one(
                 conn,
                 cancel_op(%{
                   group_id: "group-a",
                   occurred_on: @refundable_on,
                   refund_method: "hotel_credit"
                 })
               )
    end

    test "issues nothing when the group holds no cash", %{conn: conn} do
      submit_one(conn, open_group_op(%{operation_id: "op-a", group_id: "group-a"}))

      assert %{"credit_issued_cents" => 0, "refunded_cents" => 0, "retained_cents" => 0} =
               submit_one(
                 conn,
                 cancel_op(%{
                   group_id: "group-a",
                   occurred_on: @refundable_on,
                   refund_method: "hotel_credit"
                 })
               )

      assert %{"available_cents" => 0, "lots" => []} =
               read_credit(conn, "guest-22", on: @refundable_on)
    end

    test "refuses to convert a non-refundable cancellation and leaves the group active",
         %{conn: conn} do
      assert %{
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "group-81"
             } =
               submit_one(
                 conn,
                 cancel_op(%{occurred_on: @too_late_on, refund_method: "hotel_credit"})
               )

      assert %{"status" => "active", "revision" => 2} = read_group(conn, "group-81")
      assert %{"cash_held_cents" => 10_000, "credit_liability_cents" => 0} = read_ledger(conn)
      assert %{"available_cents" => 0} = read_credit(conn, "guest-22")
    end

    test "refuses to convert an advance purchase cancellation", %{conn: conn} do
      submit(conn, [
        open_group_op(%{
          operation_id: "op-a",
          group_id: "group-a",
          rate_plan: "advance_purchase"
        }),
        payment_op(%{operation_id: "op-b", group_id: "group-a"})
      ])

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} =
               submit_one(
                 conn,
                 cancel_op(%{
                   group_id: "group-a",
                   occurred_on: "2026-10-06",
                   refund_method: "hotel_credit"
                 })
               )

      assert %{"status" => "active"} = read_group(conn, "group-a")
    end

    test "a refund method GroupStay cannot settle with is not available", %{conn: conn} do
      for method <- ["voucher", "points", "", 7, true] do
        assert %{"status" => "rejected", "code" => "refund_method_not_available"} =
                 submit_one(
                   conn,
                   cancel_op(%{occurred_on: @refundable_on, refund_method: method})
                 ),
               "expected refund_method_not_available for #{inspect(method)}"
      end

      assert %{"status" => "active", "revision" => 2} = read_group(conn, "group-81")
    end

    test "a cancelled group reports group_not_active before the refund method", %{conn: conn} do
      submit_one(conn, cancel_op(%{occurred_on: @too_late_on}))

      assert %{"status" => "rejected", "code" => "group_not_active"} =
               submit_one(
                 conn,
                 cancel_op(%{
                   operation_id: "op-2",
                   occurred_on: @too_late_on,
                   refund_method: "hotel_credit"
                 })
               )
    end

    test "a stale revision is rejected before the refund method", %{conn: conn} do
      assert %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2} =
               submit_one(
                 conn,
                 cancel_op(%{
                   expected_revision: 1,
                   occurred_on: @too_late_on,
                   refund_method: "hotel_credit"
                 })
               )

      assert %{"status" => "active", "revision" => 2} = read_group(conn, "group-81")
    end
  end

  describe "cancel_group with refund_method: cash" do
    test "an absent or null refund method means cash", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      assert %{"status" => "applied", "refunded_cents" => 10_000, "credit_issued_cents" => 0} =
               submit_one(conn, cancel_op(%{occurred_on: @refundable_on, refund_method: nil}))
    end

    test "is the default and still refunds cash", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      assert %{
               "status" => "applied",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } =
               submit_one(conn, cancel_op(%{occurred_on: @refundable_on, refund_method: "cash"}))

      assert %{"credit_liability_cents" => 0, "cash_converted_to_credit_cents" => 0} =
               read_ledger(conn)
    end

    test "is accepted for a non-refundable cancellation and retains the cash", %{conn: conn} do
      submit(conn, [open_group_op(), payment_op()])

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "credit_issued_cents" => 0
             } = submit_one(conn, cancel_op(%{occurred_on: @too_late_on, refund_method: "cash"}))
    end
  end
end
