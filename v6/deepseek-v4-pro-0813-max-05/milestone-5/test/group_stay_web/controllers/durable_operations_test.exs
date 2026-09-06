defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  alias GroupStay.{DurableOperation, Operations, Repo}

  defp operations_path(operation_id), do: "/api/v1/operations/#{operation_id}"

  # A nightly rate too large for SQLite's 64-bit integer storage: it passes
  # the operation's own validation but the database write raises, producing
  # the unexpected-exception path.
  @oversized_rate 340_282_366_920_938_463_463_374_607_431_768_211_456

  describe "durable retries" do
    test "an exact retry returns the stored applied result without touching domain state", %{
      conn: conn
    } do
      open_group!(conn)

      pay = payment(%{"amount_cents" => 10_000})
      [original] = json_response(json_post(conn, pay), 200)["results"]
      assert original["revision"] == 2

      json_post(conn, payment(%{"operation_id" => "op-pay-2", "amount_cents" => 9_500}))

      # A fresh attempt would now be rejected (the outstanding deposit is 0),
      # but the retry replays the stored result without consulting the group.
      assert json_response(json_post(conn, pay), 200)["results"] == [original]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 3, "deposit_paid_cents" => 19_500} = data
    end

    test "a remembered rejection replays even when later operations make it valid", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "operation_id" => "open-src",
          "group_id" => "group-src",
          "guest_id" => "guest-durable"
        }),
        open_group(%{
          "operation_id" => "open-target",
          "group_id" => "group-target",
          "guest_id" => "guest-durable"
        })
      ])

      apply = apply_credit(%{"group_id" => "group-target", "amount_cents" => 5_000})
      [rejection] = json_response(json_post(conn, apply), 200)["results"]
      assert rejection["code"] == "insufficient_credit"

      # Credit arrives after the rejection; a fresh attempt would now apply.
      json_post(
        conn,
        cancel(%{
          "group_id" => "group-src",
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      )

      assert json_response(json_post(conn, apply), 200)["results"] == [rejection]

      data = json_response(get(conn, groups_path("group-target")), 200)["data"]
      assert %{"revision" => 1, "credit_paid_cents" => 0} = data
    end

    test "a different payload reusing the identifier is rejected and never replaces the record",
         %{
           conn: conn
         } do
      op = open_group(%{"operation_id" => "op-key"})
      [result] = json_response(json_post(conn, op), 200)["results"]

      conflicting = %{op | "group_id" => "other-group"}

      assert [
               %{
                 "operation_id" => "op-key",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(json_post(conn, conflicting), 200)["results"]

      # The conflict did not replace the stored record.
      assert json_response(json_post(conn, op), 200)["results"] == [result]
      assert json_response(get(conn, groups_path("other-group")), 404)
    end

    test "JSON object key order is ignored but array values keep their order", %{conn: conn} do
      op =
        open_group(%{
          "operation_id" => "op-keys",
          "group_id" => "group-keys",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })

      [result] = json_response(json_post(conn, op), 200)["results"]

      reordered =
        %{
          "rooms" => [%{"nightly_rate_cents" => 15_000, "room_id" => "room-a"}],
          "rate_plan" => "flexible",
          "departure_on" => "2026-12-13",
          "arrival_on" => "2026-12-10",
          "property_id" => "ams-canal",
          "guest_id" => "guest-22",
          "group_id" => "group-keys",
          "occurred_on" => "2026-10-03",
          "type" => "open_group",
          "operation_id" => "op-keys"
        }

      assert json_response(json_post(conn, reordered), 200)["results"] == [result]

      data = json_response(get(conn, groups_path("group-keys")), 200)["data"]
      assert data["revision"] == 1

      swapped =
        %{
          reordered
          | "rooms" => [
              %{"nightly_rate_cents" => 15_000, "room_id" => "room-b"},
              %{"nightly_rate_cents" => 15_000, "room_id" => "room-a"}
            ]
        }

      assert [%{"code" => "operation_id_conflict"}] =
               json_response(json_post(conn, swapped), 200)["results"]

      assert json_response(json_post(conn, reordered), 200)["results"] == [result]
      assert json_response(get(conn, groups_path("group-keys")), 200)["data"]["revision"] == 1
    end

    test "stale-revision results replay verbatim and a corrected revision is a conflict", %{
      conn: conn
    } do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      stale =
        payment(%{
          "operation_id" => "op-stale",
          "expected_revision" => 1,
          "amount_cents" => 8_000
        })

      [rejection] = json_response(json_post(conn, stale), 200)["results"]

      assert rejection == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # The exact retry returns the stored stale result verbatim.
      assert json_response(json_post(conn, stale), 200)["results"] == [rejection]

      corrected = %{stale | "expected_revision" => 2}

      assert [%{"code" => "operation_id_conflict"}] =
               json_response(json_post(conn, corrected), 200)["results"]

      assert json_response(json_post(conn, stale), 200)["results"] == [rejection]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 2} = data
    end

    test "a handled rejection commits its record and leaves domain state unchanged", %{conn: conn} do
      open_group!(conn)

      rejected = payment(%{"operation_id" => "op-over", "amount_cents" => 20_000})
      [result] = json_response(json_post(conn, rejected), 200)["results"]

      assert result == %{
               "operation_id" => "op-over",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert json_response(get(conn, operations_path("op-over")), 200) == %{"data" => result}

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = data
    end

    test "handled invalid_operation rejections are remembered by operation_id", %{conn: conn} do
      op = %{
        "operation_id" => "op-mystery",
        "type" => "teleport_group",
        "occurred_on" => "2026-11-01"
      }

      [first] = json_response(json_post(conn, op), 200)["results"]

      assert first == %{
               "operation_id" => "op-mystery",
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert json_response(json_post(conn, op), 200)["results"] == [first]
    end

    test "duplicate operations in one batch replay the original result", %{conn: conn} do
      op = open_group(%{"operation_id" => "op-one"})

      assert [first, second] = json_response(submit(conn, [op, op]), 200)["results"]
      assert first == second

      assert json_response(get(conn, groups_path("group-81")), 200)["data"]["revision"] == 1
    end

    test "concurrent retries have at-most-once effects", %{conn: conn} do
      op = open_group(%{"operation_id" => "op-race", "group_id" => "group-race"})

      results =
        1..8
        |> Enum.map(fn _ -> op end)
        |> Task.async_stream(&Operations.apply_operation/1, max_concurrency: 8, ordered: false)
        |> Enum.map(fn {:ok, result} -> result end)

      assert [%{"status" => "applied", "revision" => 1, "group_id" => "group-race"}] =
               Enum.uniq(results)

      data = json_response(get(conn, groups_path("group-race")), 200)["data"]
      assert data["revision"] == 1
    end
  end

  describe "operation reads" do
    test "returns the stored result of a remembered operation", %{conn: conn} do
      open_group!(conn)

      [pay_result] =
        json_response(json_post(conn, payment(%{"amount_cents" => 9_000})), 200)["results"]

      assert json_response(get(conn, operations_path("op-pay")), 200) == %{"data" => pay_result}

      assert json_response(get(conn, operations_path("op-open")), 200) == %{
               "data" => %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             }
    end

    test "an unknown operation identifier is 404 with operation_not_found", %{conn: conn} do
      assert json_response(get(conn, operations_path("no-such-op")), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end
  end

  describe "durable audit records" do
    test "retain the submitted type, the complete content, and commit order", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      durables = Repo.all(DurableOperation) |> Enum.sort_by(& &1.id)

      assert Enum.map(durables, & &1.operation_id) == ["op-open", "op-pay"]
      assert Enum.map(durables, & &1.op_type) == ["open_group", "record_cash_payment"]

      [open_record, pay_record] =
        Enum.map(durables, fn durable -> Jason.decode!(durable.payload_json) end)

      assert open_record["group_id"] == "group-81"

      assert open_record["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ]

      assert pay_record["group_id"] == "group-81"
      assert pay_record["amount_cents"] == 5_000
    end
  end

  describe "unexpected faults" do
    test "an unexpected exception aborts the batch with 500 and is not remembered", %{conn: conn} do
      opener = open_group(%{"operation_id" => "op-open", "group_id" => "group-81"})

      boom =
        open_group(%{
          "operation_id" => "op-boom",
          "group_id" => "group-boom",
          "rooms" => [%{"room_id" => "big-room", "nightly_rate_cents" => @oversized_rate}]
        })

      follower = payment(%{"operation_id" => "op-after", "amount_cents" => 1_000})

      conn = submit(conn, [opener, boom, follower])

      assert conn.status == 500
      assert json_response(conn, 500) == %{"error" => %{"code" => "internal_error"}}

      # Earlier operations stay committed.
      assert json_response(get(conn, groups_path("group-81")), 200)["data"]["revision"] == 1

      # The failing operation rolled back and was never remembered; the batch
      # stopped before the following operation ran.
      assert json_response(get(conn, groups_path("group-boom")), 404)
      assert json_response(get(conn, operations_path("op-boom")), 404)
      assert json_response(get(conn, operations_path("op-after")), 404)
    end
  end
end
