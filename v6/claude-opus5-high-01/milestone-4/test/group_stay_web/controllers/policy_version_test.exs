defmodule GroupStayWeb.PolicyVersionTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "policy versions" do
    test "a flexible group booked before 2027 keeps the 14-day window", %{conn: conn} do
      submit_one(conn, open_group_op(%{occurred_on: "2026-12-31"}))

      assert %{"policy_version" => "flex-14", "refundable_until" => "2026-11-26"} =
               read_group(conn, "group-81")
    end

    test "a flexible group booked from 2027 uses the 30-day window", %{conn: conn} do
      submit_one(
        conn,
        open_group_op(%{
          occurred_on: "2027-01-01",
          arrival_on: "2027-12-10",
          departure_on: "2027-12-13"
        })
      )

      assert %{"policy_version" => "flex-30", "refundable_until" => "2027-11-10"} =
               read_group(conn, "group-81")
    end

    test "an advance purchase group has no refundable date", %{conn: conn} do
      submit_one(conn, open_group_op(%{rate_plan: "advance_purchase"}))

      assert %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil} =
               read_group(conn, "group-81")
    end

    test "the 30-day window governs cancellation", %{conn: conn} do
      submit(conn, [
        open_group_op(%{
          occurred_on: "2027-01-01",
          arrival_on: "2027-12-10",
          departure_on: "2027-12-13"
        }),
        payment_op(%{operation_id: "op-2", occurred_on: "2027-01-02"})
      ])

      # 2027-11-11 is 29 days out, inside the new window.
      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000} =
               submit_one(conn, cancel_op(%{occurred_on: "2027-11-11"}))
    end

    test "a group booked before 2027 is not moved to the newer policy by a reschedule",
         %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{
               "status" => "applied",
               "new_arrival_on" => "2027-12-10",
               "new_departure_on" => "2027-12-13",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-11-26",
               "revision" => 2
             } = submit_one(conn, reschedule_op(%{new_arrival_on: "2027-12-10"}))

      assert %{"policy_version" => "flex-14", "refundable_until" => "2027-11-26"} =
               read_group(conn, "group-81")

      # Still the 14-day window: 2027-11-26 is refundable, the next day is not.
      assert %{"status" => "applied", "refunded_cents" => 0} =
               submit_one(conn, cancel_op(%{occurred_on: "2027-11-26"}))
    end

    test "rescheduling an advance purchase group reports no refundable date", %{conn: conn} do
      submit_one(conn, open_group_op(%{rate_plan: "advance_purchase"}))

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = submit_one(conn, reschedule_op())
    end
  end
end
