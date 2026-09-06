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

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp guest_credit(conn, guest_id \\ "guest-22") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp issue_credit(conn, cancel_op_id, group_id, cash_cents, occurred_on \\ "2026-10-04") do
    run(conn, [
      open_op(%{"operation_id" => cancel_op_id <> "-open", "group_id" => group_id}),
      payment_op(%{
        "operation_id" => cancel_op_id <> "-pay",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      cancel_op(%{
        "operation_id" => cancel_op_id,
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ])
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
      for {dates, i} <-
            Enum.with_index([
              %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"},
              %{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-10"}
            ]) do
        assert [result] =
                 run(conn, [
                   open_op(
                     Map.merge(dates, %{
                       "group_id" => "group-stay",
                       "operation_id" => "op-nights-#{i}"
                     })
                   )
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects unusable stay dates", %{conn: conn} do
      for {dates, i} <-
            Enum.with_index([
              %{"arrival_on" => "not-a-date", "departure_on" => "2026-12-13"},
              %{"arrival_on" => "2026-12-10", "departure_on" => "2026-02-30"}
            ]) do
        assert [result] =
                 run(conn, [
                   open_op(
                     Map.merge(dates, %{
                       "group_id" => "group-stay",
                       "operation_id" => "op-dates-#{i}"
                     })
                   )
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_stay"
      end
    end

    test "rejects rooms that are not usable", %{conn: conn} do
      for {rooms, i} <-
            Enum.with_index([
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
            ]) do
        assert [result] =
                 run(conn, [
                   open_op(%{
                     "group_id" => "group-rooms",
                     "rooms" => rooms,
                     "operation_id" => "op-rooms-#{i}"
                   })
                 ])

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

      assert [result] =
               run(conn, [open_op(%{"operation_id" => "op-dup", "arrival_on" => "2026-12-11"})])

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
      for {overrides, i} <-
            Enum.with_index([
              %{"operation_id" => nil},
              %{"type" => nil},
              %{"group_id" => nil},
              %{"occurred_on" => nil}
            ]) do
        overrides = Map.put_new(overrides, "operation_id", "op-unidentified-#{i}")
        assert [result] = run(conn, [open_op(overrides)])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end
    end

    test "rejects operations missing data needed to apply them", %{conn: conn} do
      for {overrides, i} <-
            Enum.with_index([
              %{"guest_id" => nil},
              %{"property_id" => nil},
              %{"arrival_on" => nil},
              %{"departure_on" => nil},
              %{"rate_plan" => nil},
              %{"rooms" => nil}
            ]) do
        assert [result] =
                 run(conn, [open_op(Map.put(overrides, "operation_id", "op-incomplete-#{i}"))])

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

      for {amount, i} <- Enum.with_index([0, -500, 10.5, "5000", true]) do
        assert [result] =
                 run(conn, [
                   payment_op(%{"amount_cents" => amount, "operation_id" => "op-amount-#{i}"})
                 ])

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
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-01",
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

      for {new_arrival, i} <- Enum.with_index(["2026-10-04", "2026-10-01"]) do
        assert [result] =
                 run(conn, [
                   reschedule_op(%{
                     "new_arrival_on" => new_arrival,
                     "operation_id" => "op-move-past-#{i}"
                   })
                 ])

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
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = fetched_group(conn)
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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
               "cash_retained_cents" => 5_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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

      assert [result] = run(conn, [cancel_op(%{"operation_id" => "op-cancel-again"})])
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

      assert [result] =
               run(conn, [
                 cancel_op(%{"operation_id" => "op-cancel-stale", "expected_revision" => 1})
               ])

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
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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

  describe "policy versions" do
    test "a flexible group booked before the cutoff keeps the 14-day window", %{conn: conn} do
      assert [_] = run(conn, [open_op(%{"occurred_on" => "2026-12-31"})])

      group = fetched_group(conn)
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2026-11-26"
    end

    test "a flexible group booked on the cutoff uses the 30-day window", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{
                   "occurred_on" => "2027-01-01",
                   "arrival_on" => "2027-03-15",
                   "departure_on" => "2027-03-18"
                 })
               ])

      group = fetched_group(conn)
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-02-13"
    end

    test "a flex-30 group is refundable through its refundable_until date", %{conn: conn} do
      open_30 = fn group_id ->
        open_op(%{
          "operation_id" => "op-open-#{group_id}",
          "group_id" => group_id,
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        })
      end

      assert [_, _, on_boundary] =
               run(conn, [
                 open_30.("group-a"),
                 payment_op(%{"group_id" => "group-a", "operation_id" => "op-pay-a"}),
                 cancel_op(%{
                   "group_id" => "group-a",
                   "occurred_on" => "2027-02-13",
                   "operation_id" => "op-cancel-a"
                 })
               ])

      assert on_boundary["status"] == "applied"
      assert on_boundary["refunded_cents"] == 5_000
      assert on_boundary["retained_cents"] == 0

      assert [_, _, past_boundary] =
               run(conn, [
                 open_30.("group-b"),
                 payment_op(%{"group_id" => "group-b", "operation_id" => "op-pay-b"}),
                 cancel_op(%{
                   "group_id" => "group-b",
                   "occurred_on" => "2027-02-14",
                   "operation_id" => "op-cancel-b"
                 })
               ])

      assert past_boundary["status"] == "applied"
      assert past_boundary["refunded_cents"] == 0
      assert past_boundary["retained_cents"] == 5_000
    end

    test "an advance purchase group is never refundable", %{conn: conn} do
      assert [_] = run(conn, [open_op(%{"rate_plan" => "advance_purchase"})])

      group = fetched_group(conn)
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      assert [_] = run(conn, [open_op(%{"occurred_on" => "2026-12-31"})])

      assert [result] =
               run(conn, [
                 reschedule_op(%{
                   "occurred_on" => "2027-01-05",
                   "new_arrival_on" => "2027-06-01"
                 })
               ])

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-05-18"

      group = fetched_group(conn)
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-05-18"
    end

    test "reschedule results report the recomputed refundable_until", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{
                   "occurred_on" => "2027-02-01",
                   "arrival_on" => "2027-04-10",
                   "departure_on" => "2027-04-12"
                 })
               ])

      assert [result] =
               run(conn, [
                 reschedule_op(%{"occurred_on" => "2027-02-02", "new_arrival_on" => "2027-04-20"})
               ])

      assert result["policy_version"] == "flex-30"
      assert result["refundable_until"] == "2027-03-21"
    end

    test "advance purchase reschedule results carry a null refundable_until", %{conn: conn} do
      assert [_] = run(conn, [open_op(%{"rate_plan" => "advance_purchase"})])

      assert [result] = run(conn, [reschedule_op()])
      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  describe "cancel_group refund methods" do
    test "hotel credit converts a refundable cash payment into a 110% lot", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), payment_op()])

      assert [result] =
               run(conn, [
                 cancel_op(%{"occurred_on" => "2026-10-20", "refund_method" => "hotel_credit"})
               ])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5_500,
               "revision" => 3
             }

      assert guest_credit(conn) == %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-10-21"
                 }
               ]
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "credit_liability_cents" => 5_500
             }
    end

    test "rounds the 10% bonus to the nearest cent, half up", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), payment_op(%{"amount_cents" => 1_005})])

      assert [result] =
               run(conn, [
                 cancel_op(%{"occurred_on" => "2026-10-20", "refund_method" => "hotel_credit"})
               ])

      # 10% of 1005 is 100.5, which rounds up to 101.
      assert result["credit_issued_cents"] == 1_106
      assert ledger(conn)["cash_converted_to_credit_cents"] == 1_005
      assert guest_credit(conn)["available_cents"] == 1_106
    end

    test "the lot expires the day after its 365 available days", %{conn: conn} do
      assert [_, _, _] =
               run(conn, [
                 open_op(),
                 payment_op(),
                 cancel_op(%{"occurred_on" => "2026-10-20", "refund_method" => "hotel_credit"})
               ])

      last_day = get(conn, "/api/v1/guests/guest-22/credit?on=2027-10-20")
      assert hd(json_response(last_day, 200)["data"]["lots"])["remaining_cents"] == 5_500

      expired = get(conn, "/api/v1/guests/guest-22/credit?on=2027-10-21")
      assert json_response(expired, 200)["data"]["lots"] == []

      ledger_last = get(conn, "/api/v1/ledger?on=2027-10-20")
      assert json_response(ledger_last, 200)["data"]["credit_liability_cents"] == 5_500

      ledger_expired = get(conn, "/api/v1/ledger?on=2027-10-21")
      assert json_response(ledger_expired, 200)["data"]["credit_liability_cents"] == 0
    end

    test "an explicit cash refund keeps the earlier behavior", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), payment_op()])

      assert [result] =
               run(conn, [
                 cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "cash"})
               ])

      assert result["refunded_cents"] == 5_000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert guest_credit(conn)["available_cents"] == 0
    end

    test "hotel credit is not available for a non-refundable cancellation", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), payment_op()])

      assert [result] =
               run(conn, [
                 cancel_op(%{"occurred_on" => "2026-12-01", "refund_method" => "hotel_credit"})
               ])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = fetched_group(conn)
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert guest_credit(conn)["available_cents"] == 0

      assert ledger(conn) == %{
               "cash_held_cents" => 5_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "hotel credit is not available for an advance purchase cancellation", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(%{"rate_plan" => "advance_purchase"}), payment_op()])

      assert [result] = run(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])
      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"
      assert fetched_group(conn)["status"] == "active"
    end

    test "rejects an unknown refund method without changing the group", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), payment_op()])

      assert [result] = run(conn, [cancel_op(%{"refund_method" => "voucher"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
      assert fetched_group(conn)["status"] == "active"
      assert fetched_group(conn)["revision"] == 2
    end

    test "checks the revision before the refund method", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), payment_op()])

      assert [result] =
               run(conn, [
                 cancel_op(%{
                   "occurred_on" => "2026-12-01",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 1
                 })
               ])

      assert result["code"] == "stale_revision"
      assert fetched_group(conn)["status"] == "active"
    end

    test "converting a deposit paid only with credit issues no lot", %{conn: conn} do
      assert [_, _, _, _] =
               run(conn, [
                 open_op(%{"group_id" => "group-fund", "operation_id" => "op-open-fund"}),
                 payment_op(%{"group_id" => "group-fund", "operation_id" => "op-pay-fund"}),
                 cancel_op(%{
                   "group_id" => "group-fund",
                   "occurred_on" => "2026-10-20",
                   "refund_method" => "hotel_credit",
                   "operation_id" => "op-cancel-fund"
                 }),
                 open_op()
               ])

      assert [_] = run(conn, [credit_op(%{"amount_cents" => 5_500})])

      assert [result] =
               run(conn, [
                 cancel_op(%{
                   "occurred_on" => "2026-11-26",
                   "refund_method" => "hotel_credit",
                   "operation_id" => "op-cancel-settle"
                 })
               ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 5_500
      assert ledger(conn)["cash_converted_to_credit_cents"] == 5_000
    end
  end

  describe "apply_hotel_credit" do
    test "redeems available credit into the outstanding deposit", %{conn: conn} do
      assert [_, _, _] =
               run(conn, [
                 open_op(%{"group_id" => "group-fund", "operation_id" => "op-open-fund"}),
                 payment_op(%{
                   "group_id" => "group-fund",
                   "amount_cents" => 2_000,
                   "operation_id" => "op-pay-fund"
                 }),
                 cancel_op(%{
                   "group_id" => "group-fund",
                   "occurred_on" => "2026-10-20",
                   "refund_method" => "hotel_credit",
                   "operation_id" => "op-cancel-fund"
                 })
               ])

      assert [_] = run(conn, [open_op()])

      assert [result] = run(conn, [credit_op(%{"operation_id" => "op-credit-1"})])

      assert result == %{
               "operation_id" => "op-credit-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 18_500,
               "revision" => 2
             }

      group = fetched_group(conn)
      assert group["deposit_paid_cents"] == 1_000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 1_000
      assert group["outstanding_deposit_cents"] == 18_500

      credit = guest_credit(conn)
      assert credit["available_cents"] == 1_200
      assert hd(credit["lots"])["remaining_cents"] == 1_200

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 2_200
    end

    test "consumes lots by earliest expiry and then source operation", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-late", "group-late", 1_000, "2026-10-25")
      assert [_, _, _] = issue_credit(conn, "op-cancel-early", "group-early", 1_000, "2026-10-20")

      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [credit_op(%{"amount_cents" => 1_500})])
      assert result["status"] == "applied"

      assert guest_credit(conn)["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-late",
                 "remaining_cents" => 700,
                 "expires_on" => "2027-10-26"
               }
             ]
    end

    test "breaks expiry ties by source operation identifier", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-b", "group-b", 1_000)
      assert [_, _, _] = issue_credit(conn, "op-cancel-a", "group-a", 1_000)

      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [credit_op(%{"amount_cents" => 1_100})])
      assert result["status"] == "applied"

      assert guest_credit(conn)["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-b",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2027-10-05"
               }
             ]
    end

    test "does not spend lots that have expired by the operation date", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-old", "group-old", 1_000, "2026-10-20")
      assert [_] = run(conn, [open_op()])

      assert [result] =
               run(conn, [
                 credit_op(%{
                   "occurred_on" => "2027-10-21",
                   "amount_cents" => 100,
                   "operation_id" => "op-credit-late"
                 })
               ])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"

      assert [result] =
               run(conn, [
                 credit_op(%{
                   "occurred_on" => "2027-10-20",
                   "amount_cents" => 100,
                   "operation_id" => "op-credit-intime"
                 })
               ])

      assert result["status"] == "applied"
    end

    test "rejects a credit payment for a missing group", %{conn: conn} do
      assert [result] = run(conn, [credit_op(%{"group_id" => "group-missing"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "rejects a credit payment for a cancelled group", %{conn: conn} do
      assert [_, _] = run(conn, [open_op(), cancel_op()])
      assert [result] = run(conn, [credit_op()])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"
    end

    test "rejects amounts that are not usable as a payment", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 1_000)
      assert [_] = run(conn, [open_op()])

      for {amount, i} <- Enum.with_index([0, -500, 10.5, "1000", true]) do
        assert [result] =
                 run(conn, [
                   credit_op(%{"amount_cents" => amount, "operation_id" => "op-credit-bad-#{i}"})
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end

      assert fetched_group(conn)["deposit_paid_cents"] == 0
      assert fetched_group(conn)["revision"] == 1
    end

    test "rejects credit that exceeds the outstanding deposit", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 19_500)
      assert [_] = run(conn, [open_op()])

      assert [result] = run(conn, [credit_op(%{"amount_cents" => 19_501})])
      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"
      assert fetched_group(conn)["deposit_paid_cents"] == 0
    end

    test "rejects a credit payment the guest cannot cover", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 1_000)
      assert [_] = run(conn, [open_op()])

      assert [result] = run(conn, [credit_op(%{"amount_cents" => 1_101})])
      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"

      assert guest_credit(conn)["available_cents"] == 1_100
      assert fetched_group(conn)["deposit_paid_cents"] == 0
      assert fetched_group(conn)["revision"] == 1
    end

    test "rejects a guest without any credit", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [result] = run(conn, [credit_op(%{"amount_cents" => 100})])
      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "rejects a stale revision before the credit rules", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 1_000)
      assert [_] = run(conn, [open_op()])

      assert [result] =
               run(conn, [credit_op(%{"expected_revision" => 5, "amount_cents" => 999_999})])

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 5,
               "actual_revision" => 1
             }

      assert fetched_group(conn)["revision"] == 1
      assert guest_credit(conn)["available_cents"] == 1_100
    end

    test "rejections never increment the revision", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      for op <- [
            credit_op(%{"amount_cents" => 0}),
            credit_op(%{"amount_cents" => 999_999}),
            credit_op(%{"expected_revision" => 9})
          ] do
        assert [result] = run(conn, [op])
        assert result["status"] == "rejected"
      end

      assert fetched_group(conn)["revision"] == 1
    end

    test "groups funded from the same lot settle independently", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-10-20")

      assert [_] = run(conn, [open_op(%{"group_id" => "group-a", "operation_id" => "op-open-a"})])
      assert [_] = run(conn, [open_op(%{"group_id" => "group-b", "operation_id" => "op-open-b"})])

      assert [_] =
               run(conn, [
                 credit_op(%{
                   "group_id" => "group-a",
                   "amount_cents" => 1_000,
                   "operation_id" => "op-credit-a"
                 })
               ])

      assert [_] =
               run(conn, [
                 credit_op(%{
                   "group_id" => "group-b",
                   "amount_cents" => 500,
                   "operation_id" => "op-credit-b"
                 })
               ])

      assert guest_credit(conn)["available_cents"] == 700

      assert [kept] =
               run(conn, [
                 cancel_op(%{
                   "group_id" => "group-a",
                   "occurred_on" => "2026-12-09",
                   "operation_id" => "op-cancel-a"
                 })
               ])

      assert kept["status"] == "applied"
      assert kept["retained_cents"] == 0
      assert guest_credit(conn)["available_cents"] == 700

      assert [restored] =
               run(conn, [
                 cancel_op(%{
                   "group_id" => "group-b",
                   "occurred_on" => "2026-11-26",
                   "operation_id" => "op-cancel-b"
                 })
               ])

      assert restored["status"] == "applied"

      assert guest_credit(conn)["available_cents"] == 1_200
      assert ledger(conn)["credit_liability_cents"] == 1_200
    end
  end

  describe "settling credit-funded groups" do
    setup %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 5_000, "2026-10-20")
      assert [_] = run(conn, [open_op()])
      assert [applied] = run(conn, [credit_op(%{"amount_cents" => 5_500})])
      assert applied["status"] == "applied"
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 1_000})])
      :ok
    end

    test "a cash refund returns applied credit to its original lot", %{conn: conn} do
      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 1_000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn) == %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-fund",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-10-21"
                 }
               ]
             }

      assert ledger(conn)["cash_refunded_cents"] == 1_000
      assert ledger(conn)["credit_liability_cents"] == 5_500
    end

    test "a hotel credit settlement funds a new lot without a second bonus", %{conn: conn} do
      assert [result] =
               run(conn, [
                 cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
               ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 1_100

      assert guest_credit(conn)["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-fund",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-10-21"
               },
               %{
                 "source_operation_id" => "op-cancel",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2027-11-27"
               }
             ]

      assert ledger(conn)["cash_converted_to_credit_cents"] == 6_000
      assert ledger(conn)["credit_liability_cents"] == 6_600
    end

    test "a non-refundable cancellation retains cash and consumes credit", %{conn: conn} do
      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2026-12-01"})])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1_000
      assert result["credit_issued_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["cash_retained_cents"] == 1_000
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "restored credit whose expiry has passed expires immediately", %{conn: conn} do
      assert [_] =
               run(conn, [
                 reschedule_op(%{"occurred_on" => "2026-10-06", "new_arrival_on" => "2027-12-10"})
               ])

      # The funding lot expired on 2027-10-21, before this cancellation.
      assert [result] = run(conn, [cancel_op(%{"occurred_on" => "2027-11-01"})])
      assert result["status"] == "applied"
      assert result["refunded_cents"] == 1_000

      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0

      as_of_before = get(conn, "/api/v1/ledger?on=2027-10-20")
      assert json_response(as_of_before, 200)["data"]["credit_liability_cents"] == 0
    end
  end
end
