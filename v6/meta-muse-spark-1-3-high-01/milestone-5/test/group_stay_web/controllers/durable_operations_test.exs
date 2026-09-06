defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp open_op(group_id, op_id) do
    %{
      "operation_id" => op_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  test "retry with identical payload returns exact original result without reapplying", %{
    conn: conn
  } do
    conn = post_batch(conn, [open_op("group-idem-1", "op-idem-1")])
    assert %{"results" => [first]} = json_response(conn, 200)
    assert first["status"] == "applied"
    assert first["revision"] == 1

    # pay once
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-idem-1",
          "amount_cents" => 5_000
        }
      ])

    assert %{"results" => [pay1]} = json_response(c, 200)
    assert pay1["revision"] == 2
    assert pay1["outstanding_deposit_cents"] == 14_500

    # retry same payment verbatim: must return identical result even though
    # outstanding is now smaller (a fresh op for 5000 would exceed it)
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-idem-1",
          "amount_cents" => 5_000
        }
      ])

    assert %{"results" => [pay2]} = json_response(c, 200)
    assert pay2 == pay1

    # group revision must not have advanced again
    c = get(build_conn(), "/api/v1/groups/group-idem-1")
    assert %{"data" => %{"revision" => 2}} = json_response(c, 200)

    # operations endpoint exposes stored result
    c = get(build_conn(), "/api/v1/operations/op-idem-pay")
    assert %{"data" => stored} = json_response(c, 200)
    assert stored == pay1

    # unknown operation id 404
    c = get(build_conn(), "/api/v1/operations/no-such-op")
    assert %{"error" => %{"code" => "operation_not_found"}} = json_response(c, 404)
  end

  test "rejected results are remembered; retry stays rejected even if now valid", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-idem-2", "op-idem-2")])
    assert json_response(conn, 200)

    # payment exceeding outstanding is rejected
    too_much = 99_999

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-rej",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-idem-2",
          "amount_cents" => too_much
        }
      ])

    assert %{"results" => [rej1]} = json_response(c, 200)
    assert rej1["code"] == "payment_exceeds_outstanding"

    # cancel the group (no cash paid) then retry the same payment: original
    # rejection must be returned, not group_not_active
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-2cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-idem-2"
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-rej",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-idem-2",
          "amount_cents" => too_much
        }
      ])

    assert %{"results" => [rej2]} = json_response(c, 200)
    assert rej2 == rej1
  end

  test "reusing identifier with different payload is a conflict", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-idem-3", "op-idem-3")])
    assert json_response(conn, 200)

    base = %{
      "operation_id" => "op-idem-conf",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-idem-3",
      "amount_cents" => 1_000
    }

    c = post_batch(build_conn(), [base])
    assert %{"results" => [r1]} = json_response(c, 200)
    assert r1["status"] == "applied"

    # different amount -> conflict, group_id echoed
    c = post_batch(build_conn(), [Map.put(base, "amount_cents", 2_000)])
    assert %{"results" => [r2]} = json_response(c, 200)
    assert r2["status"] == "rejected"
    assert r2["code"] == "operation_id_conflict"
    assert r2["operation_id"] == "op-idem-conf"
    assert r2["group_id"] == "group-idem-3"

    # original record unchanged
    c = get(build_conn(), "/api/v1/operations/op-idem-conf")
    assert %{"data" => stored} = json_response(c, 200)
    assert stored == r1

    # revision advanced only once
    c = get(build_conn(), "/api/v1/groups/group-idem-3")
    assert %{"data" => %{"revision" => 2}} = json_response(c, 200)
  end

  test "key order is irrelevant but array order is significant", %{conn: conn} do
    op_a = %{
      "operation_id" => "op-idem-key",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-idem-key",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }

    conn = post_batch(conn, [op_a])
    assert %{"results" => [r1]} = json_response(conn, 200)
    assert r1["status"] == "applied"

    # Same content, keys inserted in a different order at the top level.
    op_reordered =
      op_a
      |> Map.to_list()
      |> Enum.reverse()
      |> Map.new()

    c = post_batch(build_conn(), [op_reordered])
    assert %{"results" => [r2]} = json_response(c, 200)
    assert r2 == r1

    # Swapped room order is a different payload -> conflict with same id.
    op_swapped = Map.put(op_a, "rooms", Enum.reverse(op_a["rooms"]))

    c = post_batch(build_conn(), [op_swapped])
    assert %{"results" => [r3]} = json_response(c, 200)
    assert r3["code"] == "operation_id_conflict"
  end

  test "stale retry returns stored stale details verbatim; corrected revision conflicts", %{
    conn: conn
  } do
    conn = post_batch(conn, [open_op("group-idem-4", "op-idem-4")])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-pay4",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-idem-4",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }
      ])

    assert %{"results" => [%{"revision" => 2}]} = json_response(c, 200)

    stale = %{
      "operation_id" => "op-idem-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-idem-4",
      "amount_cents" => 500,
      "expected_revision" => 1
    }

    c = post_batch(build_conn(), [stale])
    assert %{"results" => [s1]} = json_response(c, 200)
    assert s1["code"] == "stale_revision"
    assert s1["actual_revision"] == 2

    # exact retry returns stored stale details even after revision moves on
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-idem-pay4b",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-idem-4",
          "amount_cents" => 500,
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"revision" => 3}]} = json_response(c, 200)

    c = post_batch(build_conn(), [stale])
    assert %{"results" => [s2]} = json_response(c, 200)
    assert s2 == s1

    # corrected expected_revision under same id is a different payload
    c = post_batch(build_conn(), [Map.put(stale, "expected_revision", 3)])
    assert %{"results" => [s3]} = json_response(c, 200)
    assert s3["code"] == "operation_id_conflict"
  end

  test "duplicate operation_id inside one batch: second is a replay", %{conn: conn} do
    op = open_op("group-idem-5", "op-idem-5")

    conn = post_batch(conn, [op, op])
    assert %{"results" => [r1, r2]} = json_response(conn, 200)
    assert r1["status"] == "applied"
    assert r2 == r1
  end
end
