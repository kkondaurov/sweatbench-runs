defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "opens a flexible group and returns the deposit", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "calculates advance-purchase deposit as full lodging", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-ap",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 97500, "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately then sums", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-round",
            "group_id" => "group-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 1003},
              %{"room_id" => "room-b", "nightly_rate_cents" => 1003}
            ]
          })
        ])

      assert %{"results" => [%{"status" => "applied", "deposit_due_cents" => 402}]} =
               json_response(conn, 200)
    end

    test "rejects a duplicate group identifier", %{conn: conn} do
      conn = post_batch(conn, [open_group_op(), open_group_op(%{"operation_id" => "op-dup"})])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-dup",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects a stay with no nights", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-stay",
            "group_id" => "group-stay",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects departure before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-stay2",
            "group_id" => "group-stay2",
            "arrival_on" => "2026-12-13",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects empty or duplicate rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-empty",
            "group_id" => "group-empty",
            "rooms" => []
          }),
          open_group_op(%{
            "operation_id" => "op-dup-rooms",
            "group_id" => "group-dup-rooms",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-plan",
            "group_id" => "group-plan",
            "rate_plan" => "nonrefundable"
          })
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rate_plan"}]} =
               json_response(conn, 200)
    end

    test "does not create a group when open_group is rejected", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-bad",
            "group_id" => "group-bad",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [%{"status" => "rejected"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-bad")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end

    test "records cash against an outstanding deposit", %{conn: conn} do
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
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects payments that are missing, inactive, unusable, or too large", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-missing",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing-group",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-zero",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "op-over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19501
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"code" => "group_not_found"},
                 %{"code" => "invalid_amount"},
                 %{"code" => "payment_exceeds_outstanding"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500
               }
             } =
               json_response(conn, 200)
    end

    test "reschedules an active group by the same number of days", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-06",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "revision" => 2
               }
             } = json_response(conn, 200)
    end

    test "rejects a reschedule whose arrival is not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move-bad",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-20",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert %{"results" => [_, %{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 19500),
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
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 19500,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)
    end

    test "retains cash for a flexible group cancelled fewer than 14 days before arrival", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 8000,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)
    end

    test "uses the current arrival when deciding a flexible refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 19500),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-01-20"
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-12",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 19500, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "never refunds an advance-purchase cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-open",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          }),
          cash_payment_op("op-pay", 10000, "group-ap"),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 10000,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects later mutations on a cancelled group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          cash_payment_op("op-pay", 100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          apply_credit_op("op-credit", 100)
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "revision" => 2},
                 %{"code" => "group_not_active"},
                 %{"code" => "group_not_active"},
                 %{"code" => "group_not_active"},
                 %{"code" => "group_not_active"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 2,
                 "outstanding_deposit_cents" => 0
               }
             } =
               json_response(conn, 200)
    end

    test "increments revision once per applied mutation and ignores expected_revision on open", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(%{"expected_revision" => 99}),
          cash_payment_op("op-pay", 100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-11"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{"status" => "applied", "revision" => 3}
               ]
             } = json_response(conn, 200)
    end

    test "resolves a missing group before comparing revisions", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100,
            "expected_revision" => 1
          }
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_group_op(), cash_payment_op("op-pay", 5000)])
      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-stale",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "revision" => 2,
                 "deposit_paid_cents" => 5000,
                 "outstanding_deposit_cents" => 14500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 5000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               json_response(conn, 200)
    end

    test "sees earlier operations in the same batch when checking expected_revision", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          Map.put(cash_payment_op("op-pay", 100), "expected_revision", 1),
          Map.put(cash_payment_op("op-pay-2", 100), "expected_revision", 1)
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unknown types and incomplete operations without stopping the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          %{
            "operation_id" => "op-incomplete",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-03"
          },
          open_group_op()
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "op-incomplete",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{"operation_id" => "op-1001", "status" => "applied"}
               ]
             } = json_response(conn, 200)
    end

    test "returns 422 when the body has no operations array", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/partner-batches", Jason.encode!(%{not_operations: []}))

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "accepts an empty operations list", %{conn: conn} do
      conn = post_batch(conn, [])
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "accepts params posted as maps", %{conn: conn} do
      conn =
        conn
        |> recycle()
        |> post(~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_op(%{"operation_id" => "op-map", "group_id" => "group-map"})
          ]
        })

      assert %{
               "results" => [%{"status" => "applied", "group_id" => "group-map", "revision" => 1}]
             } =
               json_response(conn, 200)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns partner identifiers, rooms in order, and deposit totals", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
            ]
          }),
          cash_payment_op("op-pay", 4500)
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

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
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 4500,
                 "cash_paid_cents" => 4500,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 15000
               }
             } = json_response(conn, 200)
    end

    test "returns 404 for an unknown group", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/groups/missing")
      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero and tracks held, refunded, and retained cash", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(),
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("op-pay-1", 5000),
          cash_payment_op("op-pay-2", 3000, "group-82"),
          %{
            "operation_id" => "op-cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-09",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 5000,
                 "cash_retained_cents" => 3000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "does not treat unpaid deposit as cash", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)
    end
  end

  describe "policy versions" do
    test "assigns flex-14 before 2027-01-01 and flex-30 on or after", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-flex14",
            "group_id" => "group-flex14",
            "occurred_on" => "2026-12-31"
          }),
          open_group_op(%{
            "operation_id" => "op-flex30",
            "group_id" => "group-flex30",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          open_group_op(%{
            "operation_id" => "op-ap",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          })
        ])

      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-flex14")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-flex30")

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-02-13"
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-ap")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = json_response(conn, 200)
    end

    test "keeps the original policy version when a group is rescheduled", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-06-01"
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-05-18"
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          cash_payment_op("op-pay", 19500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-10",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{"status" => "applied", "refunded_cents" => 19500, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "uses a 30-day window for flex-30 groups", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment_op("op-pay", 19500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-13",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 19500, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment_op("op-pay-2", 8000, "group-82"),
          %{
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-14",
            "group_id" => "group-82"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 8000}
               ]
             } = json_response(conn, 200)
    end

    test "derives policy for groups stored without a policy_version", %{conn: conn} do
      {:ok, group} =
        %GroupStay.Groups.Group{}
        |> GroupStay.Groups.Group.changeset(%{
          group_id: "group-legacy",
          guest_id: "guest-22",
          property_id: "ams-canal",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          status: "active",
          revision: 1,
          lodging_total_cents: 97500,
          deposit_due_cents: 19500,
          deposit_paid_cents: 0
        })
        |> Ecto.Changeset.put_assoc(:rooms, [
          %GroupStay.Groups.Room{room_id: "room-a", nightly_rate_cents: 15000, position: 0}
        ])
        |> GroupStay.Repo.insert()

      assert group.policy_version == nil

      conn = get_json(conn, ~p"/api/v1/groups/group-legacy")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             } = json_response(conn, 200)
    end
  end

  describe "hotel credit" do
    test "issues 110% credit for a refundable hotel_credit cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 5500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 5500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2028-05-02"
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "rounds the 10% bonus with the standard half-cent-up rule", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5),
          %{
            "operation_id" => "cancel-bonus",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => [_, _, %{"credit_issued_cents" => 6}]} = json_response(conn, 200)
    end

    test "omitting refund_method refunds cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "refunded_cents" => 5000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects hotel_credit on a non-refundable cancellation and leaves the group active", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "revision" => 2,
                 "deposit_paid_cents" => 8000,
                 "cash_paid_cents" => 8000
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 8000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "rejects hotel_credit for advance-purchase groups", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-open",
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase"
          }),
          cash_payment_op("op-pay", 10000, "group-ap"),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => [_, _, %{"code" => "refund_method_not_available"}]} =
               json_response(conn, 200)
    end

    test "applies unexpired credit to an active group's outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-credit", 2000, "group-82")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 5500},
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-credit",
                   "status" => "applied",
                   "group_id" => "group-82",
                   "amount_cents" => 2000,
                   "outstanding_deposit_cents" => 17500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 2000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 2000,
                 "outstanding_deposit_cents" => 17500,
                 "revision" => 2
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 3500,
                 "lots" => [%{"remaining_cents" => 3500, "source_operation_id" => "cancel-17"}]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)
    end

    test "rejects credit that exceeds outstanding or available balance", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-over", 19501, "group-82"),
          apply_credit_op("op-short", 5501, "group-82"),
          apply_credit_op("op-zero", 0, "group-82")
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"status" => "applied", "revision" => 1},
                 %{"code" => "payment_exceeds_outstanding"},
                 %{"code" => "insufficient_credit"},
                 %{"code" => "invalid_amount"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0, "credit_paid_cents" => 0}} =
               json_response(conn, 200)
    end

    test "consumes lots by earliest expiry then source_operation_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-a", "group_id" => "group-a"}),
          cash_payment_op("pay-a", 1000, "group-a"),
          %{
            "operation_id" => "cancel-b",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-a",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-b", "group_id" => "group-b"}),
          cash_payment_op("pay-b", 2000, "group-b"),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-b",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-c", "group_id" => "group-c"}),
          cash_payment_op("pay-c", 3000, "group-c"),
          %{
            "operation_id" => "cancel-c",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-c",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-d", "group_id" => "group-d"}),
          apply_credit_op("op-apply", 4000, "group-d")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 2600,
                 "lots" => [
                   %{"source_operation_id" => "cancel-a", "remaining_cents" => 1500},
                   %{"source_operation_id" => "cancel-b", "remaining_cents" => 1100}
                 ]
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-d",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-03",
            "group_id" => "group-d"
          }
        ])

      assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 0}]} =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 6600,
                 "lots" => [
                   %{"source_operation_id" => "cancel-c", "remaining_cents" => 3300},
                   %{"source_operation_id" => "cancel-a", "remaining_cents" => 2200},
                   %{"source_operation_id" => "cancel-b", "remaining_cents" => 1100}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "does not let one guest spend another guest's credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-other",
            "guest_id" => "guest-99"
          }),
          apply_credit_op("op-credit", 1000, "group-other")
        ])

      assert %{"results" => [_, _, _, _, %{"code" => "insufficient_credit"}]} =
               json_response(conn, 200)
    end

    test "counts only cash as cash_held when a group is also funded by credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("op-pay-2", 3000, "group-82"),
          apply_credit_op("op-credit", 2000, "group-82")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 3000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-82")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 3000,
                 "credit_paid_cents" => 2000,
                 "deposit_paid_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "restores applied credit to original lots without a second bonus", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("op-pay-2", 3000, "group-82"),
          apply_credit_op("op-credit", 2000, "group-82"),
          %{
            "operation_id" => "cancel-18",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-82",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"credit_issued_cents" => 5500},
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 3300
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{
               "data" => %{
                 "available_cents" => 8800,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-11-01"
                   },
                   %{
                     "source_operation_id" => "cancel-18",
                     "remaining_cents" => 3300,
                     "expires_on" => "2027-11-02"
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 8000,
                 "credit_liability_cents" => 8800
               }
             } = json_response(conn, 200)
    end

    test "refunds cash and restores credit on a refundable cash cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("op-pay-2", 3000, "group-82"),
          apply_credit_op("op-credit", 2000, "group-82"),
          %{
            "operation_id" => "cancel-18",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-02",
            "group_id" => "group-82",
            "refund_method" => "cash"
          }
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
                   "refunded_cents" => 3000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 3000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)
    end

    test "retains cash and consumes applied credit on a non-refundable cancellation", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          cash_payment_op("op-pay-2", 3000, "group-82"),
          apply_credit_op("op-credit", 2000, "group-82"),
          %{
            "operation_id" => "cancel-18",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-09",
            "group_id" => "group-82"
          }
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
                   "refunded_cents" => 0,
                   "retained_cents" => 3000,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{"data" => %{"available_cents" => 3500}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_retained_cents" => 3000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 3500
               }
             } = json_response(conn, 200)
    end

    test "expires restored credit immediately when the original lot is already past", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          apply_credit_op("op-credit", 5500, "group-82"),
          %{
            "operation_id" => "cancel-18",
            "type" => "cancel_group",
            "occurred_on" => "2027-11-02",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "pauses expiry while credit funds an active group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          apply_credit_op("op-credit", 2000, "group-82")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, "/api/v1/guests/guest-22/credit?on=2027-11-02")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get_json(conn, "/api/v1/ledger?on=2027-11-02")

      assert %{"data" => %{"credit_liability_cents" => 2000}} = json_response(conn, 200)
    end

    test "evaluates credit expiry using occurred_on when applying", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          Map.put(apply_credit_op("op-credit", 1000, "group-82"), "occurred_on", "2027-11-02")
        ])

      assert %{"results" => [_, _, _, _, %{"code" => "insufficient_credit"}]} =
               json_response(conn, 200)
    end

    test "reports expiry as of on= and defaults to the current UTC date", %{conn: conn} do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      tomorrow = Date.add(today, 1)

      conn =
        post_batch(conn, [
          open_group_op(%{
            "arrival_on" => Date.to_iso8601(Date.add(today, 60)),
            "departure_on" => Date.to_iso8601(Date.add(today, 63))
          }),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-today",
            "type" => "cancel_group",
            "occurred_on" => Date.to_iso8601(Date.add(today, -365)),
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, "/api/v1/guests/guest-22/credit?on=#{Date.to_iso8601(yesterday)}")
      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)

      conn = get_json(conn, "/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)

      conn = get_json(conn, "/api/v1/guests/guest-22/credit?on=#{Date.to_iso8601(tomorrow)}")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get_json(conn, "/api/v1/ledger?on=#{Date.to_iso8601(tomorrow)}")
      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "checks revision before refund_method and insufficient-credit rules", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 8000)
        ])

      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-stale-method",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          %{
            "operation_id" => "op-stale-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-82",
            "amount_cents" => 100,
            "expected_revision" => 0
          }
        ])

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "active", "revision" => 2}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-82")
      assert %{"data" => %{"revision" => 1, "credit_paid_cents" => 0}} = json_response(conn, 200)
    end

    test "increments revision once when hotel credit is applied", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("op-pay", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          Map.put(apply_credit_op("op-credit", 1000, "group-82"), "expected_revision", 1)
        ])

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"revision" => 3},
                 %{"revision" => 1},
                 %{"status" => "applied", "revision" => 2}
               ]
             } = json_response(conn, 200)
    end

    test "returns empty credit for a guest with no lots", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/guests/guest-missing/credit")

      assert %{
               "data" => %{
                 "guest_id" => "guest-missing",
                 "available_cents" => 0,
                 "lots" => []
               }
             } = json_response(conn, 200)
    end
  end

  describe "durable operations" do
    test "replays an applied result without changing domain state", %{conn: conn} do
      payment = cash_payment_op("op-pay", 5000)
      conn = post_batch(conn, [open_group_op(), payment])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [payment])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "amount_cents" => 5000,
                   "outstanding_deposit_cents" => 14500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "deposit_paid_cents" => 5000,
                 "cash_paid_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "treats object key order as insignificant and array order as significant", %{conn: conn} do
      first =
        ~s({"operations":[{"type":"open_group","operation_id":"op-order","occurred_on":"2026-10-03","group_id":"group-order","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]})

      retry =
        ~s({"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"nightly_rate_cents":17500,"room_id":"room-b"}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-order","occurred_on":"2026-10-03","operation_id":"op-order","type":"open_group"}]})

      conn = post_raw_batch(conn, first)

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)

      conn = post_raw_batch(conn, retry)

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)

      swapped =
        open_group_op(%{
          "operation_id" => "op-order",
          "group_id" => "group-order",
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
          ]
        })

      conn = post_batch(conn, [swapped])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-order",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "replays a rejection even when a later operation would make it valid", %{conn: conn} do
      missing_payment = cash_payment_op("op-missing-pay", 1000, "group-later")

      conn = post_batch(conn, [missing_payment])

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "op-open-later", "group_id" => "group-later"}),
          missing_payment
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-missing-pay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-later")

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               json_response(conn, 200)
    end

    test "rejects a reused identifier with a different payload without replacing the original", %{
      conn: conn
    } do
      original = open_group_op()
      conn = post_batch(conn, [original])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)

      conn = post_batch(conn, [cash_payment_op("op-1001", 100)])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [original])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/operations/op-1001")

      assert %{
               "data" => %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "revision" => 1
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = json_response(conn, 200)
    end

    test "returns stored stale-revision details without consulting current group state", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_group_op(), cash_payment_op("op-pay", 5000)])
      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      stale = %{
        "operation_id" => "op-stale",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "expected_revision" => 1
      }

      conn = post_batch(conn, [stale])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [cash_payment_op("op-pay-2", 100)])

      assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
               json_response(conn, 200)

      conn = post_batch(conn, [stale])

      assert %{
               "results" => [
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      corrected = Map.put(stale, "expected_revision", 3)
      conn = post_batch(conn, [corrected])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "active", "revision" => 3}} = json_response(conn, 200)
    end

    test "replays the same operation twice in one batch without applying it twice", %{conn: conn} do
      payment = cash_payment_op("op-pay", 5000)

      conn = post_batch(conn, [open_group_op(), payment, payment])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 14500},
                 %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 14500}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5000}} =
               json_response(conn, 200)
    end

    test "GET returns only the stored result and 404 when missing", %{conn: conn} do
      conn = post_batch(conn, [open_group_op()])
      assert %{"results" => [result]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/operations/op-1001")
      body = json_response(conn, 200)

      assert body == %{"data" => result}
      refute Map.has_key?(body["data"], "payload")
      refute Map.has_key?(body["data"], "type")
      refute Map.has_key?(body, "payload")

      conn = get_json(conn, ~p"/api/v1/operations/missing-op")
      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "GET returns a remembered rejection", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-bad",
            "group_id" => "group-bad",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          })
        ])

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "invalid_stay"

      conn = get_json(conn, ~p"/api/v1/operations/op-bad")
      assert %{"data" => ^result} = json_response(conn, 200)
    end

    test "retains type, submitted content, and first-commit order", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          open_group_op()
        ])

      assert %{"results" => [%{"code" => "invalid_operation"}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      records = GroupStay.Operations.list_in_commit_order()
      assert Enum.map(records, & &1.operation_id) == ["op-unknown", "op-1001"]
      assert Enum.map(records, & &1.type) == ["explode_group", "open_group"]
      assert hd(records).payload["type"] == "explode_group"
      assert hd(records).payload["occurred_on"] == "2026-10-03"
      assert List.last(records).payload["group_id"] == "group-81"

      assert List.last(records).payload["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
             ]
    end

    test "replays a reschedule result including dates without moving the group again", %{
      conn: conn
    } do
      move = %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      }

      conn = post_batch(conn, [open_group_op(), move])

      assert %{
               "results" => [
                 _,
                 %{
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-06",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [move])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "refundable_until" => "2026-12-06",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/operations/op-move")

      assert %{
               "data" => %{
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 2
               }
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "revision" => 2
               }
             } = json_response(conn, 200)
    end

    test "does not reissue credit when a hotel-credit cancellation is retried", %{conn: conn} do
      cancel = %{
        "operation_id" => "cancel-17",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      }

      conn = post_batch(conn, [open_group_op(), cash_payment_op("op-pay", 5000), cancel])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "credit_issued_cents" => 5500, "revision" => 3}
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [cancel])

      assert %{
               "results" => [
                 %{"status" => "applied", "credit_issued_cents" => 5500, "revision" => 3}
               ]
             } =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/guests/guest-22/credit")
      assert %{"data" => %{"available_cents" => 5500, "lots" => [_]}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)
    end

    test "continues the batch after a handled rejection that is remembered", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          open_group_op()
        ])

      assert %{
               "results" => [
                 %{"code" => "invalid_operation"},
                 %{"status" => "applied", "group_id" => "group-81"}
               ]
             } = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/operations/op-unknown")

      assert %{"data" => %{"status" => "rejected", "code" => "invalid_operation"}} =
               json_response(conn, 200)
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp post_raw_batch(conn, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", body)
  end

  defp get_json(conn, path) do
    conn
    |> recycle()
    |> get(path)
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp cash_payment_op(operation_id, amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_op(operation_id, amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
