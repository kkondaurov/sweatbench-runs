defmodule GroupStayWeb.RescheduleGroupTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  setup %{conn: conn} do
    submit_one(conn, open_group_op())
    :ok
  end

  describe "reschedule_group" do
    test "shifts departure by the same number of days and keeps the price", %{conn: conn} do
      assert %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-17",
               "new_departure_on" => "2026-12-20",
               "revision" => 2
             } = submit_one(conn, reschedule_op())

      assert %{
               "arrival_on" => "2026-12-17",
               "departure_on" => "2026-12-20",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "booked_on" => "2026-10-03"
             } = read_group(conn, "group-81")
    end

    test "can move a stay earlier", %{conn: conn} do
      assert %{
               "status" => "applied",
               "new_arrival_on" => "2026-10-06",
               "new_departure_on" => "2026-10-09"
             } = submit_one(conn, reschedule_op(%{new_arrival_on: "2026-10-06"}))
    end

    test "keeps cash already paid", %{conn: conn} do
      submit_one(conn, payment_op())
      submit_one(conn, reschedule_op())

      assert %{"deposit_paid_cents" => 10_000, "outstanding_deposit_cents" => 9500} =
               read_group(conn, "group-81")

      assert %{"cash_held_cents" => 10_000} = read_ledger(conn)
    end

    test "rejects an arrival that is not after the operation date", %{conn: conn} do
      for new_arrival_on <- ["2026-10-05", "2026-10-04", "nonsense", nil] do
        assert %{"status" => "rejected", "code" => "invalid_stay"} =
                 submit_one(conn, reschedule_op(%{new_arrival_on: new_arrival_on})),
               "expected invalid_stay for #{inspect(new_arrival_on)}"
      end

      assert %{"status" => "rejected", "code" => "invalid_stay"} =
               submit_one(conn, Map.delete(reschedule_op(), "new_arrival_on"))

      assert %{"arrival_on" => "2026-12-10", "revision" => 1} = read_group(conn, "group-81")
    end

    test "rejects a missing or cancelled group", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "group_not_found"} =
               submit_one(conn, reschedule_op(%{group_id: "group-none"}))

      submit_one(conn, cancel_op())

      assert %{"status" => "rejected", "code" => "group_not_active"} =
               submit_one(conn, reschedule_op())

      assert %{"arrival_on" => "2026-12-10"} = read_group(conn, "group-81")
    end
  end
end
