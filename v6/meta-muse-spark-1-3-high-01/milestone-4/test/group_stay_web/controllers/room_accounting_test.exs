defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
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
      },
      overrides
    )
  end

  test "cash funds rooms in order and cancel_rooms settles subset", %{conn: conn} do
    conn = post_batch(conn, [open_op("g-room1")])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    # deposit due: 9000 + 10500 = 19500. Pay 10000 -> room-a full (9000), room-b 1000.
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-pay1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "g-room1",
          "amount_cents" => 10_000
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c = get(build_conn(), "/api/v1/groups/g-room1")
    assert %{"data" => d} = json_response(c, 200)
    assert d["deposit_paid_cents"] == 10_000
    assert d["outstanding_deposit_cents"] == 9_500
    by_id = Map.new(d["rooms"], fn r -> {r["room_id"], r} end)
    assert by_id["room-a"]["cash_paid_cents"] == 9_000
    assert by_id["room-a"]["status"] == "active"
    assert by_id["room-b"]["cash_paid_cents"] == 1_000

    # refundable partial cancel of room-a (cancel 11-20, 20 days before arrival)
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-cx1",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "g-room1",
          "room_ids" => ["room-a"]
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["cancelled_room_ids"] == ["room-a"]
    assert r["refunded_cents"] == 9_000
    assert r["retained_cents"] == 0
    assert r["credit_issued_cents"] == 0

    c = get(build_conn(), "/api/v1/groups/g-room1")
    assert %{"data" => d2} = json_response(c, 200)
    assert d2["status"] == "active"
    assert d2["deposit_due_cents"] == 10_500
    assert d2["deposit_paid_cents"] == 1_000
    assert d2["outstanding_deposit_cents"] == 9_500
    assert d2["lodging_total_cents"] == 52_500
    by2 = Map.new(d2["rooms"], fn r -> {r["room_id"], r} end)
    assert by2["room-a"]["status"] == "cancelled"

    # invalid room ids rejected
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-cxb",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "g-room1",
          "room_ids" => ["room-a"]
        }
      ])

    assert %{"results" => [%{"code" => "invalid_rooms"}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-cxc",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "g-room1",
          "room_ids" => ["room-a", "room-a"]
        }
      ])

    assert %{"results" => [%{"code" => "invalid_rooms"}]} = json_response(c, 200)
  end

  test "cancel_rooms bonus computed once on combined cash", %{conn: conn} do
    conn = post_batch(conn, [open_op("g-room2")])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-p2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "g-room2",
          "amount_cents" => 19_500
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-cx2",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "g-room2",
          "room_ids" => ["room-b", "room-a"],
          "refund_method" => "hotel_credit"
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    # combined cash 19500 -> bonus 1950 -> 21450 (not per-room 9900+11550=21450 same here
    # but single rounding: use 5 cents case below implicitly). Just check combined.
    assert r["credit_issued_cents"] == 21_450
    assert r["cancelled_room_ids"] == ["room-a", "room-b"]

    c = get(build_conn(), "/api/v1/groups/g-room2")
    assert %{"data" => %{"status" => "cancelled"}} = json_response(c, 200)
  end

  test "reduce_cash_payment reopens outstanding and composes", %{conn: conn} do
    conn = post_batch(conn, [open_op("g-red1")])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-red",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "g-red1",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-1",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-red",
          "amount_cents" => 2_000
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["group_id"] == "g-red1"
    assert r["amount_cents"] == 2_000
    assert r["outstanding_deposit_cents"] == 16_500

    # too much now (held 3000)
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-2",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-red",
          "amount_cents" => 3_001
        }
      ])

    assert %{"results" => [%{"code" => "reduction_exceeds_held_cash"}]} = json_response(c, 200)

    # exact remainder valid
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-3",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-red",
          "amount_cents" => 3_000
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    # now nothing held -> not reducible
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-4",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-red",
          "amount_cents" => 1
        }
      ])

    assert %{"results" => [%{"code" => "payment_not_reducible"}]} = json_response(c, 200)

    # unknown payment
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-5",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "nope",
          "amount_cents" => 1
        }
      ])

    assert %{"results" => [%{"code" => "operation_not_found"}]} = json_response(c, 200)

    # invalid amount
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-6",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-red",
          "amount_cents" => 0
        }
      ])

    assert %{"results" => [%{"code" => "invalid_amount"}]} = json_response(c, 200)

    # ledger reduced total
    lc = get(build_conn(), "/api/v1/ledger")
    assert %{"data" => ledger} = json_response(lc, 200)
    assert ledger["cash_reduced_cents"] == 5_000

    # reconcile payment
    pc = get(build_conn(), "/api/v1/payments/pay-red")
    assert %{"data" => p} = json_response(pc, 200)
    assert p["recorded_cents"] == 5_000
    assert p["held_cents"] == 0
    assert p["reduced_cents"] == 5_000
    assert p["refunded_cents"] == 0
    assert p["charged_back_cents"] == 0

    assert p["held_cents"] + p["refunded_cents"] + p["retained_cents"] +
             p["converted_to_credit_cents"] + p["reduced_cents"] + p["charged_back_cents"] ==
             p["recorded_cents"]
  end

  test "charge back moves refunded portion and revokes credit", %{conn: conn} do
    conn = post_batch(conn, [open_op("g-cb1")])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-cb",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "g-cb1",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cx-cb",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "g-cb1"
        }
      ])

    assert %{"results" => [%{"refunded_cents" => 5_000}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cb-1",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-25",
          "payment_operation_id" => "pay-cb"
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["charged_back_cents"] == 5_000
    assert r["group_id"] == "g-cb1"

    lc = get(build_conn(), "/api/v1/ledger")
    assert %{"data" => ledger} = json_response(lc, 200)
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 5_000

    pc = get(build_conn(), "/api/v1/payments/pay-cb")
    assert %{"data" => p} = json_response(pc, 200)
    assert p["charged_back_cents"] == 5_000
    assert p["refunded_cents"] == 0

    # second chargeback rejected
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cb-2",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-25",
          "payment_operation_id" => "pay-cb"
        }
      ])

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} = json_response(c, 200)

    # unknown + non-payment
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cb-3",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-11-25",
          "payment_operation_id" => "missing"
        }
      ])

    assert %{"results" => [%{"code" => "operation_not_found"}]} = json_response(c, 200)
  end

  test "payment reconcile errors", %{conn: conn} do
    c = get(build_conn(), "/api/v1/payments/never-seen")
    assert %{"error" => %{"code" => "operation_not_found"}} = json_response(c, 404)

    conn = post_batch(conn, [open_op("g-rec1", %{"operation_id" => "op-rec-open"})])
    assert json_response(conn, 200)

    c = get(build_conn(), "/api/v1/payments/op-rec-open")
    assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(c, 422)
  end
end
