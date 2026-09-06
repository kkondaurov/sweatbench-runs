defmodule GroupStayWeb.CancelGroupTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "cancel_group" do
    test "refunds cash when a flexible stay is cancelled at least 14 days out", %{conn: conn} do
      submit_one(conn, open_group_op())
      submit_one(conn, payment_op())

      # 14 calendar days before the 2026-12-10 arrival.
      assert %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 3
             } = submit_one(conn, cancel_op(%{occurred_on: "2026-11-26"}))

      assert %{
               "status" => "cancelled",
               "deposit_paid_cents" => 10_000,
               "deposit_due_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             } = read_group(conn, "group-81")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0
             } = read_ledger(conn)
    end

    test "retains cash when a flexible stay is cancelled inside 14 days", %{conn: conn} do
      submit_one(conn, open_group_op())
      submit_one(conn, payment_op())

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000} =
               submit_one(conn, cancel_op(%{occurred_on: "2026-11-27"}))

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 10_000
             } = read_ledger(conn)
    end

    test "an advance purchase stay is never refundable", %{conn: conn} do
      submit_one(conn, open_group_op(%{rate_plan: "advance_purchase"}))
      submit_one(conn, payment_op())

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000} =
               submit_one(conn, cancel_op(%{occurred_on: "2026-10-06"}))

      assert %{"cash_retained_cents" => 10_000} = read_ledger(conn)
    end

    test "cancelling without cash settles nothing and drops the unpaid deposit", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0} =
               submit_one(conn, cancel_op())

      assert %{"outstanding_deposit_cents" => 0, "status" => "cancelled"} =
               read_group(conn, "group-81")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             } = read_ledger(conn)
    end

    test "cancellation uses the rescheduled arrival date", %{conn: conn} do
      submit_one(conn, open_group_op())
      submit_one(conn, payment_op())
      submit_one(conn, reschedule_op(%{new_arrival_on: "2026-10-20"}))

      # 2026-10-06 is more than 14 days before the original arrival, but only 14
      # days before the new one, so the cash is still refunded.
      assert %{"status" => "applied", "refunded_cents" => 10_000} =
               submit_one(conn, cancel_op(%{occurred_on: "2026-10-06"}))
    end

    test "a cancelled group cannot be cancelled again", %{conn: conn} do
      submit_one(conn, open_group_op())
      submit_one(conn, payment_op())
      submit_one(conn, cancel_op(%{occurred_on: "2026-11-27"}))

      assert %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"} =
               submit_one(conn, cancel_op(%{operation_id: "op-2", occurred_on: "2026-11-28"}))

      assert %{"revision" => 3} = read_group(conn, "group-81")
      assert %{"cash_retained_cents" => 10_000} = read_ledger(conn)
    end

    test "rejects a missing group", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "group_not_found"} =
               submit_one(conn, cancel_op(%{group_id: "group-none"}))
    end
  end
end
