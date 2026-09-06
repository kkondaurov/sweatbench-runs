defmodule GroupStayWeb.Acceptance.GroupLifecycleTest do
  use GroupStayWeb.ConnCase, async: true

  describe "recording cash payments" do
    test "applies cash to an active group's outstanding deposit" do
      open_group!(build_conn())

      result =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"amount_cents" => 5000, "expected_revision" => 1})
        )

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             }

      assert %{
               "deposit_paid_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             } = group_data("group-81")
    end

    test "the deposit can be paid in full" do
      open_group!(build_conn())
      result = apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 19500}))
      assert %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2} = result
    end

    test "a payment may not exceed the outstanding deposit" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 10000}))

      result = apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 9501}))

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = result
      assert group_data("group-81")["deposit_paid_cents"] == 10000
      assert group_data("group-81")["revision"] == 2
    end

    test "unusable amounts are rejected" do
      open_group!(build_conn())

      for amount <- [0, -100, 500.5, "500", nil] do
        result = apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => amount}))
        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end

      assert group_data("group-81")["deposit_paid_cents"] == 0
    end

    test "a payment for a missing group is rejected" do
      result = apply_one!(build_conn(), record_cash_operation(%{"group_id" => "ghost"}))
      assert %{"status" => "rejected", "code" => "group_not_found"} = result
    end

    test "a payment for a cancelled group is rejected" do
      open_group!(build_conn())
      apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-10-04"}))

      result = apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 100}))
      assert %{"status" => "rejected", "code" => "group_not_active"} = result
    end
  end

  describe "rescheduling a group" do
    test "shifts arrival and departure by the same number of days" do
      open_group!(build_conn())

      result =
        apply_one!(
          build_conn(),
          reschedule_operation(%{"occurred_on" => "2026-10-04", "new_arrival_on" => "2026-12-20"})
        )

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      assert %{
               "arrival_on" => "2026-12-20",
               "departure_on" => "2026-12-23",
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "revision" => 2
             } = group_data("group-81")
    end

    test "an applied reschedule to the same arrival still increments the revision" do
      open_group!(build_conn())

      result =
        apply_one!(
          build_conn(),
          reschedule_operation(%{"new_arrival_on" => "2026-12-10"})
        )

      assert %{"status" => "applied", "revision" => 2} = result
      assert group_data("group-81")["arrival_on"] == "2026-12-10"
    end

    test "a reschedule keeps the length and price of the stay" do
      open_group!(build_conn())
      apply_one!(build_conn(), reschedule_operation(%{"new_arrival_on" => "2027-01-02"}))

      assert %{
               "arrival_on" => "2027-01-02",
               "departure_on" => "2027-01-05",
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500
             } = group_data("group-81")
    end

    test "the new arrival must be after the operation date" do
      open_group!(build_conn())

      for date <- ["2026-10-04", "2026-10-03", "2026-09-01"] do
        result = apply_one!(build_conn(), reschedule_operation(%{"new_arrival_on" => date}))
        assert %{"status" => "rejected", "code" => "invalid_stay"} = result
      end

      assert group_data("group-81")["arrival_on"] == "2026-12-10"
      assert group_data("group-81")["revision"] == 1
    end

    test "an unusable new arrival date is rejected" do
      open_group!(build_conn())
      result = apply_one!(build_conn(), reschedule_operation(%{"new_arrival_on" => "soon"}))
      assert %{"status" => "rejected", "code" => "invalid_stay"} = result
    end

    test "a missing group is rejected" do
      result = apply_one!(build_conn(), reschedule_operation(%{"group_id" => "ghost"}))
      assert %{"status" => "rejected", "code" => "group_not_found"} = result
    end

    test "a cancelled group cannot be moved" do
      open_group!(build_conn())
      apply_one!(build_conn(), cancel_operation())

      result = apply_one!(build_conn(), reschedule_operation(%{"new_arrival_on" => "2026-12-20"}))
      assert %{"status" => "rejected", "code" => "group_not_active"} = result
    end
  end

  describe "cancelling a group" do
    test "a flexible group cancelled at least 14 days before arrival is refunded" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 5000}))

      # Arrival 2026-12-10: cancelling on 2026-11-26 is exactly 14 days before.
      result = apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 5000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
    end

    test "a flexible group cancelled later is non-refundable" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 5000}))

      # Cancelling 13 days before arrival.
      result = apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-27"}))

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 5000,
               "revision" => 3
             } = result
    end

    test "an advance-purchase group is never refundable" do
      open_group!(build_conn(), %{"rate_plan" => "advance_purchase"})
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 9999}))

      result = apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-10-04"}))

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 9999} = result
    end

    test "an unpaid group cancels with nothing refunded or retained" do
      open_group!(build_conn())

      result = apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "revision" => 2
             } = result
    end

    test "the group becomes cancelled and its unpaid deposit is no longer due" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 5000}))
      apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 5000,
               "outstanding_deposit_cents" => 0,
               "revision" => 3
             } = group_data("group-81")
    end

    test "a cancelled group rejects later payments, reschedules, and cancellations" do
      open_group!(build_conn())
      apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      for operation <- [
            record_cash_operation(%{"amount_cents" => 100}),
            reschedule_operation(%{"new_arrival_on" => "2026-12-20"}),
            cancel_operation(%{"occurred_on" => "2026-11-26"})
          ] do
        result = apply_one!(build_conn(), operation)
        assert %{"status" => "rejected", "code" => "group_not_active"} = result
      end

      assert group_data("group-81")["revision"] == 2
    end

    test "a missing group is rejected" do
      result = apply_one!(build_conn(), cancel_operation(%{"group_id" => "ghost"}))
      assert %{"status" => "rejected", "code" => "group_not_found"} = result
    end
  end

  describe "revisions" do
    test "every applied operation increments the revision exactly once" do
      open_group!(build_conn())
      assert group_data("group-81")["revision"] == 1

      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))
      apply_one!(build_conn(), reschedule_operation(%{"new_arrival_on" => "2026-12-20"}))
      apply_one!(build_conn(), cancel_operation(%{"occurred_on" => "2026-11-26"}))

      assert group_data("group-81")["revision"] == 5
    end

    test "rejected operations never increment the revision" do
      open_group!(build_conn())

      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 0}))
      apply_one!(build_conn(), reschedule_operation(%{"new_arrival_on" => "2026-01-01"}))
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 999_999}))
      apply_one!(build_conn(), cancel_operation(%{"group_id" => "ghost"}))

      assert group_data("group-81")["revision"] == 1
    end

    test "a matching expected_revision applies the operation" do
      open_group!(build_conn())

      apply_one!(
        build_conn(),
        record_cash_operation(%{"amount_cents" => 1000, "expected_revision" => 1})
      )

      result =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"amount_cents" => 1000, "expected_revision" => 2})
        )

      assert %{"status" => "applied", "revision" => 3} = result
    end

    test "a stale expected_revision is rejected with the current revision" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))

      result =
        apply_one!(
          build_conn(),
          reschedule_operation(%{
            "new_arrival_on" => "2026-12-20",
            "expected_revision" => 1
          })
        )

      assert result == %{
               "operation_id" => "op-move",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert %{"revision" => 2, "arrival_on" => "2026-12-10"} = group_data("group-81")
      assert %{"cash_held_cents" => 1000} = ledger()
    end

    test "a stale revision is rejected before other domain rules" do
      open_group!(build_conn())

      result =
        apply_one!(
          build_conn(),
          record_cash_operation(%{"amount_cents" => -5, "expected_revision" => 7})
        )

      assert %{"status" => "rejected", "code" => "stale_revision"} = result
    end

    test "group existence is resolved before the revision check" do
      result =
        apply_one!(
          build_conn(),
          cancel_operation(%{"group_id" => "ghost", "expected_revision" => 5})
        )

      assert %{"status" => "rejected", "code" => "group_not_found"} = result
    end

    test "omitting expected_revision preserves the unconditional behavior" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))
      result = apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 1000}))
      assert %{"status" => "applied", "revision" => 3} = result
    end
  end

  describe "finance totals" do
    test "an empty ledger reports zeros" do
      assert %{"data" => data} = json_response(get_ledger(build_conn()), 200)

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "cash held is cash applied to active reservations" do
      open_group!(build_conn())
      apply_one!(build_conn(), record_cash_operation(%{"amount_cents" => 5000}))

      assert %{
               "cash_held_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             } == ledger()
    end

    test "cancellation moves held cash to refunded or retained" do
      open_group!(build_conn(), %{"group_id" => "group-refund"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-refund", "amount_cents" => 5000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-refund", "occurred_on" => "2026-11-26"})
      )

      open_group!(build_conn(), %{"group_id" => "group-retain", "rate_plan" => "advance_purchase"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-retain", "amount_cents" => 3000})
      )

      apply_one!(
        build_conn(),
        cancel_operation(%{"group_id" => "group-retain", "occurred_on" => "2026-11-26"})
      )

      open_group!(build_conn(), %{"group_id" => "group-active"})

      apply_one!(
        build_conn(),
        record_cash_operation(%{"group_id" => "group-active", "amount_cents" => 7000})
      )

      assert %{
               "cash_held_cents" => 7000,
               "cash_refunded_cents" => 5000,
               "cash_retained_cents" => 3000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             } == ledger()
    end
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end

  defp ledger do
    assert %{status: 200} = conn = get_ledger(build_conn())
    json_response(conn, 200)["data"]
  end
end
