defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post_batch_raw(conn, %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a non-list operations field", %{conn: conn} do
      conn = post_batch_raw(conn, %{operations: %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "returns an empty result list for an empty batch", %{conn: conn} do
      conn = post_batch(conn, [])
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "accepts a map body from ConnTest without JSON encoding", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{operations: [example_open()]})

      assert %{"results" => [%{"status" => "applied", "group_id" => "group-81"}]} =
               json_response(conn, 200)
    end

    test "opens a flexible group using the documented example", %{conn: conn} do
      conn = post_batch(conn, [example_open()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 1,
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
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             }
    end

    test "requires the full lodging amount as deposit for advance_purchase", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"})
        ])

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

    test "rounds each flexible room deposit separately half-up", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "r1", "nightly_rate_cents" => 3},
              %{"room_id" => "r2", "nightly_rate_cents" => 3}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 2}
               ]
             } = json_response(conn, 200)
    end

    test "rejects an existing group identifier", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          example_open(%{"operation_id" => "op-dup"})
        ])

      assert [
               %{"status" => "applied", "operation_id" => "op-1001"},
               %{
                 "status" => "rejected",
                 "operation_id" => "op-dup",
                 "code" => "group_already_exists"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a stay shorter than one night", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-same-day",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          })
        ])

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-same-day")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "rejects inverted stay dates", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-inverted",
            "arrival_on" => "2026-12-13",
            "departure_on" => "2026-12-10"
          })
        ])

      assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects empty, duplicate, or malformed rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g-empty", "rooms" => []}),
          example_open(%{
            "group_id" => "g-dup",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 200}
            ]
          }),
          example_open(%{
            "group_id" => "g-neg",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]
          })
        ])

      assert [
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rooms"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      conn = post_batch(conn, [example_open(%{"group_id" => "g-plan", "rate_plan" => "nonref"})])

      assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] =
               json_response(conn, 200)["results"]
    end

    test "records cash against an active group's outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 5000
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 5000
      assert data["cash_paid_cents"] == 5000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 14_500
      assert data["revision"] == 2
    end

    test "rejects a payment that exceeds the outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19_501
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 0
      assert data["revision"] == 1
    end

    test "rejects an unusable payment amount", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-zero",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "op-neg",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => -10
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"code" => "invalid_amount"},
               %{"code" => "invalid_amount"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects payment, reschedule, cancel, and credit for a missing group", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "p",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "r",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "c",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing"
          },
          %{
            "operation_id" => "h",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100
          }
        ])

      assert [
               %{"code" => "group_not_found"},
               %{"code" => "group_not_found"},
               %{"code" => "group_not_found"},
               %{"code" => "group_not_found"}
             ] = json_response(conn, 200)["results"]
    end

    test "reschedules an active group by the same number of nights", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 2,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-06"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["arrival_on"] == "2026-12-20"
      assert data["departure_on"] == "2026-12-23"
      assert data["deposit_due_cents"] == 19_500
    end

    test "rejects a reschedule whose arrival is not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-same",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-20",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "rejected", "code" => "invalid_stay"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["arrival_on"] == "2026-12-10"
    end

    test "refunds a flexible group cancelled at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 8000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["outstanding_deposit_cents"] == 0
    end

    test "retains cash when a flexible group is cancelled fewer than 14 days out", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 8000,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]
    end

    test "never refunds an advance_purchase cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"}),
          cash_payment("op-pay", "group-ap", 20_000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 20_000, "credit_issued_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects later operations against a cancelled group", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          cash_payment("op-pay", "group-81", 100),
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
          %{
            "operation_id" => "op-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 100
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0},
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"},
               %{"code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end

    test "returns group_not_found before comparing a stale revision", %{conn: conn} do
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

      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]
    end

    test "rejects a stale revision before other domain rules", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 100),
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 99_999,
            "expected_revision" => 1
          }
        ])

      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 100
      assert data["revision"] == 2
    end

    test "applies an operation when expected_revision matches the current revision", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          example_open(),
          Map.put(cash_payment("op-pay", "group-81", 100), "expected_revision", 1)
        ])

      assert [
               %{"revision" => 1},
               %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 19_400}
             ] = json_response(conn, 200)["results"]
    end

    test "uses the rescheduled arrival when deciding cancellation refundability", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 8000),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-11-01"
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-20",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "new_arrival_on" => "2026-11-01"},
               %{"refunded_cents" => 0, "retained_cents" => 8000}
             ] = json_response(conn, 200)["results"]
    end

    test "leaves the group unchanged when a cancel is stale", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 1000),
          %{
            "operation_id" => "op-stale-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "expected_revision" => 1
          }
        ])

      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"code" => "stale_revision", "actual_revision" => 2}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 1000

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 1000
    end

    test "accepts a payment that equals the outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 19_500)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "continues the batch after an unknown or incomplete operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "explode_group"},
          %{"operation_id" => "op-incomplete", "type" => "record_cash_payment"},
          example_open()
        ])

      assert [
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
               %{"operation_id" => "op-1001", "status" => "applied", "group_id" => "group-81"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns 404 for an unknown group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero and tracks held, refunded, and retained cash", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }

      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "held"}),
          cash_payment("pay-held", "held", 4000),
          example_open(%{"group_id" => "refund"}),
          cash_payment("pay-refund", "refund", 2500),
          %{
            "operation_id" => "cancel-refund",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "refund"
          },
          example_open(%{"group_id" => "retain", "rate_plan" => "advance_purchase"}),
          cash_payment("pay-retain", "retain", 3000),
          %{
            "operation_id" => "cancel-retain",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "retain"
          }
        ])

      assert conn.status == 200

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 4000,
                 "cash_refunded_cents" => 2500,
                 "cash_retained_cents" => 3000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "does not treat unpaid deposit as cash", %{conn: conn} do
      conn = post_batch(conn, [example_open()])
      assert conn.status == 200

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end
  end

  describe "policy versions" do
    test "assigns flex-30 for flexible groups booked on or after 2027-01-01", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-flex30",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-flex30")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-02-13"
    end

    test "keeps flex-14 for flexible groups booked before 2027-01-01", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"occurred_on" => "2026-12-31", "group_id" => "group-flex14"})
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-flex14")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end

    test "marks advance-purchase groups as advance-nonrefundable", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase",
            "occurred_on" => "2027-06-01"
          })
        ])

      conn = get(conn, "/api/v1/groups/group-ap")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "does not change policy version when rescheduling into a newer window", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"occurred_on" => "2026-12-31"}),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-02",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-03-20"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-06",
                 "new_arrival_on" => "2027-03-20",
                 "new_departure_on" => "2027-03-23"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-03-06"
    end

    test "refunds a flex-30 group cancelled on refundable_until", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-flex30",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment("op-pay", "group-flex30", 4000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-13",
            "group_id" => "group-flex30"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 4000, "retained_cents" => 0, "credit_issued_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end

    test "retains a flex-30 group cancelled after refundable_until", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-flex30",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-18"
          }),
          cash_payment("op-pay", "group-flex30", 4000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-14",
            "group_id" => "group-flex30"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 4000, "credit_issued_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end

    test "implies policy from booked_on when policy_version is missing", %{conn: conn} do
      conn = post_batch(conn, [example_open()])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      group = GroupStay.Groups.get_group("group-81")

      group
      |> Ecto.Changeset.change(%{policy_version: nil})
      |> GroupStay.Repo.update!()

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end
  end

  describe "hotel credit" do
    test "converts refundable cash into a 110% credit lot", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 5500,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["status"] == "cancelled"

      conn = get(conn, "/api/v1/guests/guest-22/credit")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 5500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-10-04"
                   }
                 ]
               }
             }

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "rounds the 10% credit bonus half-up", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-round"}),
          cash_payment("op-pay", "group-round", 15),
          %{
            "operation_id" => "cancel-round",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-round",
            "refund_method" => "hotel_credit"
          }
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"credit_issued_cents" => 17}] =
               json_response(conn, 200)["results"]
    end

    test "rejects hotel credit for a non-refundable cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "rejected", "code" => "refund_method_not_available"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 8000

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 8000
    end

    test "rejects hotel credit for advance purchase", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"}),
          cash_payment("op-pay", "group-ap", 1000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap",
            "refund_method" => "hotel_credit"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "refund_method_not_available"}
             ] = json_response(conn, 200)["results"]
    end

    test "checks stale revision before refund_method_not_available", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"}),
          cash_payment("op-pay", "group-ap", 1000),
          %{
            "operation_id" => "op-stale",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-ap",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          }
        ])

      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"code" => "stale_revision", "actual_revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "applies hotel credit to an active group", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          %{
            "operation_id" => "op-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-82",
            "amount_cents" => 2000
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"credit_issued_cents" => 5500},
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "applied",
                 "group_id" => "group-82",
                 "amount_cents" => 2000,
                 "outstanding_deposit_cents" => 17_500,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-82")
      data = json_response(conn, 200)["data"]
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 2000
      assert data["deposit_paid_cents"] == 2000

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 3500
      assert hd(credit["lots"])["remaining_cents"] == 3500

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_converted_to_credit_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5500
    end

    test "rejects apply_hotel_credit that exceeds outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          %{
            "operation_id" => "op-over",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-82",
            "amount_cents" => 19_501
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "payment_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects apply_hotel_credit when the guest cannot cover the amount", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-82"}),
          %{
            "operation_id" => "op-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-82",
            "amount_cents" => 100
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "rejected", "code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-82")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "checks stale revision before insufficient_credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "group-82"}),
          cash_payment("op-pay", "group-82", 100),
          %{
            "operation_id" => "op-stale",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-82",
            "amount_cents" => 100,
            "expected_revision" => 1
          }
        ])

      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"code" => "stale_revision", "actual_revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "consumes lots by earliest expiry then source_operation_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 1000),
          %{
            "operation_id" => "cancel-b",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-10",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          cash_payment("pay-2", "g2", 1000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-10",
            "group_id" => "g2",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-3", "group_id" => "g3"}),
          cash_payment("pay-3", "g3", 1000),
          %{
            "operation_id" => "cancel-c",
            "type" => "cancel_group",
            "occurred_on" => "2026-09-01",
            "group_id" => "g3",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-4", "group_id" => "g4"}),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-11",
            "group_id" => "g4",
            "amount_cents" => 1600
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      lots = json_response(conn, 200)["data"]["lots"]

      assert lots == [
               %{
                 "source_operation_id" => "cancel-a",
                 "remaining_cents" => 600,
                 "expires_on" => "2027-10-10"
               },
               %{
                 "source_operation_id" => "cancel-b",
                 "remaining_cents" => 1100,
                 "expires_on" => "2027-10-10"
               }
             ]
    end

    test "restores applied credit to original lots on refundable cash cancellation", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 2000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          cash_payment("pay-2", "g2", 500),
          %{
            "operation_id" => "cancel-g2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "g2",
            "refund_method" => "cash"
          }
        ])

      results = json_response(conn, 200)["results"]

      assert %{
               "refunded_cents" => 500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = List.last(results)

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 2200
      assert hd(credit["lots"])["remaining_cents"] == 2200
      assert hd(credit["lots"])["expires_on"] == "2027-10-04"
      assert hd(credit["lots"])["source_operation_id"] == "cancel-17"

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_refunded_cents"] == 500
      assert ledger["cash_converted_to_credit_cents"] == 2000
      assert ledger["credit_liability_cents"] == 2200
    end

    test "issues a new lot for cash and restores prior credit without a second bonus", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 2000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          cash_payment("pay-2", "g2", 500),
          %{
            "operation_id" => "cancel-g2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "g2",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 550
             } = List.last(json_response(conn, 200)["results"])

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 2750

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-10-04"
               },
               %{
                 "source_operation_id" => "cancel-g2",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-10-06"
               }
             ]
    end

    test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 2000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{
            "operation_id" => "open-2",
            "group_id" => "g2",
            "arrival_on" => "2026-10-20",
            "departure_on" => "2026-10-22"
          }),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          cash_payment("pay-2", "g2", 500),
          %{
            "operation_id" => "cancel-g2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-10",
            "group_id" => "g2"
          }
        ])

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 500,
               "credit_issued_cents" => 0
             } = List.last(json_response(conn, 200)["results"])

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 1400

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_retained_cents"] == 500
      assert ledger["credit_liability_cents"] == 1400
    end

    test "expires restored credit immediately when the original lot is past expiry", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 2000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{
            "operation_id" => "open-2",
            "group_id" => "g2",
            "arrival_on" => "2028-01-01",
            "departure_on" => "2028-01-04"
          }),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          %{
            "operation_id" => "cancel-g2",
            "type" => "cancel_group",
            "occurred_on" => "2027-10-05",
            "group_id" => "g2"
          }
        ])

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0
             } = List.last(json_response(conn, 200)["results"])

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 1400

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 1400
    end

    test "evaluates lot expiry using the operation occurred_on date", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 1000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          %{
            "operation_id" => "apply-late",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-10-05",
            "group_id" => "g2",
            "amount_cents" => 100
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["code"] == "insufficient_credit"
    end

    test "omits expired and exhausted lots from guest credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 1000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          }
        ])

      assert conn.status == 200

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-10-05")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      conn = get(conn, "/api/v1/ledger?on=2027-10-05")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-10-04")
      assert json_response(conn, 200)["data"]["available_cents"] == 1100
    end

    test "keeps applied credit in liability after the lot's calendar expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-1", "g1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 2000
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/ledger?on=2027-10-05")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 2000

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-10-05")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2027-10-04")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 5500
    end

    test "returns empty credit for a guest with no lots", %{conn: conn} do
      conn = get(conn, "/api/v1/guests/guest-unknown/credit")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "guest_id" => "guest-unknown",
                 "available_cents" => 0,
                 "lots" => []
               }
             }
    end

    test "rejects an unusable apply_hotel_credit amount", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-zero",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          }
        ])

      assert [%{"status" => "applied"}, %{"code" => "invalid_amount"}] =
               json_response(conn, 200)["results"]
    end
  end

  describe "deposit rounding" do
    test "rounds an exact half-cent upward" do
      assert GroupStay.Groups.round_percent(25, 50) == 13
      assert GroupStay.Groups.round_percent(1, 50) == 1
      assert GroupStay.Groups.round_percent(10003, 20) == 2001
      assert GroupStay.Groups.round_percent(10002, 20) == 2000
    end
  end

  defp post_batch(conn, operations) do
    post_batch_raw(conn, %{operations: operations})
  end

  defp post_batch_raw(conn, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp example_open(overrides \\ %{}) do
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

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
