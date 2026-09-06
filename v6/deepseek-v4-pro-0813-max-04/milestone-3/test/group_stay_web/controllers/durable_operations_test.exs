defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query
  import GroupStay.Operations

  alias GroupStay.Deposits.Operation
  alias GroupStay.Repo

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_group(conn, group_id),
    do: json_response(get(conn, ~p"/api/v1/groups/#{group_id}"), 200)["data"]

  defp get_operation(conn, operation_id),
    do: json_response(get(conn, ~p"/api/v1/operations/#{operation_id}"), 200)["data"]

  defp ledger(conn), do: json_response(get(conn, ~p"/api/v1/ledger"), 200)["data"]

  describe "equivalent retries" do
    test "return the exact original result without applying the operation twice" do
      conn = build_conn()

      ops = [open(), payment()]

      first = batch_results(conn, ops)
      again = batch_results(conn, ops)

      assert Enum.map(first, & &1["status"]) == ["applied", "applied"]
      assert again == first

      # The retry neither re-applies nor advances state.
      assert get_group(conn, "group-81")["revision"] == 2
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 10_000
      assert ledger(conn)["cash_held_cents"] == 10_000
    end

    test "does not consult current domain state for revisions or stale details" do
      conn = build_conn()

      stale = payment(%{"operation_id" => "op-stale", "expected_revision" => 99})

      first = batch_results(conn, [open(), stale])

      assert Enum.at(first, 1) == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      # Move the group on; a corrected revision would now fit, but the retry
      # must return the stored rejection verbatim.
      batch_results(conn, [payment(%{"operation_id" => "op-other", "amount_cents" => 1_000})])
      current_revision = get_group(conn, "group-81")["revision"]

      again = batch_results(conn, [open(), stale])

      assert again == first
      assert Enum.at(again, 1)["actual_revision"] == 1
      assert get_group(conn, "group-81")["revision"] == current_revision
    end

    test "a retry of the whole batch returns the whole original batch result" do
      conn = build_conn()

      ops = [
        open(),
        payment(),
        reschedule(),
        cancel(),
        open(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-82",
          "guest_id" => "guest-23"
        })
      ]

      first = batch_results(conn, ops)
      again = batch_results(conn, ops)

      assert again == first
      assert get_group(conn, "group-81")["status"] == "cancelled"
      assert get_group(conn, "group-81")["revision"] == 4
    end

    test "treats JSON object key order as irrelevant" do
      conn = build_conn()

      original =
        ~s|{"operations":[{"operation_id":"op-open","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]}|

      reordered =
        ~s|{"operations":[{"rate_plan":"flexible","rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"nightly_rate_cents":17500,"room_id":"room-b"}],"type":"open_group","departure_on":"2026-12-13","arrival_on":"2026-12-10","occurred_on":"2026-10-03","guest_id":"guest-22","property_id":"ams-canal","operation_id":"op-open","group_id":"group-81"}]}|

      conn = put_req_header(conn, "content-type", "application/json")
      first = json_response(post(conn, ~p"/api/v1/partner-batches", original), 200)

      conn = build_conn()
      conn = put_req_header(conn, "content-type", "application/json")
      again = json_response(post(conn, ~p"/api/v1/partner-batches", reordered), 200)

      assert again == first
      assert get_group(conn, "group-81")["revision"] == 1
    end

    test "the second occurrence of an identifier within one batch replays" do
      conn = build_conn()

      results = batch_results(conn, [open(), open()])

      assert results == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]

      assert get_group(conn, "group-81")["revision"] == 1
    end
  end

  describe "remembered rejections" do
    test "a retry still receives the original rejection once later state would make it valid" do
      conn = build_conn()

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      apply = apply_credit(%{"group_id" => "group-target", "amount_cents" => 5_000})

      first = batch_results(conn, [target, apply])

      assert Enum.at(first, 0)["status"] == "applied"

      assert Enum.at(first, 1) == %{
               "operation_id" => "op-credit",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      # Now make the guest's credit sufficient for exactly that operation.
      source =
        open(%{
          "operation_id" => "op-source",
          "group_id" => "group-source",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      pay_source =
        payment(%{
          "operation_id" => "op-pay-source",
          "group_id" => "group-source",
          "amount_cents" => 10_000
        })

      credit_cancel =
        cancel(%{
          "operation_id" => "op-cancel-source",
          "group_id" => "group-source",
          "occurred_on" => "2027-02-01",
          "refund_method" => "hotel_credit"
        })

      batch_results(conn, [source, pay_source, credit_cancel])

      again = batch_results(conn, [apply])

      assert again == first |> Enum.drop(1)
      assert get_group(conn, "group-target")["revision"] == 1
      assert get_group(conn, "group-target")["credit_paid_cents"] == 0
    end

    test "remembered handled rejections leave the database exactly as it was" do
      conn = build_conn()

      over = payment(%{"operation_id" => "op-over", "amount_cents" => 20_000})

      batch_results(conn, [open(), over])

      retry = batch_results(conn, [over])

      assert retry == [
               %{
                 "operation_id" => "op-over",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               }
             ]

      assert get_group(conn, "group-81")["revision"] == 1
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 0
    end
  end

  describe "payload conflicts" do
    test "reusing an identifier with a different payload is rejected and keeps the original record" do
      conn = build_conn()

      first = batch_results(conn, [open()])

      conflict = batch_results(conn, [open(%{"guest_id" => "guest-99"})])

      assert conflict == [
               %{
                 "operation_id" => "op-open",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]

      # The conflict does not replace the original record...
      assert get_operation(conn, "op-open") == hd(first)

      # ...so the original payload still replays verbatim.
      assert batch_results(conn, [open()]) == first
      assert get_group(conn, "group-81")["guest_id"] == "guest-22"
    end

    test "array order within the payload is significant" do
      conn = build_conn()

      open_with_rooms =
        open(%{
          "operation_id" => "op-rooms",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
          ]
        })

      batch_results(conn, [open_with_rooms])

      swapped_rooms =
        open(%{
          "operation_id" => "op-rooms",
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        })

      assert batch_results(conn, [swapped_rooms]) == [
               %{
                 "operation_id" => "op-rooms",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
    end

    test "retrying a stale operation with a corrected revision is a conflict" do
      conn = build_conn()

      stale = payment(%{"operation_id" => "op-slow", "expected_revision" => 1})

      first = batch_results(conn, [open(), payment(), stale])

      assert Enum.at(first, 2)["code"] == "stale_revision"

      corrected =
        payment(%{
          "operation_id" => "op-slow",
          "expected_revision" => 2,
          "amount_cents" => 1_000
        })

      assert batch_results(conn, [corrected]) == [
               %{
                 "operation_id" => "op-slow",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]

      # The group itself was never adjusted by either of these attempts.
      assert get_group(conn, "group-81")["revision"] == 2
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result" do
      conn = build_conn()

      results = batch_results(conn, [open(), payment()])

      assert get_operation(conn, "op-open") == Enum.at(results, 0)
      assert get_operation(conn, "op-pay") == Enum.at(results, 1)
    end

    test "returns stored results for rejected operations" do
      conn = build_conn()

      results = batch_results(conn, [open(), payment(%{"amount_cents" => 99_999})])

      assert get_operation(conn, "op-pay") == Enum.at(results, 1)
      assert Enum.at(results, 1)["status"] == "rejected"
    end

    test "returns 404 with the stable code for an unknown operation" do
      conn = build_conn()

      conn = get(conn, ~p"/api/v1/operations/no-such-op")

      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "exposes only the stored result and not the submission" do
      conn = build_conn()

      batch_results(conn, [open()])

      assert get_operation(conn, "op-open") == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end
  end

  describe "durable audit records" do
    test "retain the type and the complete submitted content" do
      conn = build_conn()

      mystery = %{"operation_id" => "unknown-op", "type" => "close_group"}
      batch_results(conn, [mystery, open()])

      records =
        from(o in Operation, order_by: [asc: o.id], select: {o.operation_id, o.type, o.payload})
        |> Repo.all()

      assert Enum.map(records, &elem(&1, 0)) == ["unknown-op", "op-open"]
      assert Enum.map(records, &elem(&1, 1)) == ["close_group", "open_group"]
      assert Jason.decode!(Enum.at(records, 0) |> elem(2)) == mystery
      assert Jason.decode!(Enum.at(records, 1) |> elem(2)) == open()
    end

    test "preserve the order in which durable records were first committed" do
      conn = build_conn()

      batch_results(conn, [
        %{"operation_id" => "op-first", "type" => "close_group"},
        open(),
        payment(),
        %{"operation_id" => "op-last", "type" => "close_group"}
      ])

      records =
        from(o in Operation, order_by: [asc: o.id], select: o.operation_id)
        |> Repo.all()

      assert records == ["op-first", "op-open", "op-pay", "op-last"]
    end

    test "commit with their domain changes in the same transaction" do
      conn = build_conn()

      batch_results(conn, [open(), payment()])

      records =
        from(o in Operation, order_by: [asc: o.id], select: {o.operation_id, o.result})
        |> Repo.all()

      assert Enum.map(records, &Jason.decode!(elem(&1, 1))) == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               }
             ]

      assert get_group(conn, "group-81")["deposit_paid_cents"] == 10_000
    end
  end

  describe "unexpected server faults" do
    test "roll back the failed operation without remembering it and abort with 500" do
      conn = build_conn()

      # A nightly rate beyond SQLite's 64-bit integer range fails with an
      # uncontrolled exception rather than a handled rejection.
      big =
        open(%{
          "operation_id" => "op-big",
          "group_id" => "group-big",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 9_223_372_036_854_775_808}
          ]
        })

      # The endpoint renders the 500 and re-raises in tests after the request
      # is answered.
      assert_raise Exqlite.Error, fn -> post_batch(conn, [open(), big]) end

      # Earlier handled operations in the batch stay committed.
      assert get_group(conn, "group-81")["revision"] == 1
      assert get_operation(conn, "op-open")

      # The failed operation left no durable record and no group.
      assert get(conn, ~p"/api/v1/operations/op-big").status == 404
      assert get(conn, ~p"/api/v1/groups/group-big").status == 404
    end
  end
end
