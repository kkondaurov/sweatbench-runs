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
                 "outstanding_deposit_cents" => 15_000
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
end
