defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
  end

  defp submit_raw(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, body)
  end

  defp run(conn, operations) do
    submit(conn, operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp reschedule_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-15"
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp fetched_group(conn, group_id \\ "group-81") do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  describe "batch validation" do
    test "rejects a body without an operations array", %{conn: conn} do
      response = submit_raw(conn, Jason.encode!(%{}))
      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a body whose operations value is not an array", %{conn: conn} do
      response = submit_raw(conn, Jason.encode!(%{"operations" => %{"type" => "open_group"}}))
      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "accepts an empty operations array", %{conn: conn} do
      assert run(conn, []) == []
    end
  end

  describe "open_group" do
    test "opens the group from the API example", %{conn: conn} do
      assert [result] = run(conn, [open_op(%{"operation_id" => "op-1001"})])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      group = fetched_group(conn)
      assert group["group_id"] == "group-81"
      assert group["guest_id"] == "guest-22"
      assert group["property_id"] == "ams-canal"
      assert group["booked_on"] == "2026-10-03"
      assert group["arrival_on"] == "2026-12-10"
      assert group["departure_on"] == "2026-12-13"
      assert group["rate_plan"] == "flexible"
      assert group["status"] == "active"
      assert group["revision"] == 1
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500

      assert group["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ]
    end

    test "an advance purchase group requires its full lodging amount as deposit", %{conn: conn} do
      assert [_] = run(conn, [open_op(%{"rate_plan" => "advance_purchase"})])
      group = fetched_group(conn)
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 97_500
    end

    test "rounds each flexible room deposit separately before summing", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_002},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10_002}
      ]

      assert [result] =
               run(conn, [
                 open_op(%{
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11",
                   "rooms" => rooms
                 })
               ])

      # 20% of 10002 is 2000.4, which rounds down to 2000 per room.
      assert result["deposit_due_cents"] == 4_000
    end

    test "rounds fractional room deposits to the nearest cent", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10_003},
        %{"room_id" => "room-b", "nightly_rate_cents" => 10_004}
      ]

      assert [result] =
               run(conn, [
                 open_op(%{
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11",
                   "rooms" => rooms
                 })
               ])

      # 2000.6 rounds to 2001; 2000.8 rounds to 2001.
      assert result["deposit_due_cents"] == 4_002
    end

    test "rejects a group identifier that is already taken", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [open_op(%{"operation_id" => "op-dup"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_already_exists"
      assert result["operation_id"] == "op-dup"
      assert fetched_group(conn)["revision"] == 1
    end

    test "rejects a stay without at least one night", %{conn: conn} do
      for dates <- [
            %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"},
            %{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-10"}
          ] do
        assert [result] = run(conn, [open_op(Map.merge(dates, %{"group_id" => "group-stay"}))])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects unusable stay dates", %{conn: conn} do
      for dates <- [
            %{"arrival_on" => "not-a-date", "departure_on" => "2026-12-13"},
            %{"arrival_on" => "2026-12-10", "departure_on" => "2026-02-30"}
          ] do
        assert [result] = run(conn, [open_op(Map.merge(dates, %{"group_id" => "group-stay"}))])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects rooms that are not usable", %{conn: conn} do
      for rooms <- [
            [],
            [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
            ],
            [%{"room_id" => "room-a"}],
            [%{"nightly_rate_cents" => 15_000}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
            [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}],
            ["room-a"]
          ] do
        assert [result] = run(conn, [open_op(%{"group_id" => "group-rooms", "rooms" => rooms})])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms"
      end
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      assert [result] = run(conn, [open_op(%{"rate_plan" => "standard"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rate_plan"
    end

    test "rejects a duplicate open without creating another group", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [open_op(%{"arrival_on" => "2026-12-11"})])
      assert result["code"] == "group_already_exists"
      assert fetched_group(conn)["arrival_on"] == "2026-12-10"
    end

    test "ignores expected_revision", %{conn: conn} do
      assert [result] = run(conn, [open_op(%{"expected_revision" => 99})])
      assert result["status"] == "applied"
      assert result["revision"] == 1
    end
  end

  describe "invalid operations" do
    test "rejects unknown operation types", %{conn: conn} do
      assert [result] = run(conn, [open_op(%{"type" => "extend_group"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end

    test "rejects operations that cannot be identified", %{conn: conn} do
      for overrides <- [
            %{"operation_id" => nil},
            %{"type" => nil},
            %{"group_id" => nil},
            %{"occurred_on" => nil}
          ] do
        assert [result] = run(conn, [open_op(overrides)])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end

    test "rejects operations missing data needed to apply them", %{conn: conn} do
      for overrides <- [
            %{"guest_id" => nil},
            %{"property_id" => nil},
            %{"arrival_on" => nil},
            %{"departure_on" => nil},
            %{"rate_plan" => nil},
            %{"rooms" => nil}
          ] do
        assert [result] = run(conn, [open_op(overrides)])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert [result] = run(conn, [payment_op(%{"amount_cents" => nil})])
      assert result["code"] == "invalid_operation"

      assert [result] = run(conn, [reschedule_op(%{"new_arrival_on" => nil})])
      assert result["code"] == "invalid_operation"
    end

    test "rejects entries that are not operation objects", %{conn: conn} do
      assert [result] = run(conn, ["open_group"])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
      assert result["operation_id"] == nil
    end

    test "invalid operations leave the database unchanged", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [payment_op(%{"amount_cents" => nil})])
      assert result["code"] == "invalid_operation"
      assert fetched_group(conn)["revision"] == 1
      assert fetched_group(conn)["deposit_paid_cents"] == 0
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [result] = run(conn, [payment_op(%{"operation_id" => "op-pay-1"})])

      assert result == %{
               "operation_id" => "op-pay-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 5_000
      assert group["outstanding_deposit_cents"] == 14_500
      assert group["revision"] == 2

      assert [second] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 14_500})])

      assert second["status"] == "applied"
      assert second["outstanding_deposit_cents"] == 0
      assert second["revision"] == 3
    end

    test "rejects a payment for a missing group", %{conn: conn} do
      assert [result] = run(conn, [payment_op(%{"group_id" => "group-missing"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "rejects a payment for a cancelled group", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), cancel_op()])
      assert [result] = run(conn, [payment_op()])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "rejects amounts that are not usable as a payment", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      for amount <- [0, -500, 10.5, "5000", true] do
        assert [result] = run(conn, [payment_op(%{"amount_cents" => amount})])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end

      assert fetched_group(conn)["deposit_paid_cents"] == 0
      assert fetched_group(conn)["revision"] == 1
    end

    test "rejects a payment exceeding the outstanding deposit", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [payment_op(%{"amount_cents" => 19_501})])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
      assert fetched_group(conn)["deposit_paid_cents"] == 0
    end
  end

  describe "reschedule_group" do
    test "shifts arrival and departure by the same number of days", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [result] =
               run(conn, [
                 reschedule_op(%{"operation_id" => "op-move-1", "new_arrival_on" => "2026-12-15"})
               ])

      assert result == %{
               "operation_id" => "op-move-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-15",
               "new_departure_on" => "2026-12-18",
               "revision" => 2
             }

      group = fetched_group(conn)
      assert group["arrival_on"] == "2026-12-15"
      assert group["departure_on"] == "2026-12-18"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "accepts a reschedule that keeps the same dates", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [result] = run(conn, [reschedule_op(%{"new_arrival_on" => "2026-12-10"})])
      assert result["status"] == "applied"
      assert result["new_departure_on"] == "2026-12-13"
      assert result["revision"] == 2
    end

    test "rejects a new arrival that is not after the operation date", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      for new_arrival <- ["2026-10-04", "2026-10-01"] do
        assert [result] = run(conn, [reschedule_op(%{"new_arrival_on" => new_arrival})])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end

      assert fetched_group(conn)["arrival_on"] == "2026-12-10"
      assert fetched_group(conn)["revision"] == 1
    end

    test "rejects an unusable new arrival date", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [reschedule_op(%{"new_arrival_on" => "soon"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_stay"
    end

    test "rejects rescheduling a missing group", %{conn: conn} do
      assert [result] = run(conn, [reschedule_op(%{"group_id" => "group-missing"})])
      assert result["code"] == "group_not_found"
    end

    test "rejects rescheduling a cancelled group", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), cancel_op()])
      assert [result] = run(conn, [reschedule_op()])
      assert result["code"] == "group_not_active"
    end
  end

  describe "cancel_group" do
    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      assert [_, paid] = run(conn, [open_op(), payment_op()])
      assert paid["status"] == "applied"

      # Cancellation on 2026-11-26 is exactly 14 days before arrival on 2026-12-10.
      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 5_000,
               "retained_cents" => 0,
               "revision" => 3
             }

      group = fetched_group(conn)
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
    end

    test "retains cash for a flexible group cancelled less than 14 days before arrival", %{
      conn: conn
    } do
      assert [_, _] = run(conn, [open_op(), payment_op()])
      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-27"})])
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5_000

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000
             }
    end

    test "retains cash for an advance purchase group regardless of timing", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(%{"rate_plan" => "advance_purchase"}), payment_op()])
      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2026-10-04"})])
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5_000
    end

    test "cancelling without payments settles nothing", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [cancel_op()])
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "unpaid deposit is no longer due after cancellation", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [cancel_op()])

      group = fetched_group(conn)
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
    end

    test "rejects further operations on a cancelled group", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), cancel_op()])

      assert [result] = run(conn, [payment_op()])
      assert result["code"] == "group_not_active"

      assert [result] = run(conn, [reschedule_op()])
      assert result["code"] == "group_not_active"

      assert [result] = run(conn, [cancel_op()])
      assert result["code"] == "group_not_active"

      assert fetched_group(conn)["revision"] == 2
    end

    test "rejects cancelling a missing group", %{conn: conn} do
      assert [result] = run(conn, [cancel_op(%{"group_id" => "group-missing"})])
      assert result["code"] == "group_not_found"
    end
  end

  describe "expected_revision" do
    test "applies when it matches the current revision", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [payment_op(%{"expected_revision" => 1})])
      assert result["status"] == "applied"
      assert result["revision"] == 2
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      # The amount also exceeds the outstanding deposit, but the stale
      # revision must win.
      assert [result] =
               run(conn, [
                 payment_op(%{"expected_revision" => 5, "amount_cents" => 999_999})
               ])

      assert result == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }

      group = fetched_group(conn)
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "rejects a stale revision for every later operation type", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [result] = run(conn, [reschedule_op(%{"expected_revision" => 2})])
      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1

      assert [result] = run(conn, [cancel_op(%{"expected_revision" => 2})])
      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 1

      assert fetched_group(conn)["revision"] == 1
      assert fetched_group(conn)["status"] == "active"
    end

    test "rejects a stale revision before checking whether the group is active", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), cancel_op()])

      assert [result] = run(conn, [cancel_op(%{"expected_revision" => 1})])
      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2
    end

    test "resolves group existence before comparing revisions", %{conn: conn} do
      assert [result] =
               run(conn, [payment_op(%{"group_id" => "group-missing", "expected_revision" => 1})])

      assert result["code"] == "group_not_found"
    end

    test "sees revisions updated earlier in the same batch", %{conn: conn} do
      assert [_, applied, stale] =
               run(conn, [
                 open_op(),
                 payment_op(%{"operation_id" => "op-pay-1", "expected_revision" => 1}),
                 payment_op(%{"operation_id" => "op-pay-2", "expected_revision" => 1})
               ])

      assert applied["status"] == "applied"
      assert applied["revision"] == 2
      assert stale["status"] == "rejected"
      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
    end

    test "omitting expected_revision keeps the unconditional behavior", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [payment_op()])
      assert result["status"] == "applied"
    end
  end

  describe "batch processing" do
    test "processes operations in order and returns one result per operation", %{conn: conn} do
      results =
        run(conn, [
          open_op(%{"operation_id" => "op-1"}),
          payment_op(%{"operation_id" => "op-2"}),
          reschedule_op(%{"operation_id" => "op-3"}),
          cancel_op(%{"operation_id" => "op-4"})
        ])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-2", "op-3", "op-4"]
      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied)
      assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    end

    test "later operations observe earlier operations in the same batch", %{conn: conn} do
      assert [opened, paid, cancelled] =
               run(conn, [
                 open_op(),
                 payment_op(%{"amount_cents" => 19_500}),
                 cancel_op(%{"occurred_on" => "2026-11-26"})
               ])

      assert opened["status"] == "applied"
      assert paid["outstanding_deposit_cents"] == 0
      assert cancelled["refunded_cents"] == 19_500

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 19_500,
               "cash_retained_cents" => 0
             }
    end

    test "a rejected operation does not stop later operations", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [rejected, applied] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-bad", "amount_cents" => 0}),
                 payment_op(%{"operation_id" => "op-good", "amount_cents" => 1_000})
               ])

      assert rejected["status"] == "rejected"
      assert applied["status"] == "applied"
      assert applied["revision"] == 2
    end

    test "a rejected operation does not undo earlier successful operations", %{conn: conn} do
      assert [applied, rejected] =
               run(conn, [
                 open_op(),
                 open_op(%{"operation_id" => "op-dup"})
               ])

      assert applied["status"] == "applied"
      assert rejected["status"] == "rejected"
      assert fetched_group(conn)["revision"] == 1
    end

    test "rejections never increment the revision", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      for op <- [
            payment_op(%{"amount_cents" => 999_999}),
            reschedule_op(%{"new_arrival_on" => "2026-10-01"}),
            cancel_op(%{"expected_revision" => 99})
          ] do
        assert [result] = run(conn, [op])
        assert result["status"] == "rejected"
      end

      assert fetched_group(conn)["revision"] == 1
    end
  end
end
