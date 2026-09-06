defmodule GroupStayWeb.AddressedOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp open_group(overrides \\ %{}) do
    conn = post_batch([open_group_op(overrides)])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit" do
      open_group()
      conn = post_batch([record_cash_payment_op(%{"amount_cents" => 12_000})])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 12_000,
                   "outstanding_deposit_cents" => 7_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects a payment to a missing group" do
      conn = post_batch([record_cash_payment_op(%{"group_id" => "group-missing"})])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "group_not_found",
                   "group_id" => "group-missing"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unusable amounts with invalid_amount" do
      open_group()

      for {amount, index} <- Enum.with_index([0, -100, "100", 1.5]) do
        conn =
          post_batch([
            record_cash_payment_op(%{
              "operation_id" => "op-pay-#{index}",
              "amount_cents" => amount
            })
          ])

        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_amount"}]} =
                 json_response(conn, 200)
      end
    end

    test "rejects a payment above the outstanding deposit" do
      open_group()
      conn = post_batch([record_cash_payment_op(%{"amount_cents" => 19_501})])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}]
             } = json_response(conn, 200)
    end

    test "outstanding deposit falls to zero as payments arrive" do
      open_group()
      post_batch([record_cash_payment_op(%{"amount_cents" => 10_000})])

      conn =
        post_batch([
          record_cash_payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 9_500})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 3}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "reschedule_group" do
    test "shifts arrival and departure by the same number of days" do
      open_group()
      conn = post_batch([reschedule_group_op(%{"new_arrival_on" => "2026-12-22"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-22",
                   "new_departure_on" => "2026-12-25",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "shifting backwards also shifts departure" do
      open_group()
      conn = post_batch([reschedule_group_op(%{"new_arrival_on" => "2026-12-01"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-01",
                   "new_departure_on" => "2026-12-04"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects a new arrival not after the operation date" do
      open_group()
      conn = post_batch([reschedule_group_op(%{"new_arrival_on" => "2026-10-05"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects an unparseable new arrival date" do
      open_group()
      conn = post_batch([reschedule_group_op(%{"new_arrival_on" => "soon"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects rescheduling a missing group" do
      conn = post_batch([reschedule_group_op(%{"group_id" => "group-missing"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)
    end
  end

  describe "cancel_group" do
    test "refunds cash when cancelled at least 14 days before arrival" do
      # booked 2026-10-03, arrival 2026-12-10; cancel 2026-11-20 -> 20 days before arrival
      open_group()
      post_batch([record_cash_payment_op(%{"amount_cents" => 10_000})])
      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-11-20"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 10_000,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)
    end

    test "retains cash when a flexible group is cancelled inside 14 days" do
      # arrival 2026-12-10; cancel 2026-12-01 -> 9 days before arrival
      open_group()
      post_batch([record_cash_payment_op(%{"amount_cents" => 10_000})])
      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-12-01"})])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 10_000
                 }
               ]
             } = json_response(conn, 200)
    end

    test "the 14 day boundary is refundable" do
      # arrival 2026-12-10; cancel 2026-11-26 -> exactly 14 days before arrival
      open_group()
      post_batch([record_cash_payment_op(%{"amount_cents" => 10_000})])
      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-11-26"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 10_000, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "advance_purchase is never refundable" do
      open_group(%{"rate_plan" => "advance_purchase"})
      post_batch([record_cash_payment_op(%{"amount_cents" => 50_000})])
      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-10-06"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 50_000}
               ]
             } = json_response(conn, 200)
    end

    test "unpaid deposit is simply no longer due" do
      open_group()
      conn = post_batch([cancel_group_op(%{"occurred_on" => "2026-12-01"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "cancelling a missing group is group_not_found" do
      conn = post_batch([cancel_group_op(%{"group_id" => "group-missing"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)
    end

    test "a cancelled group rejects further payments, moves, and cancellations" do
      open_group()
      post_batch([cancel_group_op()])

      ops = [
        record_cash_payment_op(%{"operation_id" => "op-after-cancel-1"}),
        reschedule_group_op(%{"operation_id" => "op-after-cancel-2"}),
        cancel_group_op(%{"operation_id" => "op-after-cancel-3"})
      ]

      for op <- ops do
        conn = post_batch([op])

        assert %{"results" => [%{"status" => "rejected", "code" => "group_not_active"}]} =
                 json_response(conn, 200)
      end
    end
  end

  describe "revisions and concurrency" do
    test "open_group ignores expected_revision" do
      conn = post_batch([open_group_op(%{"expected_revision" => 9})])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)
    end

    test "an applied operation with a matching expected_revision increments the revision" do
      open_group()

      conn =
        post_batch([
          record_cash_payment_op(%{"expected_revision" => 1, "amount_cents" => 5_000})
        ])

      assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
               json_response(conn, 200)
    end

    test "a stale revision is rejected before other domain validation" do
      open_group()
      post_batch([record_cash_payment_op(%{"amount_cents" => 5_000})])

      conn =
        post_batch([
          record_cash_payment_op(%{
            "operation_id" => "op-1002",
            "expected_revision" => 1,
            "amount_cents" => 1.5
          })
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1002",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "group existence is resolved before comparing revisions" do
      conn =
        post_batch([
          record_cash_payment_op(%{"group_id" => "group-missing", "expected_revision" => 3})
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "group_not_found"}]
             } = json_response(conn, 200)
    end

    test "rejected operations never increment the revision" do
      open_group()
      conn = post_batch([record_cash_payment_op(%{"amount_cents" => 99_999})])
      assert %{"results" => [%{"status" => "rejected"}]} = json_response(conn, 200)

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1}} = json_response(conn, 200)
    end

    test "earlier operations in the same batch are visible to later ones" do
      operations = [
        open_group_op(),
        record_cash_payment_op(%{"expected_revision" => 1, "amount_cents" => 8_000}),
        cancel_group_op(%{"expected_revision" => 2, "occurred_on" => "2026-11-20"})
      ]

      conn = post_batch(operations)

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{"status" => "applied", "revision" => 3, "refunded_cents" => 8_000}
               ]
             } = json_response(conn, 200)
    end

    test "omitting expected_revision preserves unconditional behavior" do
      open_group()
      conn = post_batch([reschedule_group_op()])

      assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
               json_response(conn, 200)
    end

    test "unknown operation types are rejected with invalid_operation" do
      conn =
        post_batch([
          %{
            "operation_id" => "op-x",
            "type" => "charge_card",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end

    test "operations missing operation_id are invalid" do
      conn = post_batch([open_group_op() |> Map.delete("operation_id")])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end
  end
end
