defmodule GroupStayWeb.PolicyVersionTest do
  use GroupStayWeb.ConnCase

  # Deposit for the default rooms is 19_500 cents.

  describe "policy version on open" do
    test "flexible groups booked before 2027 use the 14-day window" do
      submit_one(
        open_group_op(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      )

      assert %{"policy_version" => "flex-14", "refundable_until" => "2027-02-15"} =
               get_group("group-81")
    end

    test "flexible groups booked from 2027 use the 30-day window" do
      submit_one(
        open_group_op(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      )

      assert %{"policy_version" => "flex-30", "refundable_until" => "2027-01-30"} =
               get_group("group-81")
    end

    test "advance purchase has no refundable date" do
      submit_one(
        open_group_op(%{
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        })
      )

      group = get_group("group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert Map.has_key?(group, "refundable_until")
      assert group["refundable_until"] == nil
    end

    test "a refundable date before the booking date is reported as is" do
      submit_one(
        open_group_op(%{
          "occurred_on" => "2027-01-10",
          "arrival_on" => "2027-01-20",
          "departure_on" => "2027-01-21"
        })
      )

      assert %{"policy_version" => "flex-30", "refundable_until" => "2026-12-21"} =
               get_group("group-81")
    end
  end

  describe "cancelling under flex-30" do
    setup do
      submit([
        open_group_op(%{
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-04"
        }),
        payment_op(%{"occurred_on" => "2027-01-06", "amount_cents" => 4000})
      ])

      :ok
    end

    test "refunds on the refundable_until date, 30 days before arrival" do
      assert %{"refunded_cents" => 4000, "retained_cents" => 0, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"occurred_on" => "2027-01-30"}))
    end

    test "retains cash 29 days before arrival" do
      assert %{"refunded_cents" => 0, "retained_cents" => 4000, "credit_issued_cents" => 0} =
               submit_one(cancel_op(%{"occurred_on" => "2027-01-31"}))
    end
  end

  describe "rescheduling" do
    test "keeps the original policy and recomputes refundable_until" do
      submit_one(open_group_op())

      assert submit_one(
               reschedule_op(%{
                 "operation_id" => "op-move-1",
                 "occurred_on" => "2027-02-01",
                 "new_arrival_on" => "2027-05-10"
               })
             ) == %{
               "operation_id" => "op-move-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-05-10",
               "new_departure_on" => "2027-05-13",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-04-26",
               "revision" => 2
             }

      assert %{"policy_version" => "flex-14", "refundable_until" => "2027-04-26"} =
               get_group("group-81")

      # 20 days' notice is refundable under the group's 14-day window.
      submit_one(payment_op(%{"occurred_on" => "2027-02-02", "amount_cents" => 1000}))

      assert %{"refunded_cents" => 1000} =
               submit_one(cancel_op(%{"occurred_on" => "2027-04-20"}))
    end

    test "reports a null refundable_until for advance purchase" do
      submit_one(open_group_op(%{"rate_plan" => "advance_purchase"}))

      assert %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil} =
               submit_one(reschedule_op())
    end
  end
end
