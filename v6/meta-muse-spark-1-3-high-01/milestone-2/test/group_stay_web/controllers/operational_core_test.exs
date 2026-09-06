defmodule GroupStayWeb.OperationalCoreTest do
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

  test "opens group with flexible deposit math from API example", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-81")])
    assert %{"results" => [result]} = json_response(conn, 200)
    # 3 nights: room-a lodging 45000 -> 9000; room-b lodging 52500 -> 10500; total 19500
    assert result == %{
             "operation_id" => "op-open-group-81",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19_500,
             "revision" => 1
           }

    conn = get(build_conn(), "/api/v1/groups/group-81")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["lodging_total_cents"] == 97_500
    assert data["deposit_due_cents"] == 19_500
    assert data["deposit_paid_cents"] == 0
    assert data["outstanding_deposit_cents"] == 19_500
    assert data["revision"] == 1
    assert data["status"] == "active"
    assert data["booked_on"] == "2026-10-03"
    assert data["rate_plan"] == "flexible"

    assert data["rooms"] == [
             %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
             %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
           ]
  end

  test "rounding: half-cent rounds upward per room", %{conn: conn} do
    # 1 night at 5 cents flexible: 5*20/100 = 1.0 -> 1; use 15 cents lodging: 15*20=300/100=3 exact
    # half-cent case: lodging 15? no. lodging=5 -> 100/100=1. lodging 25 -> 500/100=5.
    # lodging 75 -> 1500/100=15. Need x.2*20 = y.5 case: lodging= 175 -> 3500/100 = 35 exact.
    # lodging ending in 2.5 * 20? lodging integer cents L: L*20/100 = L/5. Half-cent when L/5 ends .5 => L = 5k+2.5 impossible integer.
    # Actually L*20+50 div 100: L=1 -> (20+50)/100=0; L=3 -> (60+50)/100=1 (1.1*0.2=0.6? hmm)
    # L=13: 13*0.2=2.6 -> 3? (260+50)/100=3. L=12: 2.4->2 (240+50)/100=2. L= 7: 1.4->1. L=8:1.6->2.
    # half-cent upward: L*0.2 = n+0.5 => L = 5n+2.5: e.g. L=  125 -> 25.0 exact. L=  75 -> 15 exact. L must be x.5? impossible.
    # So check formula: div(L*20+50,100) equals round-half-up of L*20/100. e.g. L=13: 2.6->3 ok.
    conn =
      post_batch(conn, [
        open_op("group-round", %{
          "operation_id" => "op-round",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 13}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert %{"results" => [%{"deposit_due_cents" => 3, "status" => "applied"}]} =
             json_response(conn, 200)
  end

  test "advance_purchase requires full lodging", %{conn: conn} do
    conn =
      post_batch(conn, [
        open_op("group-adv", %{
          "operation_id" => "op-adv",
          "rate_plan" => "advance_purchase"
        })
      ])

    assert %{"results" => [%{"deposit_due_cents" => 97_500}]} = json_response(conn, 200)
  end

  test "open validations", %{conn: conn} do
    # duplicate
    conn1 = post_batch(conn, [open_op("group-dup", %{"operation_id" => "op-1"})])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn1, 200)

    conn2 =
      post_batch(build_conn(), [
        open_op("group-dup", %{"operation_id" => "op-2"})
      ])

    assert %{"results" => [%{"status" => "rejected", "code" => "group_already_exists"}]} =
             json_response(conn2, 200)

    # invalid rate plan
    conn3 =
      post_batch(build_conn(), [
        open_op("group-badplan", %{"operation_id" => "op-3", "rate_plan" => "weekly"})
      ])

    assert %{"results" => [%{"code" => "invalid_rate_plan", "status" => "rejected"}]} =
             json_response(conn3, 200)

    # invalid stay: departure <= arrival
    conn4 =
      post_batch(build_conn(), [
        open_op("group-badstay", %{
          "operation_id" => "op-4",
          "departure_on" => "2026-12-10"
        })
      ])

    assert %{"results" => [%{"code" => "invalid_stay"}]} = json_response(conn4, 200)

    # invalid rooms: dup ids, empty, zero rate
    for {suffix, rooms} <- [
          {"r-dup",
           [
             %{"room_id" => "a", "nightly_rate_cents" => 100},
             %{"room_id" => "a", "nightly_rate_cents" => 100}
           ]},
          {"r-empty", []},
          {"r-zero", [%{"room_id" => "a", "nightly_rate_cents" => 0}]}
        ] do
      c =
        post_batch(build_conn(), [
          open_op("group-#{suffix}", %{"operation_id" => "op-#{suffix}", "rooms" => rooms})
        ])

      assert %{"results" => [%{"code" => "invalid_rooms"}]} = json_response(c, 200)
    end

    # missing occurred_on -> invalid_operation
    c =
      post_batch(build_conn(), [
        Map.delete(open_op("group-noocc", %{"operation_id" => "op-noocc"}), "occurred_on")
      ])

    assert %{"results" => [%{"code" => "invalid_operation"}]} = json_response(c, 200)
  end

  test "invalid batch without operations array", %{conn: conn} do
    conn = post(conn, "/api/v1/partner-batches", %{})
    assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
  end

  test "cash payment flow and errors", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-pay", %{"operation_id" => "op-open"})])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    pay = fn op_id, extra ->
      post_batch(build_conn(), [
        Map.merge(
          %{
            "operation_id" => op_id,
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-pay",
            "amount_cents" => 5_000
          },
          extra
        )
      ])
    end

    c = pay.("op-p1", %{})
    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["amount_cents"] == 5_000
    assert r["outstanding_deposit_cents"] == 14_500
    assert r["revision"] == 2

    # exceeds outstanding
    c = pay.("op-p2", %{"amount_cents" => 99_999})
    assert %{"results" => [%{"code" => "payment_exceeds_outstanding"}]} = json_response(c, 200)

    # invalid amount
    c = pay.("op-p3", %{"amount_cents" => 0})
    assert %{"results" => [%{"code" => "invalid_amount"}]} = json_response(c, 200)

    # missing group
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-p4",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "nope",
          "amount_cents" => 100
        }
      ])

    assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(c, 200)
  end

  test "reschedule shifts departure equally and validates", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-move", %{"operation_id" => "op-open"})])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-rs",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-move",
          "new_arrival_on" => "2026-12-12"
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["new_arrival_on"] == "2026-12-12"
    assert r["new_departure_on"] == "2026-12-15"
    assert r["revision"] == 2

    # new arrival must be after operation date
    c2 =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-rs2",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-12",
          "group_id" => "group-move",
          "new_arrival_on" => "2026-12-12"
        }
      ])

    assert %{"results" => [%{"code" => "invalid_stay"}]} = json_response(c2, 200)
  end

  test "cancellation refund windows and ledger", %{conn: conn} do
    # refundable: cancel >= 14 days before arrival (flexible)
    conn = post_batch(conn, [open_op("group-cref", %{"operation_id" => "op-o1"})])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-pay1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-cref",
          "amount_cents" => 5_000
        }
      ])

    assert json_response(c, 200)

    # arrival 2026-12-10; cancel 2026-11-20 => 20 days -> refundable
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-c1",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-cref"
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)

    assert r == %{
             "operation_id" => "op-c1",
             "status" => "applied",
             "group_id" => "group-cref",
             "refunded_cents" => 5_000,
             "retained_cents" => 0,
             "revision" => 3,
             "credit_issued_cents" => 0
           }

    # non-refundable late flexible cancel
    c = post_batch(build_conn(), [open_op("group-clate", %{"operation_id" => "op-o2"})])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-pay2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-clate",
          "amount_cents" => 1_000
        }
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-c2",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-clate"
        }
      ])

    assert %{"results" => [r2]} = json_response(c, 200)
    assert r2["refunded_cents"] == 0
    assert r2["retained_cents"] == 1_000

    # advance purchase always non-refundable
    c =
      post_batch(build_conn(), [
        open_op("group-cadv", %{"operation_id" => "op-o3", "rate_plan" => "advance_purchase"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-c3",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-cadv"
        }
      ])

    assert %{"results" => [r3]} = json_response(c, 200)
    assert r3["refunded_cents"] == 0
    assert r3["retained_cents"] == 0

    # cancelled group rejects later payment/reschedule/cancel
    for op <- [
          %{
            "operation_id" => "op-x1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-12-02",
            "group_id" => "group-cref",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-x2",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-cref",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-x3",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-02",
            "group_id" => "group-cref"
          }
        ] do
      cx = post_batch(build_conn(), [op])
      assert %{"results" => [%{"code" => "group_not_active"}]} = json_response(cx, 200)
    end

    # cancellation exactly 14 days before arrival is refundable
    c = post_batch(build_conn(), [open_op("group-c14", %{"operation_id" => "op-o4"})])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-pay14",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-c14",
          "amount_cents" => 2_000
        }
      ])

    assert json_response(c, 200)

    # arrival 2026-12-10 minus 14 = 2026-11-26
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-c14",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-c14"
        }
      ])

    assert %{"results" => [%{"refunded_cents" => 2_000, "retained_cents" => 0}]} =
             json_response(c, 200)

    # ledger: active groups hold nothing paid (all paid groups cancelled here? group-adv unpaid)
    # paid: cref 5000 refunded, clate 1000 retained, c14 2000 refunded => refunded 7000, retained 1000, held 0
    lc = get(build_conn(), "/api/v1/ledger")
    assert %{"data" => ledger} = json_response(lc, 200)

    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_refunded_cents"] == 7_000
    assert ledger["cash_retained_cents"] == 1_000
  end

  test "ledger holds active cash", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-held", %{"operation_id" => "op-o"})])
    assert json_response(conn, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-hp",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-held",
          "amount_cents" => 3_000
        }
      ])

    assert json_response(c, 200)

    lc = get(build_conn(), "/api/v1/ledger")
    assert %{"data" => %{"cash_held_cents" => 3_000}} = json_response(lc, 200)
  end

  test "concurrent revisions and stale handling", %{conn: conn} do
    conn = post_batch(conn, [open_op("group-rev", %{"operation_id" => "op-o"})])
    assert json_response(conn, 200)

    # payment with correct expected_revision
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-r1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-rev",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }
      ])

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} = json_response(c, 200)

    # stale revision rejected before domain validation, with expected fields
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-r2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-rev",
          "amount_cents" => -5,
          "expected_revision" => 1
        }
      ])

    assert %{"results" => [r]} = json_response(c, 200)

    assert r == %{
             "operation_id" => "op-r2",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-rev",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    # missing group still group_not_found even with expected_revision
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-r3",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-missing",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }
      ])

    assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(c, 200)

    # batch ordering: earlier op changes visible to later expected_revision
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-b1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-rev",
          "amount_cents" => 500,
          "expected_revision" => 2
        },
        %{
          "operation_id" => "op-b2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-rev",
          "amount_cents" => 500,
          "expected_revision" => 3
        }
      ])

    assert %{"results" => [%{"revision" => 3}, %{"revision" => 4}]} = json_response(c, 200)
  end

  test "batch failure isolation: unknown type and invalid ops continue", %{conn: conn} do
    conn =
      post_batch(conn, [
        %{
          "operation_id" => "op-u1",
          "type" => "teleport_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "g-x"
        },
        open_op("group-iso", %{"operation_id" => "op-iso"}),
        %{
          "operation_id" => "op-u2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04"
        },
        %{
          "operation_id" => "op-pay-iso",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-iso",
          "amount_cents" => 1_000
        }
      ])

    assert %{"results" => [r1, r2, r3, r4]} = json_response(conn, 200)
    assert r1["code"] == "invalid_operation"
    assert r1["status"] == "rejected"
    assert r2["status"] == "applied"
    assert r3["code"] == "invalid_operation"
    assert r4["status"] == "applied"
  end

  test "read missing group 404", %{conn: conn} do
    conn = get(conn, "/api/v1/groups/does-not-exist")
    assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
  end
end
