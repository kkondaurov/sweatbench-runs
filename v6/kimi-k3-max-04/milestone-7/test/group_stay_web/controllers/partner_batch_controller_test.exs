defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  # Helpers -----------------------------------------------------------------

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "record_cash_payment",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reschedule_op(group_id, new_arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-20",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival_on
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-10-20",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp next_id do
    "op-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp uniq(suffix), do: "group-#{suffix}-#{System.unique_integer([:positive])}"

  # Batch envelope ------------------------------------------------------------

  describe "batch envelope" do
    test "a body without an operations array is an invalid batch", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{"not_operations" => []})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "a non-array operations value is an invalid batch", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "an empty operations array returns no results", %{conn: conn} do
      assert submit(conn, []) == %{"results" => []}
    end

    test "an unknown operation type is rejected and later operations continue", %{conn: conn} do
      group_id = uniq("unknown")

      results =
        submit(conn, [
          %{"operation_id" => "op-bad", "type" => "explode"},
          open_op(group_id)
        ])["results"]

      assert [
               %{
                 "operation_id" => "op-bad",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"status" => "applied"}
             ] = results
    end

    test "operations missing a type are rejected with invalid_operation", %{conn: conn} do
      group_id = uniq("typeless")

      results =
        submit(conn, [
          %{"operation_id" => "op-typeless", "group_id" => group_id},
          open_op(group_id)
        ])["results"]

      assert [%{"status" => "rejected", "code" => "invalid_operation"}, %{"status" => "applied"}] =
               results
    end

    test "non-map operations are rejected with invalid_operation", %{conn: conn} do
      group_id = uniq("nonmap")

      results = submit(conn, ["not-an-operation", open_op(group_id)])["results"]

      assert [%{"status" => "rejected", "code" => "invalid_operation"}, %{"status" => "applied"}] =
               results
    end
  end

  # open_group ----------------------------------------------------------------

  describe "open_group" do
    test "applies and computes lodging total and deposit due", %{conn: conn} do
      group_id = uniq("open")

      assert %{
               "operation_id" => _,
               "status" => "applied",
               "group_id" => ^group_id,
               "deposit_due_cents" => 19_500,
               "revision" => 1
             } =
               hd(submit(conn, [open_op(group_id)])["results"])
    end

    test "rejects a duplicate group id", %{conn: conn} do
      group_id = uniq("dup")
      submit(conn, [open_op(group_id)])

      results = submit(conn, [open_op(group_id)])["results"]

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_already_exists",
                 "group_id" => ^group_id
               }
             ] =
               results
    end

    test "rejects a stay with fewer than one night", %{conn: conn} do
      group_id = uniq("stay")

      results =
        submit(conn, [
          open_op(group_id, %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"})
        ])["results"]

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
    end

    test "rejects stay dates that do not parse with invalid_stay", %{conn: conn} do
      group_id = uniq("stay-parse")

      results =
        submit(conn, [open_op(group_id, %{"arrival_on" => "October 3"})])["results"]

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
    end

    test "rejects a group with no rooms", %{conn: conn} do
      group_id = uniq("rooms-empty")
      results = submit(conn, [open_op(group_id, %{"rooms" => []})])["results"]
      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] = results
    end

    test "rejects duplicate room identifiers", %{conn: conn} do
      group_id = uniq("rooms-dup")

      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
      ]

      results = submit(conn, [open_op(group_id, %{"rooms" => rooms})])["results"]
      assert [%{"status" => "rejected", "code" => "invalid_rooms"}] = results
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      group_id = uniq("plan")
      results = submit(conn, [open_op(group_id, %{"rate_plan" => "mystery"})])["results"]
      assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] = results
    end

    test "rejects operations missing data needed to apply them", %{conn: conn} do
      group_id = uniq("missing")

      op =
        open_op(group_id)
        |> Map.delete("arrival_on")

      results = submit(conn, [op])["results"]
      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results
    end

    test "advance_purchase requires the full lodging amount as deposit", %{conn: conn} do
      group_id = uniq("ap")
      results = submit(conn, [open_op(group_id, %{"rate_plan" => "advance_purchase"})])["results"]

      assert [%{"status" => "applied", "deposit_due_cents" => 97_500}] = results
    end

    test "flexible deposits are rounded per room and summed", %{conn: conn} do
      group_id = uniq("rounding")

      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 1234},
        %{"room_id" => "room-b", "nightly_rate_cents" => 999}
      ]

      results = submit(conn, [open_op(group_id, %{"rooms" => rooms})])["results"]

      # 3 nights (2026-12-10 -> 2026-12-13):
      # room-a: 3 * 1234 = 3702 cents, 20% = 740.4 -> 740
      # room-b: 3 * 999  = 2997 cents, 20% = 599.4 -> 599
      # The group deposit is the sum of the per-room rounded deposits.
      assert [%{"status" => "applied", "deposit_due_cents" => 1339}] = results
    end
  end

  # record_cash_payment --------------------------------------------------------

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit and increments revision", %{conn: conn} do
      group_id = uniq("pay")

      results =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 10_000),
          payment_op(group_id, 9_500)
        ])["results"]

      assert [_, %{"status" => "applied", "revision" => 2}, _] = results

      assert %{
               "status" => "applied",
               "group_id" => ^group_id,
               "amount_cents" => 9_500,
               "outstanding_deposit_cents" => 0,
               "revision" => 3
             } = Enum.at(results, 2)
    end

    test "rejects a payment for a missing group", %{conn: conn} do
      results = submit(conn, [payment_op("group-nope", 100)])["results"]
      assert [%{"status" => "rejected", "code" => "group_not_found"}] = results
    end

    test "rejects payments on a cancelled group", %{conn: conn} do
      group_id = uniq("pay-cancel")

      submit(conn, [
        open_op(group_id),
        payment_op(group_id, 100),
        cancel_op(group_id)
      ])

      results = submit(conn, [payment_op(group_id, 100)])["results"]
      assert [%{"status" => "rejected", "code" => "group_not_active"}] = results
    end

    test "rejects unusable amounts", %{conn: conn} do
      group_id = uniq("amount")
      submit(conn, [open_op(group_id)])

      for bad_amount <- [0, -100, "100", 10.5] do
        results = submit(conn, [payment_op(group_id, bad_amount)])["results"]
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] = results
      end
    end

    test "rejects a payment exceeding the outstanding deposit", %{conn: conn} do
      group_id = uniq("exceeds")
      submit(conn, [open_op(group_id)])

      results = submit(conn, [payment_op(group_id, 19_501)])["results"]
      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] = results
    end
  end

  # reschedule_group -----------------------------------------------------------

  describe "reschedule_group" do
    test "shifts the stay without changing its length", %{conn: conn} do
      group_id = uniq("resched")

      results =
        submit(conn, [
          open_op(group_id),
          reschedule_op(group_id, "2027-01-05")
        ])["results"]

      assert [
               _,
               %{
                 "status" => "applied",
                 "group_id" => ^group_id,
                 "new_arrival_on" => "2027-01-05",
                 "new_departure_on" => "2027-01-08",
                 "revision" => 2
               }
             ] = results
    end

    test "rejects a missing group", %{conn: conn} do
      results = submit(conn, [reschedule_op("group-nope", "2027-01-05")])["results"]
      assert [%{"status" => "rejected", "code" => "group_not_found"}] = results
    end

    test "rejects an arrival that is not after the operation date", %{conn: conn} do
      group_id = uniq("resched-bad")
      submit(conn, [open_op(group_id)])

      results =
        submit(conn, [reschedule_op(group_id, "2026-10-20", %{"occurred_on" => "2026-10-20"})])[
          "results"
        ]

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] = results
    end

    test "rejects rescheduling an inactive group", %{conn: conn} do
      group_id = uniq("resched-cancel")
      submit(conn, [open_op(group_id), cancel_op(group_id)])

      results = submit(conn, [reschedule_op(group_id, "2027-01-05")])["results"]
      assert [%{"status" => "rejected", "code" => "group_not_active"}] = results
    end
  end

  # cancel_group ---------------------------------------------------------------

  describe "cancel_group" do
    test "refunds cash for flexible groups cancelled at least 14 days before arrival", %{
      conn: conn
    } do
      group_id = uniq("cancel-refund")

      results =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 12_000),
          cancel_op(group_id, %{"occurred_on" => "2026-11-26"})
        ])["results"]

      assert [
               _,
               _,
               %{
                 "status" => "applied",
                 "group_id" => ^group_id,
                 "refunded_cents" => 12_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = results
    end

    test "retains cash for flexible groups cancelled inside 14 days", %{conn: conn} do
      group_id = uniq("cancel-retain")

      results =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 12_000),
          cancel_op(group_id, %{"occurred_on" => "2026-11-27"})
        ])["results"]

      assert [_, _, %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 12_000}] =
               results
    end

    test "advance_purchase groups are always non-refundable", %{conn: conn} do
      group_id = uniq("cancel-ap")

      results =
        submit(conn, [
          open_op(group_id, %{"rate_plan" => "advance_purchase"}),
          payment_op(group_id, 20_000),
          cancel_op(group_id, %{"occurred_on" => "2026-10-01"})
        ])["results"]

      assert [_, _, %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 20_000}] =
               results
    end

    test "rejecting cancellation of a missing group", %{conn: conn} do
      results = submit(conn, [cancel_op("group-nope")])["results"]
      assert [%{"status" => "rejected", "code" => "group_not_found"}] = results
    end

    test "a later payment, reschedule, or cancellation is rejected after cancel", %{conn: conn} do
      group_id = uniq("cancel-twice")
      submit(conn, [open_op(group_id), cancel_op(group_id)])

      results =
        submit(conn, [
          cancel_op(group_id),
          payment_op(group_id, 100),
          reschedule_op(group_id, "2027-01-05")
        ])["results"]

      assert [
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"},
               %{"status" => "rejected", "code" => "group_not_active"}
             ] = results
    end
  end

  # Revisions ------------------------------------------------------------------

  describe "expected_revision" do
    test "applies when the expected revision matches", %{conn: conn} do
      group_id = uniq("rev-ok")

      results =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 5_000, %{"expected_revision" => 1}),
          reschedule_op(group_id, "2027-01-05", %{"expected_revision" => 2})
        ])["results"]

      assert [
               _,
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3}
             ] = results
    end

    test "rejects a stale revision and leaves the group unchanged", %{conn: conn} do
      group_id = uniq("rev-stale")
      submit(conn, [open_op(group_id), payment_op(group_id, 5_000)])

      results =
        submit(conn, [payment_op(group_id, 1_000, %{"expected_revision" => 1})])["results"]

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => ^group_id,
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = results

      # The group and the ledger are unchanged by the rejected operation.
      group =
        conn
        |> get(~p"/api/v1/groups/#{group_id}")
        |> json_response(200)

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} = group

      ledger =
        conn
        |> get(~p"/api/v1/ledger")
        |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 5_000}} = ledger
    end

    test "group existence is resolved before comparing revisions", %{conn: conn} do
      results =
        submit(conn, [payment_op("group-nope", 1_000, %{"expected_revision" => 1})])["results"]

      assert [%{"status" => "rejected", "code" => "group_not_found"}] = results
    end

    test "a stale revision is rejected before other domain rules", %{conn: conn} do
      group_id = uniq("rev-before-domain")
      submit(conn, [open_op(group_id), cancel_op(group_id)])

      # Group is cancelled; with a stale revision the rejection must be
      # stale_revision, not group_not_active.
      results =
        submit(conn, [payment_op(group_id, 100, %{"expected_revision" => 1})])["results"]

      assert [%{"status" => "rejected", "code" => "stale_revision"}] = results
    end

    test "open_group ignores expected_revision", %{conn: conn} do
      group_id = uniq("open-ignores")

      results =
        submit(conn, [open_op(group_id, %{"expected_revision" => 99})])["results"]

      assert [%{"status" => "applied", "revision" => 1}] = results
    end
  end

  describe "batch ordering and isolation" do
    test "a later operation can observe an earlier operation in the same batch", %{conn: conn} do
      group_id = uniq("same-batch")

      results = submit(conn, [open_op(group_id), payment_op(group_id, 19_500)])["results"]

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 0}
             ] = results
    end

    test "a rejected operation does not undo earlier successful operations", %{conn: conn} do
      group_id = uniq("isolation")

      results =
        submit(conn, [
          open_op(group_id),
          payment_op(group_id, 19_501),
          payment_op(group_id, 10_000)
        ])["results"]

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "revision" => 2}
             ] = results
    end
  end
end
