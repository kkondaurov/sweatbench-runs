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
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "status" => "active",
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "status" => "active",
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
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
          example_open(%{"operation_id" => "op-empty", "group_id" => "g-empty", "rooms" => []}),
          example_open(%{
            "operation_id" => "op-dup-rooms",
            "group_id" => "g-dup",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 200}
            ]
          }),
          example_open(%{
            "operation_id" => "op-neg",
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }

      conn =
        post_batch(conn, [
          example_open(%{"operation_id" => "open-held", "group_id" => "held"}),
          cash_payment("pay-held", "held", 4000),
          example_open(%{"operation_id" => "open-refund", "group_id" => "refund"}),
          cash_payment("pay-refund", "refund", 2500),
          %{
            "operation_id" => "cancel-refund",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "refund"
          },
          example_open(%{
            "operation_id" => "open-retain",
            "group_id" => "retain",
            "rate_plan" => "advance_purchase"
          }),
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
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
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 5500,
               "credit_shortfall_cents" => 0
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

  describe "durable operations" do
    test "retries with an equivalent payload return the original applied result", %{conn: conn} do
      conn = post_batch(conn, [example_open()])

      first = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          example_open()
          |> Map.delete("guest_id")
          |> Map.put("guest_id", "guest-22")
        ])

      assert json_response(conn, 200)["results"] == first

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 1
      assert data["deposit_paid_cents"] == 0
    end

    test "retries do not apply domain effects a second time", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 4000)
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "outstanding_deposit_cents" => 15_500, "revision" => 2}
             ] = json_response(conn, 200)["results"]

      conn = post_batch(conn, [cash_payment("op-pay", "group-81", 4000)])

      assert [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "amount_cents" => 4000,
                 "outstanding_deposit_cents" => 15_500,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 4000
      assert data["revision"] == 2
    end

    test "JSON object key order does not change payload equivalence", %{conn: conn} do
      first =
        ~s({"operations":[{"departure_on":"2026-12-13","operation_id":"op-order","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","rate_plan":"flexible","rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"room_id":"room-b","nightly_rate_cents":17500}]}]})

      second =
        ~s({"operations":[{"type":"open_group","operation_id":"op-order","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","occurred_on":"2026-10-03","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]})

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", first)

      assert [%{"status" => "applied", "operation_id" => "op-order", "revision" => 1}] =
               json_response(conn, 200)["results"]

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", second)

      assert [%{"status" => "applied", "operation_id" => "op-order", "revision" => 1}] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "array order remains significant for payload equivalence", %{conn: conn} do
      conn = post_batch(conn, [example_open(%{"operation_id" => "op-rooms"})])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          example_open(%{
            "operation_id" => "op-rooms",
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
            ]
          })
        ])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")

      assert json_response(conn, 200)["data"]["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "remembered rejections are returned even if they would now be valid", %{conn: conn} do
      pay = cash_payment("op-pay", "group-81", 1000)
      conn = post_batch(conn, [pay])

      assert [%{"status" => "rejected", "code" => "group_not_found", "operation_id" => "op-pay"}] =
               json_response(conn, 200)["results"]

      conn = post_batch(conn, [example_open()])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = post_batch(conn, [pay])

      assert [%{"status" => "rejected", "code" => "group_not_found", "operation_id" => "op-pay"}] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 0
      assert data["revision"] == 1
    end

    test "reusing an operation_id with a different payload is a conflict", %{conn: conn} do
      conn = post_batch(conn, [example_open()])

      assert [%{"status" => "applied", "group_id" => "group-81"}] =
               json_response(conn, 200)["results"]

      conn = post_batch(conn, [example_open(%{"group_id" => "group-other"})])

      assert [
               %{
                 "operation_id" => "op-1001",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-other")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}

      conn = get(conn, "/api/v1/operations/op-1001")

      assert json_response(conn, 200)["data"] == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
    end

    test "GET returns a stored rejection and 404 for an unknown id", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "explode_group"}
        ])

      rejected = hd(json_response(conn, 200)["results"])
      assert rejected["code"] == "invalid_operation"

      conn = get(conn, "/api/v1/operations/op-unknown")
      assert json_response(conn, 200) == %{"data" => rejected}

      conn = get(conn, "/api/v1/operations/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "exact retries return the original revision details verbatim", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 100),
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 50,
            "expected_revision" => 1
          }
        ])

      stale = Enum.at(json_response(conn, 200)["results"], 2)

      assert stale == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn = post_batch(conn, [cash_payment("op-pay-2", "group-81", 25)])
      assert [%{"revision" => 3}] = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 50,
            "expected_revision" => 1
          }
        ])

      assert json_response(conn, 200)["results"] == [stale]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 3
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 125
    end

    test "correcting expected_revision under the same operation_id is a conflict", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 100),
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 50,
            "expected_revision" => 1
          }
        ])

      assert [%{"revision" => 1}, %{"revision" => 2}, %{"code" => "stale_revision"}] =
               json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 50,
            "expected_revision" => 2
          }
        ])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/operations/op-stale")
      assert json_response(conn, 200)["data"]["code"] == "stale_revision"
      assert json_response(conn, 200)["data"]["actual_revision"] == 2

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 2
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 100
    end

    test "handled rejections commit an idempotency record and continue the batch", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-bad", "type" => "explode_group"},
          example_open(%{"operation_id" => "op-open"})
        ])

      assert [
               %{
                 "operation_id" => "op-bad",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "op-open", "status" => "applied", "group_id" => "group-81"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/operations/op-bad")
      assert json_response(conn, 200)["data"]["code"] == "invalid_operation"

      conn = get(conn, "/api/v1/operations/op-open")
      assert json_response(conn, 200)["data"]["status"] == "applied"

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["group_id"] == "group-81"
    end

    test "retains type, complete payload, and first-commit order", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-a", "type" => "explode_group", "extra" => %{"n" => 1}},
          example_open(%{"operation_id" => "op-b"})
        ])

      assert conn.status == 200

      [first, second] =
        GroupStay.Groups.Operation
        |> GroupStay.Repo.all()
        |> Enum.sort_by(& &1.id)

      assert first.operation_id == "op-a"
      assert first.type == "explode_group"
      assert first.payload["type"] == "explode_group"
      assert first.payload["extra"] == %{"n" => 1}
      assert second.operation_id == "op-b"
      assert second.type == "open_group"
      assert second.id > first.id
    end

    test "unexpected exceptions abort the request and are not remembered", %{conn: conn} do
      conn =
        post_batch(conn, [example_open(%{"operation_id" => "op-ok", "group_id" => "group-ok"})])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      {status, _headers, _body} =
        assert_error_sent 500, fn ->
          post(conn, "/api/v1/partner-batches", %{
            operations: [
              %{
                "operation_id" => "op-crash",
                "type" => "explode_group",
                "bad" => {:not, :json}
              }
            ]
          })
        end

      assert status == 500

      conn = get(recycle(conn), "/api/v1/operations/op-crash")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      conn = get(conn, "/api/v1/operations/op-ok")
      assert json_response(conn, 200)["data"]["status"] == "applied"

      conn = get(conn, "/api/v1/groups/group-ok")
      assert json_response(conn, 200)["data"]["group_id"] == "group-ok"

      conn =
        post_batch(conn, [
          example_open(%{"operation_id" => "op-crash", "group_id" => "group-crash"})
        ])

      assert [%{"status" => "applied", "group_id" => "group-crash"}] =
               json_response(conn, 200)["results"]
    end

    test "same-batch duplicate identifiers replay without a second apply", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          example_open()
        ])

      assert [
               %{"status" => "applied", "revision" => 1, "group_id" => "group-81"},
               %{"status" => "applied", "revision" => 1, "group_id" => "group-81"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end
  end

  describe "room accounting" do
    test "allocates cash to rooms in original order", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000)
        ])

      assert conn.status == 200

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]

      assert data["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 5000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ]
    end

    test "new funding follows operation order across cash and credit", %{conn: conn} do
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
          },
          cash_payment("pay-2", "g2", 8000)
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/groups/g2")
      rooms = json_response(conn, 200)["data"]["rooms"]

      assert Enum.at(rooms, 0)["credit_paid_cents"] == 2000
      assert Enum.at(rooms, 0)["cash_paid_cents"] == 7000
      assert Enum.at(rooms, 1)["cash_paid_cents"] == 1000
      assert Enum.at(rooms, 1)["credit_paid_cents"] == 0
    end

    test "brings pre-durable funding forward as a senior unattributed block", %{conn: conn} do
      conn = post_batch(conn, [example_open()])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      group = GroupStay.Groups.get_group("group-81")

      group
      |> Ecto.Changeset.change(%{
        cash_paid_cents: 4000,
        deposit_paid_cents: 4000,
        outstanding_deposit_cents: 15_500
      })
      |> GroupStay.Repo.update!()

      GroupStay.Groups.backfill_group_accounting!(GroupStay.Groups.get_group("group-81"))

      conn =
        post_batch(conn, [
          cash_payment("op-pay", "group-81", 6000)
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      rooms = json_response(conn, 200)["data"]["rooms"]

      assert Enum.at(rooms, 0)["cash_paid_cents"] == 9000
      assert Enum.at(rooms, 1)["cash_paid_cents"] == 1000

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200)["data"]["held_cents"] == 6000
    end
  end

  describe "cancel_rooms" do
    test "settles selected rooms and leaves others unchanged", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 19_500),
          %{
            "operation_id" => "op-cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 9000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 3
      assert data["lodging_total_cents"] == 52_500
      assert data["deposit_due_cents"] == 10_500
      assert data["cash_paid_cents"] == 10_500
      assert data["outstanding_deposit_cents"] == 0
      assert Enum.at(data["rooms"], 0)["status"] == "cancelled"
      assert Enum.at(data["rooms"], 0)["cash_paid_cents"] == 0
      assert Enum.at(data["rooms"], 1)["status"] == "active"
      assert Enum.at(data["rooms"], 1)["cash_paid_cents"] == 10_500

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 10_500
      assert ledger["cash_refunded_cents"] == 9000
    end

    test "returns cancelled_room_ids in original room order", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-b", "room-a"]
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "cancelled_room_ids" => ["room-a", "room-b"],
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["status"] == "cancelled"
    end

    test "computes hotel-credit bonus once on combined selected cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{
            "group_id" => "group-bonus",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "r1", "nightly_rate_cents" => 75},
              %{"room_id" => "r2", "nightly_rate_cents" => 75}
            ]
          }),
          cash_payment("op-pay", "group-bonus", 30),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-bonus",
            "room_ids" => ["r1", "r2"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"credit_issued_cents" => 33, "refunded_cents" => 0, "retained_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects invalid room selections without changing state", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 1000),
          %{
            "operation_id" => "op-missing",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-z"]
          },
          %{
            "operation_id" => "op-dup",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-a"]
          },
          %{
            "operation_id" => "op-empty",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => []
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rooms"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["status"] == "active"
      assert data["cash_paid_cents"] == 1000
    end

    test "cancel_group settles only remaining active rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 19_500),
          %{
            "operation_id" => "op-cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "op-cancel-rest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 9000, "revision" => 3},
               %{"refunded_cents" => 10_500, "retained_cents" => 0, "revision" => 4}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["lodging_total_cents"] == 0
      assert data["deposit_due_cents"] == 0
      assert data["cash_paid_cents"] == 0
    end

    test "checks stale revision before invalid_rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 100),
          %{
            "operation_id" => "op-stale",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["missing"],
            "expected_revision" => 1
          }
        ])

      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{"code" => "stale_revision", "actual_revision" => 2}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash in reverse fill order and reopens outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 19_500),
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "payment_operation_id" => "op-pay",
                 "group_id" => "group-81",
                 "amount_cents" => 2000,
                 "outstanding_deposit_cents" => 2000,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert Enum.at(data["rooms"], 0)["cash_paid_cents"] == 9000
      assert Enum.at(data["rooms"], 1)["cash_paid_cents"] == 8500
      assert data["cash_paid_cents"] == 17_500
      assert data["outstanding_deposit_cents"] == 2000

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 19_500,
               "held_cents" => 17_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2000,
               "charged_back_cents" => 0
             }

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 17_500
      assert ledger["cash_reduced_cents"] == 2000
    end

    test "composes successive reductions against remaining held cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          %{
            "operation_id" => "op-reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "op-reduce-2",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 3000
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"amount_cents" => 2000, "outstanding_deposit_cents" => 16_500},
               %{"amount_cents" => 3000, "outstanding_deposit_cents" => 19_500, "revision" => 4}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/payments/op-pay")
      statement = json_response(conn, 200)["data"]
      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 5000
    end

    test "rejects reductions that cannot succeed", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 1000),
          %{
            "operation_id" => "op-missing",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "no-such",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-not-pay",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-1001",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-zero",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "op-over",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1001
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "operation_not_found"},
               %{"code" => "payment_not_reducible"},
               %{"code" => "invalid_amount"},
               %{"code" => "reduction_exceeds_held_cash"}
             ] = json_response(conn, 200)["results"]
    end

    test "does not rewrite the original payment result", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 4000),
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          },
          cash_payment("op-pay", "group-81", 4000)
        ])

      results = json_response(conn, 200)["results"]

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-pay",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 4000,
               "outstanding_deposit_cents" => 15_500,
               "revision" => 2
             }

      assert Enum.at(results, 3) == Enum.at(results, 1)

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 3000
    end

    test "cannot reduce settled cash or legacy funding", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 4000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 100
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "payment_not_reducible"}
             ] = json_response(conn, 200)["results"]
    end

    test "checks stale revision before payment_not_reducible", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 1000),
          %{
            "operation_id" => "op-stale",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
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
  end

  describe "charge_back_payment" do
    test "reclassifies refunded cash without reversing the guest refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 8000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 8000, "revision" => 3},
               %{
                 "status" => "applied",
                 "payment_operation_id" => "op-pay",
                 "group_id" => "group-81",
                 "charged_back_cents" => 8000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200)["data"]["cash_refunded_cents"] == 0
      assert json_response(conn, 200)["data"]["cash_charged_back_cents"] == 8000

      conn = get(conn, "/api/v1/payments/op-pay")
      statement = json_response(conn, 200)["data"]
      assert statement["refunded_cents"] == 0
      assert statement["charged_back_cents"] == 8000
      assert statement["recorded_cents"] == 8000
    end

    test "removes held cash and reopens outstanding on an active group", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "charged_back_cents" => 5000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["cash_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 19_500
    end

    test "revokes unspent converted credit and records a shortfall for applied credit", %{
      conn: conn
    } do
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
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-1"
          }
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.at(results, 4)["revision"] == 2
      assert Enum.at(results, 5)["charged_back_cents"] == 5000
      assert Enum.at(results, 5)["revision"] == 4

      conn = get(conn, "/api/v1/groups/g2")
      funded = json_response(conn, 200)["data"]
      assert funded["revision"] == 2
      assert funded["credit_paid_cents"] == 2000

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
      assert ledger["credit_liability_cents"] == 2000
      assert ledger["credit_shortfall_cents"] == 2000
    end

    test "absorbs restored credit into unrecovered clawback before expiry", %{conn: conn} do
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
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-1"
          },
          %{
            "operation_id" => "cancel-g2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "g2"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "non-refundable consumption of applied credit clears the current shortfall", %{
      conn: conn
    } do
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
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-1"
          },
          %{
            "operation_id" => "cancel-g2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-10",
            "group_id" => "g2"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "leaves reduced cash in place and rejects a second chargeback", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          %{
            "operation_id" => "op-cb-2",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"charged_back_cents" => 3000, "revision" => 4},
               %{"code" => "payment_not_chargeable"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/payments/op-pay")
      statement = json_response(conn, 200)["data"]
      assert statement["reduced_cents"] == 2000
      assert statement["charged_back_cents"] == 3000
      assert statement["held_cents"] == 0
    end

    test "rejects a fully reduced payment and a missing operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 1000),
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          %{
            "operation_id" => "op-missing",
            "type" => "charge_back_payment",
            "payment_operation_id" => "no-such"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "payment_not_chargeable"},
               %{"code" => "operation_not_found"}
             ] = json_response(conn, 200)["results"]
    end

    test "assigns telescoping entitlements across payments in one lot", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(%{"group_id" => "g1"}),
          cash_payment("pay-a", "g1", 15),
          cash_payment("pay-b", "g1", 15),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "cb-b",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-b"
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["charged_back_cents"] == 15

      conn = get(conn, "/api/v1/guests/guest-22/credit")
      assert json_response(conn, 200)["data"]["available_cents"] == 17
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns 404 and 422 for unreadable targets", %{conn: conn} do
      conn = post_batch(conn, [example_open()])
      assert conn.status == 200

      conn = get(conn, "/api/v1/payments/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      conn = get(conn, "/api/v1/payments/op-1001")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    test "returns every disposition field for an applied payment", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("pay-17", "group-81", 5000)
        ])

      assert conn.status == 200

      conn = get(conn, "/api/v1/payments/pay-17")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-17",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 5000,
                 "held_cents" => 5000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
    end
  end

  describe "durable new operations" do
    test "new funding skips cancelled rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          %{
            "operation_id" => "op-cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          cash_payment("op-pay", "group-81", 4000)
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/groups/group-81")
      rooms = json_response(conn, 200)["data"]["rooms"]
      assert Enum.at(rooms, 0)["status"] == "cancelled"
      assert Enum.at(rooms, 0)["cash_paid_cents"] == 0
      assert Enum.at(rooms, 1)["cash_paid_cents"] == 4000
    end

    test "retries cancel_rooms and reduce without a second effect", %{conn: conn} do
      cancel = %{
        "operation_id" => "op-cancel-a",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      }

      reduce = %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 500
      }

      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 19_500),
          cancel,
          reduce
        ])

      first = json_response(conn, 200)["results"]

      conn = post_batch(conn, [cancel, reduce])
      assert json_response(conn, 200)["results"] == [Enum.at(first, 2), Enum.at(first, 3)]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 4
      assert data["cash_paid_cents"] == 10_000
    end

    test "retries a chargeback without a second effect", %{conn: conn} do
      chargeback = %{
        "operation_id" => "op-cb",
        "type" => "charge_back_payment",
        "payment_operation_id" => "op-pay"
      }

      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("op-pay", "group-81", 5000),
          chargeback
        ])

      first = json_response(conn, 200)["results"]
      conn = post_batch(conn, [chargeback])
      assert json_response(conn, 200)["results"] == [List.last(first)]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 3
    end
  end

  describe "payment statement agreement" do
    test "dispositions remain a partition of recorded cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("pay-17", "group-81", 10_000),
          %{
            "operation_id" => "op-cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 500
          },
          %{
            "operation_id" => "op-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-17"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/payments/pay-17")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "pay-17",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 9500
             }

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_reduced_cents"] == 500
      assert ledger["cash_charged_back_cents"] == 9500
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
