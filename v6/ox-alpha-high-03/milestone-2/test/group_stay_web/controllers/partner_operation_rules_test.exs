defmodule GroupStayWeb.PartnerOperationRulesTest do
  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  describe "record_cash_payment" do
    test "applies cash and reports the remaining outstanding deposit" do
      open_default_group("group-pay")

      results =
        run_and_get_results([
          pay_operation("group-pay", 9_750, %{"operation_id" => "op-1"}),
          pay_operation("group-pay", 9_750, %{"operation_id" => "op-2"})
        ])

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-pay",
                 "amount_cents" => 9_750,
                 "outstanding_deposit_cents" => 9_750,
                 "revision" => 2
               },
               %{
                 "status" => "applied",
                 "amount_cents" => 9_750,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             ] = results

      group = fetch_group("group-pay")
      assert group["deposit_paid_cents"] == 19_500
      assert group["outstanding_deposit_cents"] == 0
      assert group["revision"] == 3
    end

    test "rejects a payment exceeding the outstanding deposit" do
      open_default_group("group-over")

      results =
        run_and_get_results([
          pay_operation("group-over", 19_500, %{"operation_id" => "op-1"}),
          pay_operation("group-over", 1, %{"operation_id" => "op-2"})
        ])

      assert [%{"status" => "applied"}, second] = results

      assert second == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert fetch_group("group-over")["revision"] == 2
    end

    test "rejects amounts that are not usable as a payment" do
      open_default_group("group-amt")

      for amount <- [0, -100, 10.50, "19500", nil] do
        operation =
          if amount == nil do
            Map.delete(pay_operation("group-amt", 100), "amount_cents")
          else
            pay_operation("group-amt", amount)
          end

        results = run_and_get_results([operation])
        assert hd(results)["code"] == ((amount == nil && "invalid_operation") || "invalid_amount")
      end

      assert fetch_group("group-amt")["deposit_paid_cents"] == 0
    end

    test "rejects payments to missing or inactive groups" do
      open_default_group("group-inactive")
      run_and_get_results([cancel_operation("group-inactive")])

      missing = run_and_get_results([pay_operation("no-such-group", 100)])
      assert hd(missing)["code"] == "group_not_found"

      inactive = run_and_get_results([pay_operation("group-inactive", 100)])
      assert hd(inactive)["code"] == "group_not_active"
    end

    test "checks the group before the amount" do
      results = run_and_get_results([pay_operation("no-such-group", 0)])

      assert hd(results)["code"] == "group_not_found"
    end
  end

  describe "reschedule_group" do
    test "moves the whole stay by the same number of days without changing price" do
      open_default_group("group-move")

      results =
        run_and_get_results([
          reschedule_operation("group-move", "2026-12-15", %{"occurred_on" => "2026-11-01"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-reschedule",
               "status" => "applied",
               "group_id" => "group-move",
               "new_arrival_on" => "2026-12-15",
               "new_departure_on" => "2026-12-18",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-01",
               "revision" => 2
             }

      group = fetch_group("group-move")
      assert group["arrival_on"] == "2026-12-15"
      assert group["departure_on"] == "2026-12-18"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "rejects arrivals not after the operation date as invalid_stay" do
      open_default_group("group-move-date")

      for {occurred_on, new_arrival} <- [
            {"2026-12-01", "2026-12-01"},
            {"2026-12-01", "2026-11-30"},
            {"2026-12-01", "garbage"}
          ] do
        results =
          run_and_get_results([
            reschedule_operation("group-move-date", new_arrival, %{"occurred_on" => occurred_on})
          ])

        assert hd(results)["code"] == "invalid_stay"
      end

      group = fetch_group("group-move-date")
      assert group["arrival_on"] == "2026-12-10"
      assert group["revision"] == 1
    end

    test "rejects reschedules missing data or targeting unusable groups" do
      open_default_group("group-misc")
      run_and_get_results([cancel_operation("group-misc")])

      missing_field =
        run_and_get_results([
          Map.delete(reschedule_operation("group-misc", "2027-01-01"), "new_arrival_on")
        ])

      assert hd(missing_field)["code"] == "invalid_operation"

      assert hd(run_and_get_results([reschedule_operation("no-such-group", "2027-01-01")]))[
               "code"
             ] == "group_not_found"

      assert hd(run_and_get_results([reschedule_operation("group-misc", "2027-01-01")]))[
               "code"
             ] == "group_not_active"
    end

    test "increments the revision even when the visible dates stay the same" do
      open_default_group("group-same")

      results =
        run_and_get_results([
          reschedule_operation("group-same", "2026-12-10", %{"occurred_on" => "2026-11-01"})
        ])

      assert hd(results) == %{
               "operation_id" => "op-reschedule",
               "status" => "applied",
               "group_id" => "group-same",
               "new_arrival_on" => "2026-12-10",
               "new_departure_on" => "2026-12-13",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "revision" => 2
             }
    end
  end

  describe "cancel_group" do
    test "refunds flexible reservations cancelled at least 14 days before arrival" do
      open_default_group("group-flex")
      run_and_get_results([pay_operation("group-flex", 19_500)])

      results =
        run_and_get_results([
          cancel_operation("group-flex", %{"occurred_on" => "2026-11-26"})
        ])

      # Exactly 14 days before arrival on 2026-12-10.
      assert hd(results) == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-flex",
               "refunded_cents" => 19_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      ledger = fetch_ledger()
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 19_500
      assert ledger["cash_retained_cents"] == 0

      group = fetch_group("group-flex")
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
    end

    test "retains cash from flexible reservations cancelled inside 14 days" do
      open_default_group("group-late")
      run_and_get_results([pay_operation("group-late", 19_500)])

      results =
        run_and_get_results([cancel_operation("group-late", %{"occurred_on" => "2026-11-27"})])

      assert hd(results)["retained_cents"] == 19_500
      assert hd(results)["refunded_cents"] == 0

      ledger = fetch_ledger()
      assert ledger["cash_retained_cents"] == 19_500
      assert ledger["cash_refunded_cents"] == 0
    end

    test "advance purchase reservations are never refundable" do
      post_operations([
        open_operation(%{
          "group_id" => "group-ap-cancel",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        })
      ])

      run_and_get_results([pay_operation("group-ap-cancel", 10_000)])

      results =
        run_and_get_results([
          cancel_operation("group-ap-cancel", %{"occurred_on" => "2026-10-04"})
        ])

      assert hd(results)["retained_cents"] == 10_000
      assert hd(results)["refunded_cents"] == 0
    end

    test "cancelled groups reject later payments, reschedules, and cancellations" do
      open_default_group("group-dead")
      run_and_get_results([cancel_operation("group-dead")])

      for operation <- [
            pay_operation("group-dead", 100),
            reschedule_operation("group-dead", "2027-01-01"),
            cancel_operation("group-dead")
          ] do
        results = run_and_get_results([operation])
        assert hd(results)["code"] == "group_not_active"
      end

      assert fetch_group("group-dead")["revision"] == 2
    end

    test "unpaid deposit is simply no longer due after cancellation" do
      open_default_group("group-unpaid")
      run_and_get_results([pay_operation("group-unpaid", 5_000)])

      results = run_and_get_results([cancel_operation("group-unpaid")])

      assert [first] = results
      assert first["refunded_cents"] == 5_000
      assert first["retained_cents"] == 0

      assert fetch_group("group-unpaid")["outstanding_deposit_cents"] == 0
    end
  end

  describe "revisions and concurrent updates" do
    test "each applied operation increments the revision exactly once; rejections do not" do
      open_default_group("group-rev")

      results =
        run_and_get_results([
          pay_operation("group-rev", 1_000, %{"operation_id" => "op-1"}),
          pay_operation("group-rev", -5, %{"operation_id" => "op-2"}),
          reschedule_operation("group-rev", "2026-12-20", %{"operation_id" => "op-3"}),
          pay_operation("missing", 100, %{"operation_id" => "op-4"}),
          cancel_operation("group-rev", %{"operation_id" => "op-5"})
        ])

      assert [pay, rejected_pay, resched, _missing, cancel] = results
      assert pay["revision"] == 2
      assert rejected_pay["status"] == "rejected"
      refute Map.has_key?(rejected_pay, "revision")
      assert resched["revision"] == 3
      assert cancel["revision"] == 4

      assert fetch_group("group-rev")["revision"] == 4
    end

    test "expected_revision mismatch is reported with both values" do
      open_default_group("group-stale")

      results =
        run_and_get_results([
          pay_operation("group-stale", 1_000, %{
            "operation_id" => "op-1",
            "expected_revision" => 1
          }),
          pay_operation("group-stale", 1_000, %{
            "operation_id" => "op-2",
            "expected_revision" => 1
          })
        ])

      assert [%{"status" => "applied", "revision" => 2}, stale] = results

      assert stale == %{
               "operation_id" => "op-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-stale",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "stale revision is detected before other domain rules and leaves state untouched" do
      open_default_group("group-stale-first")

      results =
        run_and_get_results([
          pay_operation("group-stale-first", 999_999, %{
            "operation_id" => "op-1",
            "expected_revision" => 99
          })
        ])

      assert hd(results)["code"] == "stale_revision"

      group = fetch_group("group-stale-first")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
      assert fetch_ledger()["cash_held_cents"] == 0
    end

    test "existence is resolved before comparing revisions" do
      results =
        run_and_get_results([
          pay_operation("ghost-group", 1_000, %{"expected_revision" => 42})
        ])

      assert hd(results)["code"] == "group_not_found"
    end

    test "omitting expected_revision preserves unconditional behavior" do
      open_default_group("group-no-expect")

      results =
        run_and_get_results([
          pay_operation("group-no-expect", 1_000)
        ])

      assert hd(results)["status"] == "applied"
    end

    test "earlier operations in the same batch satisfy expected_revision" do
      results =
        run_and_get_results([
          open_operation(%{"group_id" => "group-chain"}),
          pay_operation("group-chain", 1_000, %{"expected_revision" => 1}),
          pay_operation("group-chain", 1_000, %{"expected_revision" => 2})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]
      assert List.last(results)["revision"] == 3
    end
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end
end
