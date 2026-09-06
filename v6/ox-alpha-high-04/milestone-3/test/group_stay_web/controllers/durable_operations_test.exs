defmodule GroupStayWeb.DurableOperationsTest do
  @moduledoc """
  Durable-idempotency behavior delivered with this release: exact-result
  retries, `operation_id_conflict`, remembered rejections, same-transaction
  commits, audit retention, and the operation read endpoint.
  """

  use GroupStayWeb.ConnCase, async: true

  import Ecto.Query
  import GroupStay.TestOperations

  alias GroupStay.DurableOperations.OperationRecord
  alias GroupStay.Repo

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", batch(List.wrap(operations)))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_data(conn, path) do
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  describe "equivalent retries" do
    test "return the exact original result without reading or changing domain state", %{
      conn: conn
    } do
      op = pay("group-81", 10000)

      [_opening, first] = submit(conn, [open_group(), op])
      assert first["revision"] == 2

      # Domain state moves on before the gateway retries its lost response.
      [_second] = submit(conn, [pay("group-81", 9500, %{"operation_id" => "pay-rest"})])

      # An exact retry replays the stored result verbatim, including the
      # revision observed on the original attempt.
      assert submit(conn, [op]) == [first]

      assert get_data(conn, "/api/v1/groups/group-81") == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 3,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 19500,
               "outstanding_deposit_cents" => 0,
               "cash_paid_cents" => 19500,
               "credit_paid_cents" => 0,
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26"
             }
    end

    test "are independent of JSON object key order", %{conn: _conn} do
      submitted =
        open_group(%{
          "occurred_on" => "2026-10-03",
          "group_id" => "group-keys",
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
        })

      first = GroupStay.Operations.apply(submitted)
      assert first["status"] == "applied"

      retried = GroupStay.Operations.apply(submitted)

      # The retry is served from storage rather than by parsing and applying
      # a second time, which would have been group_already_exists.
      assert retried == first
      assert retried["deposit_due_cents"] == 9000
    end
  end

  describe "reusing an identifier with a different payload" do
    test "is rejected with operation_id_conflict and keeps the original record", %{conn: conn} do
      opening = open_group()
      op = pay("group-81", 10000)

      [original_open, original_pay] = submit(conn, [opening, op])

      # Array order remains significant: reversing the room array changes the
      # submitted payload.
      swapped_rooms = Map.put(opening, "rooms", Enum.reverse(opening["rooms"]))

      # So does changing a value, such as the paid amount.
      changed_amount = Map.put(op, "amount_cents", 500)

      for changed <- [swapped_rooms, changed_amount] do
        assert submit(conn, [changed]) == [
                 %{
                   "status" => "rejected",
                   "code" => "operation_id_conflict",
                   "operation_id" => changed["operation_id"]
                 }
               ]
      end

      # Neither conflict replaced the original records: exact retries still
      # replay them.
      assert submit(conn, [opening]) == [original_open]
      assert submit(conn, [op]) == [original_pay]
    end

    test "includes a corrected expected_revision on a stale submission", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 100, %{"operation_id" => "seed"})])

      stale =
        pay("group-81", 19500, %{"operation_id" => "stale-op", "expected_revision" => 1})

      [_stale_rejection] = submit(conn, [stale])

      # Retrying under the same identifier with the now-correct revision is a
      # different payload, therefore a conflict — never an application.
      corrected =
        pay("group-81", 19500, %{"operation_id" => "stale-op", "expected_revision" => 2})

      assert submit(conn, [corrected]) == [
               %{
                 "status" => "rejected",
                 "code" => "operation_id_conflict",
                 "operation_id" => "stale-op"
               }
             ]

      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 2
    end
  end

  describe "remembered rejections" do
    test "still receive the original rejection once later operations make them valid", %{
      conn: conn
    } do
      too_big = pay("group-81", 25000)

      [_opening, first_rejection] = submit(conn, [open_group(), too_big])
      assert first_rejection["code"] == "payment_exceeds_outstanding"

      # Funding continues until the whole deposit could be paid today.
      submit(conn, [pay("group-81", 19500, %{"operation_id" => "fund-a"})])

      # The full deposit is now settled, so the retry would be valid today.
      assert get_data(conn, "/api/v1/groups/group-81")["outstanding_deposit_cents"] == 0

      # But the retry still gets the original, stale rejection verbatim.
      assert submit(conn, [too_big]) == [first_rejection]
    end

    test "stale-revision details are part of the exact result", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 100, %{"operation_id" => "seed"})])

      stale = pay("group-81", 100, %{"operation_id" => "late-pay", "expected_revision" => 1})

      [original_stale] = submit(conn, [stale])

      assert original_stale == %{
               "operation_id" => "late-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # The group keeps moving, but the retry must not observe current state.
      submit(conn, [reschedule("group-81", "2026-12-20", %{"operation_id" => "move-one"})])

      assert submit(conn, [stale]) == [original_stale]
    end

    test "include handled invalid_operation outcomes for malformed content", %{conn: conn} do
      bogus = %{
        "operation_id" => "weird-op",
        "type" => "shrink_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81"
      }

      [rejection] = submit(conn, [bogus])
      assert rejection["code"] == "invalid_operation"

      assert submit(conn, [bogus]) == [rejection]
    end
  end

  describe "batch semantics" do
    test "handled rejections commit their record and continue with later operations", %{
      conn: conn
    } do
      opening = open_group()

      results =
        submit(conn, [
          opening,
          pay("group-81", 999_999, %{"operation_id" => "over-pay"}),
          pay("group-81", 19500, %{"operation_id" => "full-pay"})
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding",
                 "operation_id" => "over-pay"
               },
               %{"status" => "applied", "outstanding_deposit_cents" => 0}
             ] = results

      # Every remembered operation — applied or rejected — is durable,
      # including the rejected one between the two applications.
      assert remember_ids() == [opening["operation_id"], "over-pay", "full-pay"]
    end

    test "durable records preserve the order they were first committed in", %{conn: conn} do
      opening = open_group()

      submit(conn, [
        opening,
        pay("group-81", 999_999, %{"operation_id" => "order-bad"}),
        pay("group-81", 100, %{"operation_id" => "order-good"}),
        reschedule("group-81", "2026-12-20", %{"operation_id" => "order-move"})
      ])

      assert remember_ids() ==
               [
                 opening["operation_id"],
                 "order-bad",
                 "order-good",
                 "order-move"
               ]
    end

    test "records retain the type and the complete submitted content", %{conn: conn} do
      cancel_op =
        cancel("group-81", "2026-11-20", %{
          "operation_id" => "audit-cancel",
          "refund_method" => nil
        })

      submitted_open = open_group(%{"operation_id" => "audit-open"})
      submit(conn, [submitted_open, cancel_op])

      records =
        Repo.all(from(r in OperationRecord, order_by: [asc: r.id]))
        |> Map.new(&{&1.operation_id, &1})

      # The complete submitted content is retained — even null-valued keys
      # are kept exactly as sent.
      assert Jason.decode!(records["audit-open"].payload_json) == submitted_open
      assert records["audit-open"].type == "open_group"

      assert Jason.decode!(records["audit-cancel"].payload_json) == cancel_op
      assert records["audit-cancel"].type == "cancel_group"
    end
  end

  describe "unexpected exceptions" do
    test "abort the request, roll back, and leave nothing remembered", %{conn: conn} do
      opening = open_group()
      submit(conn, [opening])

      unforgivable =
        open_group(%{
          "operation_id" => "doomed-open",
          "group_id" => "doomed-group",
          "guest_id" => "guest-nines",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 5_000_000_000_000_000_000}]
        })

      # An amount beyond SQLite's integer range makes the write explode after
      # validation, the way an unexpected server fault does.
      assert_raise Exqlite.Error, fn ->
        post(conn, "/api/v1/partner-batches", batch([unforgivable]))
      end

      # The faulted operation left nothing remembered; only the healthy
      # opening from before it is durable.
      assert remember_ids() == [opening["operation_id"]]

      assert get_data(conn, "/api/v1/groups/group-81")["revision"] == 1

      # The gateway may retry the batch; the same identifier processes afresh.
      recovered =
        open_group(%{
          "operation_id" => "doomed-open",
          "group_id" => "doomed-group",
          "guest_id" => "guest-nines",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12345}]
        })

      assert submit(conn, [recovered]) == [
               %{
                 "status" => "applied",
                 "operation_id" => "doomed-open",
                 "group_id" => "doomed-group",
                 "deposit_due_cents" => 7407,
                 "revision" => 1
               }
             ]
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "exposes the stored result of applied and rejected operations", %{conn: conn} do
      [open_result] =
        submit(conn, [open_group(%{"operation_id" => "audit-open"})])

      [rejected_result] =
        submit(conn, [pay("ghost", 100, %{"operation_id" => "audit-reject"})])

      assert json_response(get(conn, "/api/v1/operations/audit-open"), 200) ==
               %{"data" => open_result}

      assert json_response(get(conn, "/api/v1/operations/audit-reject"), 200) ==
               %{"data" => rejected_result}
    end

    test "returns 404 operation_not_found for unremembered identifiers", %{conn: conn} do
      conn = get(conn, "/api/v1/operations/neither-ever-submitted")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  ## Helpers

  defp remember_ids do
    Repo.all(from(r in OperationRecord, order_by: [asc: r.id], select: r.operation_id))
  end
end
