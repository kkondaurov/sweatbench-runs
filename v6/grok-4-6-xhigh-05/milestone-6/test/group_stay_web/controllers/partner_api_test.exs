defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/v1/partner-batches" do
    test "opens a flexible group and returns the deposit due", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "charges advance-purchase rooms the full lodging amount", %{conn: conn} do
      op = open_group_op(%{"rate_plan" => "advance_purchase", "group_id" => "group-ap"})
      conn = post_batch(conn, [op])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "deposit_due_cents" => 97_500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately, half-cents up", %{conn: conn} do
      op =
        open_group_op(%{
          "group_id" => "group-round",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3}
          ]
        })

      conn = post_batch(conn, [op])

      assert %{"results" => [%{"status" => "applied", "deposit_due_cents" => 2}]} =
               json_response(conn, 200)
    end

    test "rejects a duplicate group identifier without changing the original", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), open_group_op(%{"operation_id" => "op-1002"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-1002",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1, "status" => "active"}} = json_response(conn, 200)
    end

    test "rejects invalid stays, rooms, and rate plans without creating a group", %{conn: conn} do
      ops = [
        open_group_op(%{
          "operation_id" => "bad-stay",
          "group_id" => "g-stay",
          "departure_on" => "2026-12-10"
        }),
        open_group_op(%{
          "operation_id" => "bad-rooms",
          "group_id" => "g-rooms",
          "rooms" => [
            %{"room_id" => "dup", "nightly_rate_cents" => 100},
            %{"room_id" => "dup", "nightly_rate_cents" => 200}
          ]
        }),
        open_group_op(%{
          "operation_id" => "no-rooms",
          "group_id" => "g-empty",
          "rooms" => []
        }),
        open_group_op(%{
          "operation_id" => "bad-plan",
          "group_id" => "g-plan",
          "rate_plan" => "nonrefundable"
        })
      ]

      conn = post_batch(conn, ops)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "bad-stay",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{
                   "operation_id" => "bad-rooms",
                   "status" => "rejected",
                   "code" => "invalid_rooms"
                 },
                 %{
                   "operation_id" => "no-rooms",
                   "status" => "rejected",
                   "code" => "invalid_rooms"
                 },
                 %{
                   "operation_id" => "bad-plan",
                   "status" => "rejected",
                   "code" => "invalid_rate_plan"
                 }
               ]
             } = json_response(conn, 200)

      Enum.each(["g-stay", "g-rooms", "g-empty", "g-plan"], fn group_id ->
        conn = get(conn, "/api/v1/groups/#{group_id}")
        assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
      end)
    end

    test "records cash against an active group's outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unusable or excessive payments", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "zero",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19_501
          },
          %{
            "operation_id" => "missing-group",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "no-such",
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"operation_id" => "zero", "status" => "rejected", "code" => "invalid_amount"},
                 %{
                   "operation_id" => "over",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{
                   "operation_id" => "missing-group",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} = json_response(conn, 200)
    end

    test "reschedules an active group by the same number of days", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-15"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-15",
                   "new_departure_on" => "2026-12-18",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-15",
                 "departure_on" => "2026-12-18",
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500
               }
             } = json_response(conn, 200)
    end

    test "rejects a reschedule that is not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-15",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-15"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "invalid_stay"}
               ]
             } = json_response(conn, 200)
    end

    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(19_500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 19_500,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19_500,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "retains cash when a flexible group is cancelled fewer than 14 days out", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 8000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)
    end

    test "never refunds an advance-purchase cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"rate_plan" => "advance_purchase", "group_id" => "group-ap"}),
          payment_op(97_500, "group-ap"),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 97_500}
               ]
             } = json_response(conn, 200)
    end

    test "rejects later operations against a cancelled group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          payment_op(100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0},
                 %{"status" => "rejected", "code" => "group_not_active"},
                 %{"status" => "rejected", "code" => "group_not_active"},
                 %{"status" => "rejected", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 50_000,
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "stale-pay",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"deposit_paid_cents" => 1000, "revision" => 2}} =
               json_response(conn, 200)
    end

    test "returns group_not_found before comparing revisions", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "missing",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "ghost",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "missing",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "applies when expected_revision matches the current group revision", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          Map.put(payment_op(500), "expected_revision", 1)
        ])

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 19_000}
               ]
             } = json_response(conn, 200)
    end

    test "rejects unknown types and incomplete operations, then continues", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "unknown", "type" => "explode_group", "group_id" => "x"},
          %{"operation_id" => "incomplete", "type" => "cancel_group"},
          open_group_op()
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "incomplete",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{"operation_id" => "op-1001", "status" => "applied", "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "returns 422 when the body has no operations array", %{conn: conn} do
      conn = post_json(conn, ~p"/api/v1/partner-batches", %{})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

      conn = post_json(conn, ~p"/api/v1/partner-batches", %{operations: %{}})
      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "an empty operations list is a valid batch", %{conn: conn} do
      conn = post_batch(conn, [])
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "accepts a payment that clears the outstanding deposit", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(19_500)])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2}
               ]
             } = json_response(conn, 200)
    end

    test "ignores expected_revision when opening a group", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(%{"expected_revision" => 9})])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group with rooms in original order and deposit totals", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(4500)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 2,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 4500,
                 "outstanding_deposit_cents" => 15_000,
                 "cash_paid_cents" => 4500,
                 "credit_paid_cents" => 0,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             } = json_response(conn, 200)
    end

    test "returns 404 for an unknown group", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/groups/missing")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end

    test "shows a cancelled group with no outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero and tracks held, refunded, and retained cash", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(4000),
          open_group_op(%{"group_id" => "group-82", "operation_id" => "op-open-2"}),
          payment_op(2500, "group-82")
        ])

      assert %{"results" => [_, %{"status" => "applied"}, _, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")
      assert %{"data" => %{"cash_held_cents" => 6500}} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-late",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => [%{"status" => "applied", "retained_cents" => 4000}]} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 2500,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 4000
               }
             } = json_response(conn, 200)
    end

    test "does not treat unpaid deposit as cash", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end
  end

  describe "policy versions" do
    test "assigns flex-14 and refundable_until for flexible groups booked before 2027-01-01", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "assigns flex-30 for flexible groups booked on or after 2027-01-01", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-15",
            "departure_on" => "2027-06-18"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-05-16"
               }
             } = json_response(conn, 200)
    end

    test "advance-purchase groups are advance-nonrefundable with null refundable_until", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "rate_plan" => "advance_purchase",
            "group_id" => "group-ap",
            "occurred_on" => "2027-03-01"
          })
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-ap")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = json_response(conn, 200)
    end

    test "legacy groups without a stored policy receive the version implied by booked_on", %{
      conn: conn
    } do
      insert_legacy_group(%{
        group_id: "legacy-flex",
        booked_on: ~D[2026-06-01],
        arrival_on: ~D[2026-12-20],
        departure_on: ~D[2026-12-22],
        rate_plan: "flexible"
      })

      insert_legacy_group(%{
        group_id: "legacy-30",
        booked_on: ~D[2027-02-01],
        arrival_on: ~D[2027-08-10],
        departure_on: ~D[2027-08-12],
        rate_plan: "flexible"
      })

      insert_legacy_group(%{
        group_id: "legacy-ap",
        booked_on: ~D[2026-06-01],
        arrival_on: ~D[2026-12-20],
        departure_on: ~D[2026-12-22],
        rate_plan: "advance_purchase"
      })

      conn = get(conn, ~p"/api/v1/groups/legacy-flex")

      assert %{"data" => %{"policy_version" => "flex-14", "refundable_until" => "2026-12-06"}} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/legacy-30")

      assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-07-11"}} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/legacy-ap")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = json_response(conn, 200)
    end

    test "flex-30 is refundable on the 30th day before arrival and not the day after", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-15",
            "departure_on" => "2027-06-18"
          }),
          payment_op(19_500),
          cancel_op("group-81", "2027-05-16")
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 19_500, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "open-late",
            "group_id" => "group-82",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-15",
            "departure_on" => "2027-06-18"
          }),
          payment_op(8000, "group-82"),
          cancel_op("group-82", "2027-05-17")
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 8000}
               ]
             } = json_response(conn, 200)
    end

    test "reschedule keeps the original policy and recomputes refundable_until", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2028-03-01"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "status" => "applied",
                   "new_arrival_on" => "2028-03-01",
                   "new_departure_on" => "2028-03-04",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2028-02-16",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2028-02-16"
               }
             } = json_response(conn, 200)
    end
  end

  describe "hotel credit cancellation" do
    test "converts refundable cash into a 110% credit lot and ledger conversion", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "cancel-17",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 5500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 5500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "rounds the 10% credit bonus half-cents upward", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5),
          cancel_op("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 6}
               ]
             } = json_response(conn, 200)
    end

    test "omitting refund_method refunds cash and issues no credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 5000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects hotel credit on a non-refundable cancellation and leaves the group active", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(8000),
          cancel_op("group-81", "2026-11-27", %{"refund_method" => "hotel_credit"})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "revision" => 2},
                 %{
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"status" => "active", "revision" => 2, "deposit_paid_cents" => 8000}} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 8000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "rejects hotel credit for advance-purchase even when far from arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"rate_plan" => "advance_purchase", "group_id" => "group-ap"}),
          payment_op(1000, "group-ap"),
          cancel_op("group-ap", "2026-10-04", %{"refund_method" => "hotel_credit"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "rejected", "code" => "refund_method_not_available"}
               ]
             } = json_response(conn, 200)
    end

    test "checks stale revision before refund_method_not_available", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(8000),
          cancel_op("group-81", "2026-11-27", %{
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          })
        ])

      assert %{
               "results" => [
                 _,
                 %{"revision" => 2},
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end
  end

  describe "apply_hotel_credit" do
    test "redeems unexpired credit into an active deposit without changing liability", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(2000, "group-82")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 5500},
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "status" => "applied",
                   "group_id" => "group-82",
                   "amount_cents" => 2000,
                   "outstanding_deposit_cents" => 17_500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 2000,
                 "deposit_paid_cents" => 2000,
                 "outstanding_deposit_cents" => 17_500
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 3500,
                 "lots" => [%{"remaining_cents" => 3500, "source_operation_id" => "cancel-17"}]
               }
             } = json_response(conn, 200)
    end

    test "consumes lots by earliest expiry then source_operation_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"group_id" => "g-early", "operation_id" => "open-early"}),
          payment_op(1000, "g-early"),
          cancel_op("g-early", "2026-10-10", %{
            "operation_id" => "cancel-b",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"group_id" => "g-same", "operation_id" => "open-same"}),
          payment_op(1000, "g-same"),
          cancel_op("g-same", "2026-10-20", %{
            "operation_id" => "cancel-z",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"group_id" => "g-same-2", "operation_id" => "open-same-2"}),
          payment_op(1000, "g-same-2"),
          cancel_op("g-same-2", "2026-10-20", %{
            "operation_id" => "cancel-a",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"group_id" => "g-use", "operation_id" => "open-use"}),
          apply_credit_op(1500, "g-use", "2026-10-21")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 1800,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 700,
                     "expires_on" => "2027-10-20"
                   },
                   %{
                     "source_operation_id" => "cancel-z",
                     "remaining_cents" => 1100,
                     "expires_on" => "2027-10-20"
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "rejects unusable amounts with existing payment codes or insufficient_credit", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          cancel_op("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(0, "group-82"),
          apply_credit_op(19_501, "group-82"),
          apply_credit_op(2000, "group-82"),
          apply_credit_op(100, "missing-group"),
          cancel_op("group-82", "2026-11-26"),
          apply_credit_op(100, "group-82")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "invalid_amount"},
                 %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
                 %{"status" => "rejected", "code" => "insufficient_credit"},
                 %{"status" => "rejected", "code" => "group_not_found"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-82")
      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 0}} = json_response(conn, 200)
    end

    test "checks stale revision before insufficient_credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"group_id" => "group-82"}),
          Map.merge(apply_credit_op(100, "group-82"), %{"expected_revision" => 9})
        ])

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-82",
                   "expected_revision" => 9,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "cannot apply another guest's credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"}),
          open_group_op(%{
            "operation_id" => "open-other",
            "group_id" => "group-other",
            "guest_id" => "guest-99"
          }),
          apply_credit_op(100, "group-other")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "insufficient_credit"}
               ]
             } = json_response(conn, 200)
    end

    test "evaluates lot expiry using the operation occurred_on date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(100, "group-82", "2027-11-27")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "insufficient_credit"}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          Map.put(
            apply_credit_op(100, "group-82", "2027-11-26"),
            "operation_id",
            "op-credit-on-expiry"
          )
        ])

      assert %{"results" => [%{"status" => "applied", "amount_cents" => 100}]} =
               json_response(conn, 200)
    end
  end

  describe "settling groups funded by credit" do
    test "refundable cash cancel restores original lots without a second bonus", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          payment_op(1000, "group-82"),
          apply_credit_op(2000, "group-82"),
          cancel_op("group-82", "2026-11-26", %{"operation_id" => "cancel-restore"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"credit_issued_cents" => 5500},
                 _,
                 _,
                 %{"status" => "applied", "revision" => 3},
                 %{
                   "status" => "applied",
                   "refunded_cents" => 1000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 5500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 1000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)
    end

    test "refundable hotel_credit cancel bonuses only the cash portion", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          payment_op(1000, "group-82"),
          apply_credit_op(2000, "group-82"),
          cancel_op("group-82", "2026-11-26", %{
            "operation_id" => "cancel-18",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 1100, "refunded_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 6600,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-11-26"
                   },
                   %{
                     "source_operation_id" => "cancel-18",
                     "remaining_cents" => 1100,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "restored credit that has already expired reduces liability and is not available", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{
            "operation_id" => "open-2",
            "group_id" => "group-82",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2028-01-15",
            "departure_on" => "2028-01-18"
          }),
          apply_credit_op(5500, "group-82", "2027-01-02"),
          cancel_op("group-82", "2027-11-27", %{"operation_id" => "cancel-late"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied", "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-11-27")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger?on=2027-11-27")
      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          payment_op(1000, "group-82"),
          apply_credit_op(2000, "group-82"),
          cancel_op("group-82", "2026-12-01", %{"operation_id" => "cancel-late"})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 1000,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 3500,
                 "lots" => [%{"remaining_cents" => 3500}]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_retained_cents" => 1000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 3500
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/guests/:guest_id/credit and ledger as-of dates" do
    test "omits expired and exhausted lots and orders remaining lots", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"group_id" => "g1", "operation_id" => "o1"}),
          payment_op(1000, "g1"),
          cancel_op("g1", "2026-10-01", %{
            "operation_id" => "cancel-b",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"group_id" => "g2", "operation_id" => "o2"}),
          payment_op(2000, "g2"),
          cancel_op("g2", "2026-09-01", %{
            "operation_id" => "cancel-a",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-09-01")

      assert %{
               "data" => %{
                 "available_cents" => 3300,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 2200,
                     "expires_on" => "2027-09-01"
                   },
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 1100,
                     "expires_on" => "2027-10-01"
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-09-02")

      assert %{
               "data" => %{
                 "available_cents" => 1100,
                 "lots" => [%{"source_operation_id" => "cancel-b", "remaining_cents" => 1100}]
               }
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger?on=2027-09-02")
      assert %{"data" => %{"credit_liability_cents" => 1100}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/unknown/credit")

      assert %{"data" => %{"guest_id" => "unknown", "available_cents" => 0, "lots" => []}} =
               json_response(conn, 200)
    end

    test "applied credit stays in liability after the original lot would have expired", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(5500, "group-82")
        ])

      assert %{"results" => [_, _, _, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit?on=2027-11-27")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger?on=2027-11-27")
      assert %{"data" => %{"credit_liability_cents" => 5500}} = json_response(conn, 200)
    end

    test "default as-of date is the current UTC date", %{conn: conn} do
      today = Date.utc_today()
      cancel_on = Date.add(today, -365) |> Date.to_iso8601()
      expired_on = Date.add(today, -366) |> Date.to_iso8601()

      conn =
        post_batch(conn, [
          open_group_op(%{
            "group_id" => "g-today",
            "operation_id" => "open-today",
            "occurred_on" => "2026-01-01",
            "arrival_on" => Date.add(today, 400) |> Date.to_iso8601(),
            "departure_on" => Date.add(today, 403) |> Date.to_iso8601()
          }),
          payment_op(1000, "g-today"),
          cancel_op("g-today", cancel_on, %{
            "operation_id" => "cancel-today",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{
            "group_id" => "g-old",
            "operation_id" => "open-old",
            "occurred_on" => "2026-01-01",
            "arrival_on" => Date.add(today, 400) |> Date.to_iso8601(),
            "departure_on" => Date.add(today, 403) |> Date.to_iso8601()
          }),
          payment_op(1000, "g-old"),
          cancel_op("g-old", expired_on, %{
            "operation_id" => "cancel-old",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 1100,
                 "lots" => [%{"source_operation_id" => "cancel-today"}]
               }
             } = json_response(conn, 200)
    end
  end

  describe "durable operations" do
    test "replays an equivalent retry without applying domain changes again", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), payment_op(5000)])
      original = json_response(conn, 200)

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19_500},
                 %{
                   "status" => "applied",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               ]
             } = original

      conn = post_batch(conn, [open_group_op(), payment_op(5000)])
      assert json_response(conn, 200) == original

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "deposit_paid_cents" => 5000,
                 "cash_paid_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "treats JSON object key order as insignificant and array order as significant", %{
      conn: conn
    } do
      first =
        ~s({"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"room_id":"room-b","nightly_rate_cents":17500}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2026-10-03","type":"open_group","operation_id":"op-1001"}]})

      second =
        ~s({"operations":[{"operation_id":"op-1001","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]})

      conn = post_raw(conn, ~p"/api/v1/partner-batches", first)

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)

      conn = post_raw(conn, ~p"/api/v1/partner-batches", second)

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)

      reversed_rooms =
        open_group_op(%{
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        })

      conn = post_batch(conn, [reversed_rooms])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a"},
                   %{"room_id" => "room-b"}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "replays a remembered rejection even if it would now succeed", %{conn: conn} do
      pay = payment_op(1000)

      conn = post_batch(conn, [pay])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "group_not_found"}]
             } = json_response(conn, 200)

      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [pay])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "group_not_found"}]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} = json_response(conn, 200)
    end

    test "rejects a reused identifier with a different payload without replacing the record", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_group_op()])
      original = hd(json_response(conn, 200)["results"])

      conn =
        post_batch(conn, [
          open_group_op(%{"group_id" => "group-other", "guest_id" => "guest-99"})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/operations/op-1001")
      assert %{"data" => ^original} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "active", "revision" => 1}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-other")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end

    test "returns stored stale-revision details without consulting current group state", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(1000),
          Map.merge(payment_op(500), %{
            "operation_id" => "stale-pay",
            "expected_revision" => 1
          })
        ])

      assert %{
               "results" => [
                 _,
                 %{"revision" => 2},
                 %{
                   "operation_id" => "stale-pay",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [payment_op(2000)])

      assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          Map.merge(payment_op(500), %{
            "operation_id" => "stale-pay",
            "expected_revision" => 1
          })
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "stale-pay",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          Map.merge(payment_op(500), %{
            "operation_id" => "stale-pay",
            "expected_revision" => 3
          })
        ])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"deposit_paid_cents" => 3000, "revision" => 3}} =
               json_response(conn, 200)
    end

    test "replays cancel and credit application without repeating their effects", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(2000, "group-82")
        ])

      original = json_response(conn, 200)
      assert Enum.all?(original["results"], &(&1["status"] == "applied"))

      conn =
        post_batch(conn, [
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          apply_credit_op(2000, "group-82")
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "credit_issued_cents" => 5500, "revision" => 3},
                 %{"status" => "applied", "amount_cents" => 2000, "revision" => 2}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 3500}} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-82")

      assert %{"data" => %{"credit_paid_cents" => 2000, "revision" => 2}} =
               json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)
    end

    test "GET /api/v1/operations/:operation_id returns the stored result", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      result = hd(json_response(conn, 200)["results"])

      conn = get(conn, ~p"/api/v1/operations/op-1001")
      assert json_response(conn, 200) == %{"data" => result}

      conn = post_batch(conn, [payment_op(0)])
      rejected = hd(json_response(conn, 200)["results"])
      pay_id = rejected["operation_id"]

      conn = get(conn, ~p"/api/v1/operations/#{pay_id}")
      assert %{"data" => ^rejected} = json_response(conn, 200)
    end

    test "GET /api/v1/operations/:operation_id returns 404 when unknown", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/operations/missing")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "retains type, submitted content, and first-commit order", %{conn: conn} do
      conn =
        post_batch(conn, [
          payment_op(1000),
          open_group_op()
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "group_not_found"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      recorded =
        GroupStay.Groups.Operation
        |> GroupStay.Repo.all()
        |> Enum.sort_by(& &1.id)

      assert Enum.map(recorded, & &1.operation_id) == [
               "op-pay-1000-group-81",
               "op-1001"
             ]

      [rejected, applied] = recorded
      assert rejected.operation_type == "record_cash_payment"
      assert rejected.payload["amount_cents"] == 1000
      assert rejected.payload["group_id"] == "group-81"
      assert applied.operation_type == "open_group"

      assert applied.payload["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ]
    end

    test "continues the batch after an operation_id_conflict", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{"group_id" => "group-other"}),
          open_group_op(%{"operation_id" => "op-1002", "group_id" => "group-82"})
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "operation_id_conflict"},
                 %{"status" => "applied", "group_id" => "group-82", "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "replays an equivalent retry of a reschedule including dates", %{conn: conn} do
      move = %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-15"
      }

      conn = post_batch(conn, [open_group_op(), move])
      original = json_response(conn, 200)["results"] |> List.last()

      conn = post_batch(conn, [move])
      assert hd(json_response(conn, 200)["results"]) == original

      conn = get(conn, ~p"/api/v1/operations/op-move")
      assert %{"data" => ^original} = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"arrival_on" => "2026-12-15", "revision" => 2}} =
               json_response(conn, 200)
    end

    test "same-batch duplicate operation_id replays the first result", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), open_group_op()])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19_500},
                 %{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19_500}
               ]
             } = json_response(conn, 200)

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1}} = json_response(conn, 200)
    end
  end

  defp open_group_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1001",
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

  defp payment_op(amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => "op-pay-#{amount_cents}-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on, extras \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extras
    )
  end

  defp apply_credit_op(amount_cents, group_id, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => "op-credit-#{amount_cents}-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp insert_legacy_group(attrs) do
    GroupStay.Repo.insert!(%GroupStay.Groups.Group{
      group_id: attrs.group_id,
      guest_id: "guest-legacy",
      property_id: "ams-canal",
      booked_on: attrs.booked_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      status: "active",
      revision: 1,
      policy_version: nil,
      lodging_total_cents: 10_000,
      deposit_due_cents: 2000,
      deposit_paid_cents: 0,
      outstanding_deposit_cents: 2000,
      refunded_cents: 0,
      retained_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      cash_converted_to_credit_cents: 0
    })
  end

  defp post_batch(conn, operations) do
    post_json(conn, ~p"/api/v1/partner-batches", %{operations: operations})
  end

  defp post_json(conn, path, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp post_raw(conn, path, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, body)
  end
end
