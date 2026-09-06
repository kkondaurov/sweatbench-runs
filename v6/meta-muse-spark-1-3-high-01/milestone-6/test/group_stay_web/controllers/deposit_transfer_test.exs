defmodule GroupStayWeb.DepositTransferTest do
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

  test "transfer moves cash, preserves provenance, revisions, and statement", %{conn: conn} do
    conn =
      post_batch(conn, [open_op("t-src"), open_op("t-dst", %{"operation_id" => "op-open-t-dst"})])

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-t",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "t-src",
          "amount_cents" => 10_000
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "xfer-1",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-05",
          "source_group_id" => "t-src",
          "destination_group_id" => "t-dst",
          "amount_cents" => 4_000
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["source_group_id"] == "t-src"
    assert r["destination_group_id"] == "t-dst"
    assert r["amount_cents"] == 4_000
    assert r["source_revision"] == 3
    assert r["destination_revision"] == 2
    assert r["source_outstanding_deposit_cents"] == 13_500
    assert r["destination_outstanding_deposit_cents"] == 15_500

    c = get(build_conn(), "/api/v1/groups/t-src")
    assert %{"data" => src} = json_response(c, 200)
    assert src["deposit_paid_cents"] == 6_000
    assert src["revision"] == 3

    c = get(build_conn(), "/api/v1/groups/t-dst")
    assert %{"data" => dst} = json_response(c, 200)
    assert dst["deposit_paid_cents"] == 4_000
    assert dst["revision"] == 2

    # ledger unchanged by transfer
    lc = get(build_conn(), "/api/v1/ledger")
    assert %{"data" => ledger} = json_response(lc, 200)
    assert ledger["cash_held_cents"] == 10_000

    # payment statement gains held_by_group
    pc = get(build_conn(), "/api/v1/payments/pay-t")
    assert %{"data" => p} = json_response(pc, 200)
    assert p["held_cents"] == 10_000

    assert p["held_by_group"] == [
             %{"group_id" => "t-dst", "amount_cents" => 4_000},
             %{"group_id" => "t-src", "amount_cents" => 6_000}
           ]

    # idempotent retry
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "xfer-1",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-05",
          "source_group_id" => "t-src",
          "destination_group_id" => "t-dst",
          "amount_cents" => 4_000
        }
      ])

    assert %{"results" => [r2]} = json_response(c, 200)
    assert r2 == r

    c = get(build_conn(), "/api/v1/groups/t-src")
    assert %{"data" => %{"revision" => 3}} = json_response(c, 200)
  end

  test "transfer validations and revision guards", %{conn: conn} do
    conn =
      post_batch(conn, [
        open_op("v-src"),
        open_op("v-dst", %{"operation_id" => "op-open-v-dst"}),
        open_op("v-other", %{"operation_id" => "op-open-v-other", "guest_id" => "guest-99"})
      ])

    assert json_response(conn, 200)

    bad = fn op_id, body ->
      post_batch(build_conn(), [Map.put(body, "operation_id", op_id)])
    end

    # same group
    c =
      bad.("v1", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-src",
        "amount_cents" => 100
      })

    assert %{"results" => [%{"code" => "invalid_transfer"}]} = json_response(c, 200)

    # different guests
    c =
      bad.("v2", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-other",
        "amount_cents" => 100
      })

    assert %{"results" => [%{"code" => "invalid_transfer"}]} = json_response(c, 200)

    # missing destination
    c =
      bad.("v3", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "nope",
        "amount_cents" => 100
      })

    assert %{"results" => [%{"code" => "group_not_found", "group_id" => "nope"}]} =
             json_response(c, 200)

    # invalid amount
    c =
      bad.("v4", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-dst",
        "amount_cents" => 0
      })

    assert %{"results" => [%{"code" => "invalid_amount"}]} = json_response(c, 200)

    # exceeds held (nothing funded)
    c =
      bad.("v5", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-dst",
        "amount_cents" => 100
      })

    assert %{"results" => [%{"code" => "transfer_exceeds_held_funding"}]} = json_response(c, 200)

    # fund source fully (19500) and destination fully so outstanding is 0
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "v-pay-src",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "v-src",
          "amount_cents" => 19_500
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "v-pay-dst",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "v-dst",
          "amount_cents" => 19_500
        }
      ])

    assert json_response(c, 200)

    c =
      bad.("v6", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-dst",
        "amount_cents" => 100
      })

    assert %{"results" => [%{"code" => "transfer_exceeds_outstanding"}]} = json_response(c, 200)

    # stale source revision
    c =
      bad.("v7", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-dst",
        "amount_cents" => 100,
        "expected_revision" => 1
      })

    assert %{"results" => [%{"code" => "stale_revision", "group_id" => "v-src"}]} =
             json_response(c, 200)

    # stale destination revision
    c =
      bad.("v8", %{
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "v-src",
        "destination_group_id" => "v-dst",
        "amount_cents" => 100,
        "destination_expected_revision" => 1
      })

    assert %{"results" => [%{"code" => "stale_revision", "group_id" => "v-dst"}]} =
             json_response(c, 200)
  end

  test "transferred cash settles under destination policy; reduction follows it", %{conn: conn} do
    conn =
      post_batch(conn, [open_op("s-src"), open_op("s-dst", %{"operation_id" => "op-open-s-dst"})])

    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-s",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "s-src",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "xfer-s",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-05",
          "source_group_id" => "s-src",
          "destination_group_id" => "s-dst",
          "amount_cents" => 5_000
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    # refundable cancel of destination refunds transferred cash
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cx-s-dst",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "s-dst"
        }
      ])

    assert %{"results" => [%{"refunded_cents" => 5_000}]} = json_response(c, 200)

    pc = get(build_conn(), "/api/v1/payments/pay-s")
    assert %{"data" => p} = json_response(pc, 200)
    assert p["held_cents"] == 0
    assert p["refunded_cents"] == 5_000
    assert p["held_by_group"] == []

    # non-refundable destination settlement retains transferred cash there
    c =
      post_batch(build_conn(), [
        open_op("n-src", %{"operation_id" => "op-n-src"}),
        open_op("n-dst", %{"operation_id" => "op-n-dst"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-n",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "n-src",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "xfer-n",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-05",
          "source_group_id" => "n-src",
          "destination_group_id" => "n-dst",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    # late cancel of destination: non-refundable, retains transferred cash
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cx-n-dst",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "n-dst"
        }
      ])

    assert %{"results" => [%{"retained_cents" => 5_000, "refunded_cents" => 0}]} =
             json_response(c, 200)

    pc = get(build_conn(), "/api/v1/payments/pay-n")
    assert %{"data" => pn} = json_response(pc, 200)
    assert pn["held_cents"] == 0
    assert pn["retained_cents"] == 5_000

    # fresh transfer then reduce from original payment group
    c =
      post_batch(build_conn(), [
        open_op("r-src", %{"operation_id" => "op-r-src"}),
        open_op("r-dst", %{"operation_id" => "op-r-dst"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-r",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "r-src",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "xfer-r",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-05",
          "source_group_id" => "r-src",
          "destination_group_id" => "r-dst",
          "amount_cents" => 2_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "red-r",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-06",
          "payment_operation_id" => "pay-r",
          "amount_cents" => 3_000
        }
      ])

    assert %{"results" => [rr]} = json_response(c, 200)
    assert rr["status"] == "applied"
    assert rr["group_id"] == "r-src"

    pc = get(build_conn(), "/api/v1/payments/pay-r")
    assert %{"data" => pr} = json_response(pc, 200)
    assert pr["held_cents"] == 2_000
    assert pr["reduced_cents"] == 3_000
    assert pr["held_cents"] + pr["reduced_cents"] == pr["recorded_cents"]
  end

  # build a credit lot for guest-22 via cash -> hotel_credit cancel
  test "transferred credit restores to original lot on refundable cancel", %{conn: _conn} do
    c = post_batch(build_conn(), [open_op("c-src0", %{"operation_id" => "op-c-src0"})])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-c0",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "c-src0",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cx-c0",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "c-src0",
          "refund_method" => "hotel_credit"
        }
      ])

    assert %{"results" => [%{"credit_issued_cents" => 5_500}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        open_op("c-a", %{"operation_id" => "op-c-a"}),
        open_op("c-b", %{"operation_id" => "op-c-b"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "apply-c",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-05",
          "group_id" => "c-a",
          "amount_cents" => 2_000
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "xfer-c",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-06",
          "source_group_id" => "c-a",
          "destination_group_id" => "c-b",
          "amount_cents" => 2_000
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "cx-c-b",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "c-b"
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c = get(build_conn(), "/api/v1/guests/guest-22/credit", %{on: "2026-11-21"})
    assert %{"data" => cd} = json_response(c, 200)
    # 5500 - 2000 applied + 2000 restored = 5500
    assert cd["available_cents"] == 5_500
  end
end
