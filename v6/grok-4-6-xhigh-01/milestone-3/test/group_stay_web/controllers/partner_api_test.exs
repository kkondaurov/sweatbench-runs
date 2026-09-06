defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post_batch_raw(conn, %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a non-list operations field", %{conn: conn} do
      conn = post_batch_raw(conn, %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "accepts an empty operations list", %{conn: conn} do
      conn = post_batch(conn, [])
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "opens a flexible group and returns the rounded deposit", %{conn: conn} do
      conn = post_batch(conn, [open_op()])

      assert [
               %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ] = json_response(conn, 200)["results"]
    end

    test "opens an advance-purchase group with the full lodging amount as deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase", "operation_id" => "op-ap"})
        ])

      assert [
               %{
                 "operation_id" => "op-ap",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 97_500,
                 "revision" => 1
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rounds each flexible room deposit to the nearest cent, half-cent up", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 3},
        %{"room_id" => "room-b", "nightly_rate_cents" => 13}
      ]

      conn =
        post_batch(conn, [
          open_op(%{
            "operation_id" => "op-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => rooms
          })
        ])

      assert [%{"status" => "applied", "deposit_due_cents" => 4}] =
               json_response(conn, 200)["results"]
    end

    test "rejects a duplicate group identifier without creating a second group", %{conn: conn} do
      conn = post_batch(conn, [open_op(), open_op(%{"operation_id" => "op-dup"})])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-dup",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "rejects stays that are not at least one night", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "same-day", "departure_on" => "2026-12-10"}),
          open_op(%{
            "operation_id" => "backwards",
            "group_id" => "group-82",
            "arrival_on" => "2026-12-13",
            "departure_on" => "2026-12-10"
          })
        ])

      assert [
               %{"operation_id" => "same-day", "status" => "rejected", "code" => "invalid_stay"},
               %{"operation_id" => "backwards", "status" => "rejected", "code" => "invalid_stay"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 404)["error"]["code"] == "group_not_found"
    end

    test "rejects empty, duplicate, or malformed rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "none", "rooms" => []}),
          open_op(%{
            "operation_id" => "dup-rooms",
            "group_id" => "group-82",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 200}
            ]
          }),
          open_op(%{
            "operation_id" => "bad-rate",
            "group_id" => "group-83",
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
      conn = post_batch(conn, [open_op(%{"rate_plan" => "nonrefundable"})])

      assert [%{"status" => "rejected", "code" => "invalid_rate_plan"}] =
               json_response(conn, 200)["results"]
    end

    test "records a cash payment against the outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
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
    end

    test "rejects payments that are missing, unusable, or too large", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "missing-group",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100
          },
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
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => "missing-group", "code" => "group_not_found"},
               %{"operation_id" => "zero", "code" => "invalid_amount"},
               %{"operation_id" => "over", "code" => "payment_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["deposit_paid_cents"] == 0
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "reschedules an active group by shifting the departure date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
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
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-06",
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a reschedule that is not after the operation date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-same-day",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-10-04"
          },
          %{
            "operation_id" => "op-past",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-10-03"
          },
          %{
            "operation_id" => "op-missing-group",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "operation_id" => "op-same-day",
                 "status" => "rejected",
                 "code" => "invalid_stay"
               },
               %{"operation_id" => "op-past", "status" => "rejected", "code" => "invalid_stay"},
               %{
                 "operation_id" => "op-missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["arrival_on"] == "2026-12-10"
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "refunds a flexible cancellation at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(19_500),
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
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 19_500,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]
    end

    test "retains cash when a flexible group is cancelled inside 14 days", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(4000),
          %{
            "operation_id" => "op-late",
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
                 "retained_cents" => 4000,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]
    end

    test "never refunds an advance-purchase cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(97_500),
          %{
            "operation_id" => "op-ap-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 97_500,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects later mutations after cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          pay_op(100),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-cancel-again",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"operation_id" => "op-pay", "code" => "group_not_active"},
               %{"operation_id" => "op-move", "code" => "group_not_active"},
               %{"operation_id" => "op-cancel-again", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
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
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
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
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 1000
    end

    test "returns group_not_found before comparing revisions", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-missing",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "expected_revision" => 1
          }
        ])

      assert [
               %{
                 "operation_id" => "op-missing",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "applies expected_revision against changes from earlier operations in the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          Map.put(pay_op(1000), "expected_revision", 1),
          Map.merge(pay_op(500), %{"operation_id" => "op-pay-2", "expected_revision" => 2})
        ])

      assert [
               %{"revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 18_000}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects unknown types and incomplete operations without stopping the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "explode_group", "group_id" => "group-81"},
          %{"operation_id" => "op-empty"},
          open_op()
        ])

      assert [
               %{
                 "operation_id" => "op-unknown",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "op-empty",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "op-1001", "status" => "applied", "revision" => 1}
             ] = json_response(conn, 200)["results"]
    end

    test "ignores expected_revision on open_group", %{conn: conn} do
      conn = post_batch(conn, [Map.put(open_op(), "expected_revision", 99)])

      assert [%{"status" => "applied", "revision" => 1}] = json_response(conn, 200)["results"]
    end

    test "accepts a payment that exactly clears the outstanding deposit", %{conn: conn} do
      conn = post_batch(conn, [open_op(), pay_op(19_500)])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2}
             ] = json_response(conn, 200)["results"]
    end

    test "does not reuse a cancelled group identifier", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          open_op(%{"operation_id" => "op-reopen"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"operation_id" => "op-reopen", "code" => "group_already_exists"}
             ] = json_response(conn, 200)["results"]
    end

    test "increments revision on a no-cash cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"revision" => 1},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a payment missing amount_cents as invalid_operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-no-amount",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => "op-no-amount", "code" => "invalid_operation"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group with rooms in original order and computed totals", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), pay_op(4500)])

      conn = get(conn, "/api/v1/groups/group-81")

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
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 4500,
                 "cash_paid_cents" => 4500,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 15_000
               }
             } == json_response(conn, 200)
    end

    test "returns 404 for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "returns rescheduled stay dates without changing price", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["arrival_on"] == "2026-12-20"
      assert data["departure_on"] == "2026-12-23"
      assert data["booked_on"] == "2026-10-03"
      assert data["deposit_due_cents"] == 19_500
      assert data["lodging_total_cents"] == 97_500
      assert data["revision"] == 2
    end

    test "clears outstanding after cancellation", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(2000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          }
        ])

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["outstanding_deposit_cents"] == 0
      assert data["revision"] == 3
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
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
    end

    test "holds cash on active groups and moves it on cancellation", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(8000),
          open_op(%{"group_id" => "group-82", "operation_id" => "op-open-2"}),
          Map.merge(pay_op(3000), %{"group_id" => "group-82", "operation_id" => "op-pay-2"}),
          open_op(%{"group_id" => "group-83", "operation_id" => "op-open-3"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-83", "operation_id" => "op-pay-3"}),
          %{
            "operation_id" => "refund",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-82"
          },
          %{
            "operation_id" => "retain",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-83"
          }
        ])

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 8000,
                 "cash_refunded_cents" => 3000,
                 "cash_retained_cents" => 2000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "does not treat unpaid deposit as cash", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op()])

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
    test "assigns flex-14 before the cutoff and flex-30 on or after it", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "pre", "occurred_on" => "2026-12-31"}),
          open_op(%{
            "operation_id" => "on-cutoff",
            "group_id" => "group-82",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      pre = json_response(conn, 200)["data"]
      assert pre["policy_version"] == "flex-14"
      assert pre["refundable_until"] == "2026-11-26"

      conn = get(conn, "/api/v1/groups/group-82")
      post = json_response(conn, 200)["data"]
      assert post["policy_version"] == "flex-30"
      assert post["refundable_until"] == "2027-05-02"
    end

    test "keeps advance-purchase non-refundable regardless of booking date", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "rate_plan" => "advance_purchase",
            "occurred_on" => "2027-03-01",
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          })
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "reschedule keeps the original policy and recomputes refundable_until", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"occurred_on" => "2026-12-15"}),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2027-02-01",
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
      assert data["booked_on"] == "2026-12-15"
    end

    test "flex-30 is refundable on the 30th day before arrival and not after", %{conn: conn} do
      open =
        open_op(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      conn =
        post_batch(conn, [
          open,
          pay_op(19_500),
          cancel_op("on-window", "2027-05-02")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 19_500, "retained_cents" => 0}
             ] = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          open_op(%{
            "operation_id" => "open-late",
            "group_id" => "group-82",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          }),
          Map.merge(pay_op(4000), %{"group_id" => "group-82", "operation_id" => "pay-late"}),
          %{
            "operation_id" => "after-window",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "group-82"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 4000}
             ] = json_response(conn, 200)["results"]
    end

    test "a pre-cutoff group cancelled after the cutoff still uses the 14-day window", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(%{
            "occurred_on" => "2026-12-20",
            "arrival_on" => "2027-02-10",
            "departure_on" => "2027-02-13"
          }),
          pay_op(19_500),
          cancel_op("still-flex-14", "2027-01-27")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "refunded_cents" => 19_500, "retained_cents" => 0}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["policy_version"] == "flex-14"
      assert json_response(conn, 200)["data"]["refundable_until"] == "2027-01-27"
    end

    test "legacy groups without a stored policy receive the implied version", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op()])

      {1, _} =
        GroupStay.Repo.update_all(GroupStay.Groups.Group,
          set: [policy_version: nil]
        )

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end
  end

  describe "hotel credit cancellation" do
    test "converts refundable cash into a 110% credit lot and ledger conversion", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "cancel-17",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 5500,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "cancelled"
      assert data["cash_paid_cents"] == 5000
      assert data["credit_paid_cents"] == 0
      assert data["revision"] == 3

      conn = get(conn, "/api/v1/ledger?on=2026-11-01")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 5500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 5500,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             }
    end

    test "rounds the 10% bonus half-cent upward", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
          }),
          pay_op(5),
          cancel_op("cancel-bonus", "2026-11-01", "hotel_credit")
        ])

      assert [
               %{"status" => "applied", "deposit_due_cents" => 5},
               %{"status" => "applied"},
               %{"credit_issued_cents" => 6, "refunded_cents" => 0, "retained_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects hotel credit on a non-refundable cancellation and leaves the group active", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(4000),
          cancel_op("late-credit", "2026-11-27", "hotel_credit")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "late-credit",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["status"] == "active"
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 4000

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 4000
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
    end

    test "rejects hotel credit for advance purchase", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(1000),
          cancel_op("ap-credit", "2026-10-04", "hotel_credit")
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
          open_op(),
          pay_op(1000),
          Map.merge(cancel_op("stale-credit", "2026-11-27", "hotel_credit"), %{
            "expected_revision" => 1
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2,
                 "group_id" => "group-81"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "omitted refund_method remains a cash refund", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(2000),
          cancel_op("cash-default", "2026-11-01")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => 2000, "retained_cents" => 0, "credit_issued_cents" => 0}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "apply_hotel_credit" do
    test "redeems available credit into an active deposit", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{
            "operation_id" => "open-2",
            "group_id" => "group-82",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-23"
          }),
          credit_op("apply-1", "group-82", 4000, "2026-11-02")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "apply-1",
                 "status" => "applied",
                 "group_id" => "group-82",
                 "amount_cents" => 4000,
                 "outstanding_deposit_cents" => 15_500,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-82")
      data = json_response(conn, 200)["data"]
      assert data["cash_paid_cents"] == 0
      assert data["credit_paid_cents"] == 4000
      assert data["deposit_paid_cents"] == 4000

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-02")
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 1500
      assert hd(credit["lots"])["remaining_cents"] == 1500

      conn = get(conn, "/api/v1/ledger?on=2026-11-02")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["credit_liability_cents"] == 5500
    end

    test "rejects insufficient credit without advancing revision", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          cancel_op("cancel-small", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("too-much", "group-82", 2000, "2026-11-02")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 1},
               %{"operation_id" => "too-much", "code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-82")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 1
      assert data["credit_paid_cents"] == 0
    end

    test "uses existing payment errors when they apply", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit")
        ])

      conn =
        post_batch(conn, [
          credit_op("missing", "missing", 100, "2026-11-02"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("zero", "group-82", 0, "2026-11-02"),
          credit_op("over", "group-82", 19_501, "2026-11-02"),
          cancel_op("cancel-82", "2026-11-02") |> Map.put("group_id", "group-82"),
          credit_op("inactive", "group-82", 100, "2026-11-03")
        ])

      assert [
               %{"operation_id" => "missing", "code" => "group_not_found"},
               %{"status" => "applied"},
               %{"operation_id" => "zero", "code" => "invalid_amount"},
               %{"operation_id" => "over", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied"},
               %{"operation_id" => "inactive", "code" => "group_not_active"}
             ] = json_response(conn, 200)["results"]
    end

    test "checks stale revision before insufficient_credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          Map.merge(credit_op("stale-credit", "group-81", 99_999, "2026-10-04"), %{
            "expected_revision" => 9
          })
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "code" => "stale_revision",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
             ] = json_response(conn, 200)["results"]
    end

    test "consumes lots by earliest expiry then source_operation_id", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(%{"operation_id" => "open-a", "group_id" => "group-a"}),
          Map.merge(pay_op(1000), %{"group_id" => "group-a", "operation_id" => "pay-a"}),
          cancel_op("cancel-a", "2026-11-01", "hotel_credit") |> Map.put("group_id", "group-a"),
          open_op(%{"operation_id" => "open-b", "group_id" => "group-b"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-b", "operation_id" => "pay-b"}),
          cancel_op("cancel-b", "2026-11-01", "hotel_credit") |> Map.put("group_id", "group-b"),
          open_op(%{"operation_id" => "open-c", "group_id" => "group-c"}),
          Map.merge(pay_op(3000), %{"group_id" => "group-c", "operation_id" => "pay-c"}),
          cancel_op("cancel-c", "2026-10-15", "hotel_credit") |> Map.put("group_id", "group-c"),
          open_op(%{"operation_id" => "open-d", "group_id" => "group-d"}),
          credit_op("apply-order", "group-d", 4000, "2026-11-02")
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-02")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 2600,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-a",
                   "remaining_cents" => 400,
                   "expires_on" => "2027-11-01"
                 },
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 2200,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }
    end

    test "does not let one guest spend another guest's credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{
            "operation_id" => "open-other",
            "group_id" => "group-99",
            "guest_id" => "guest-99"
          }),
          credit_op("other-guest", "group-99", 1000, "2026-11-02")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"operation_id" => "other-guest", "code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects apply_hotel_credit missing amount_cents as invalid_operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-no-amount",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => "op-no-amount", "code" => "invalid_operation"}
             ] = json_response(conn, 200)["results"]
    end

    test "treats expired credit as unavailable on occurred_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          cancel_op("cancel-old", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("after-expiry", "group-82", 100, "2027-11-02")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]
    end
  end

  describe "settling groups funded by credit" do
    test "refundable cash cancel restores original lots without a second bonus", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-82", "operation_id" => "pay-2"}),
          credit_op("apply-1", "group-82", 3000, "2026-11-02"),
          cancel_op("cancel-82", "2026-11-03") |> Map.put("group_id", "group-82")
        ])

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "cancel-82",
               "status" => "applied",
               "group_id" => "group-82",
               "refunded_cents" => 2000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-03")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }

      conn = get(conn, "/api/v1/ledger?on=2026-11-03")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "refundable hotel-credit cancel bonuses only the cash portion", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-82", "operation_id" => "pay-2"}),
          credit_op("apply-1", "group-82", 3000, "2026-11-02"),
          Map.merge(cancel_op("cancel-82", "2026-11-03", "hotel_credit"), %{
            "group_id" => "group-82"
          })
        ])

      assert List.last(json_response(conn, 200)["results"])["credit_issued_cents"] == 2200

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-03")
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 7700

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-11-01"
               },
               %{
                 "source_operation_id" => "cancel-82",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-11-03"
               }
             ]

      conn = get(conn, "/api/v1/ledger?on=2026-11-03")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 7000,
               "credit_liability_cents" => 7700
             }
    end

    test "non-refundable cancel retains cash and consumes applied credit", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-82", "operation_id" => "pay-2"}),
          credit_op("apply-1", "group-82", 3000, "2026-11-02"),
          Map.merge(cancel_op("late-82", "2026-12-01"), %{"group_id" => "group-82"})
        ])

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "late-82",
               "status" => "applied",
               "group_id" => "group-82",
               "refunded_cents" => 0,
               "retained_cents" => 2000,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-12-01")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 2500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 2500,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }

      conn = get(conn, "/api/v1/ledger?on=2026-12-01")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 2000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 2500
             }
    end

    test "restored credit that already expired reduces liability immediately", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{
            "operation_id" => "open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          credit_op("apply-1", "group-82", 3000, "2026-11-02"),
          Map.merge(cancel_op("cancel-82", "2027-11-02"), %{"group_id" => "group-82"})
        ])

      assert List.last(json_response(conn, 200)["results"])["status"] == "applied"

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-02")
      assert json_response(conn, 200)["data"]["available_cents"] == 0
      assert json_response(conn, 200)["data"]["lots"] == []

      conn = get(conn, "/api/v1/ledger?on=2027-11-02")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end
  end

  describe "GET /api/v1/guests/:guest_id/credit and ledger as-of" do
    test "omits expired and exhausted lots and orders the rest", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(%{"operation_id" => "open-a", "group_id" => "group-a"}),
          Map.merge(pay_op(1000), %{"group_id" => "group-a", "operation_id" => "pay-a"}),
          cancel_op("cancel-a", "2026-10-01", "hotel_credit") |> Map.put("group_id", "group-a"),
          open_op(%{"operation_id" => "open-b", "group_id" => "group-b"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-b", "operation_id" => "pay-b"}),
          cancel_op("cancel-b", "2026-11-01", "hotel_credit") |> Map.put("group_id", "group-b"),
          open_op(%{"operation_id" => "open-c", "group_id" => "group-c"}),
          credit_op("use-all-a", "group-c", 1100, "2026-10-02")
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 2200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 2200,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-02")
      assert json_response(conn, 200)["data"]["available_cents"] == 0
      assert json_response(conn, 200)["data"]["lots"] == []
    end

    test "returns empty credit for a guest with no lots", %{conn: conn} do
      conn = get(conn, "/api/v1/guests/guest-99/credit")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "guest_id" => "guest-99",
                 "available_cents" => 0,
                 "lots" => []
               }
             }
    end

    test "applied credit stays in liability after the lot's expiry date", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{
            "operation_id" => "open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          credit_op("apply-1", "group-82", 3000, "2026-11-02")
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-02")
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2027-11-02")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 3000

      conn = get(conn, "/api/v1/groups/group-82")
      assert json_response(conn, 200)["data"]["credit_paid_cents"] == 3000
      assert json_response(conn, 200)["data"]["status"] == "active"
    end

    test "ledger on= reports expiry as of that date without changing cash totals", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(1000), %{"group_id" => "group-82", "operation_id" => "pay-2"})
        ])

      conn = get(conn, "/api/v1/ledger?on=2026-11-01")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 1000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }

      conn = get(conn, "/api/v1/ledger?on=2027-11-02")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 1000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 0
             }
    end
  end

  describe "durable operation idempotency" do
    test "retries with an equivalent payload return the original applied result", %{conn: conn} do
      first = post_batch(conn, [open_op(), pay_op(5000)])
      original = json_response(first, 200)["results"]

      retry = post_batch(conn, [open_op(), pay_op(5000)])
      assert json_response(retry, 200)["results"] == original

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 2
      assert data["deposit_paid_cents"] == 5000
    end

    test "JSON object key order is irrelevant for equivalence", %{conn: conn} do
      first =
        post_json_string(conn, """
        {"operations":[{"operation_id":"op-keys","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"nightly_rate_cents":17500,"room_id":"room-b"}]}]}
        """)

      assert [%{"status" => "applied", "operation_id" => "op-keys", "revision" => 1}] =
               json_response(first, 200)["results"]

      retry =
        post_json_string(conn, """
        {"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"room_id":"room-b","nightly_rate_cents":17500}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2026-10-03","type":"open_group","operation_id":"op-keys"}]}
        """)

      assert json_response(retry, 200)["results"] == json_response(first, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "array order remains significant", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(%{"operation_id" => "op-rooms"})])

      swapped = %{
        "operation_id" => "op-rooms",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-82",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
        ]
      }

      conn = post_batch(conn, [swapped])

      assert [
               %{
                 "operation_id" => "op-rooms",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-82")
      assert json_response(conn, 404)["error"]["code"] == "group_not_found"
    end

    test "a remembered rejection is replayed even if it would now be valid", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-early-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 1000
          }
        ])

      assert [%{"operation_id" => "op-early-pay", "code" => "group_not_found"}] =
               json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-early-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 1000
          }
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-early-pay",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["deposit_paid_cents"] == 0
      assert data["revision"] == 1

      conn = get(conn, "/api/v1/operations/op-early-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "operation_id" => "op-early-pay",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             }
    end

    test "reusing an identifier with a different payload is a conflict", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(%{"operation_id" => "op-reuse"})])

      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "op-reuse", "group_id" => "group-82"})
        ])

      assert [
               %{
                 "operation_id" => "op-reuse",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/operations/op-reuse")

      assert %{
               "data" => %{
                 "operation_id" => "op-reuse",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "revision" => 1
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-82")
      assert json_response(conn, 404)["error"]["code"] == "group_not_found"
    end

    test "GET returns the stored result and 404 for an unknown id", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), pay_op(4500)])

      conn = get(conn, "/api/v1/operations/op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 4500,
                 "outstanding_deposit_cents" => 15_000,
                 "revision" => 2
               }
             }

      conn = get(conn, "/api/v1/operations/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "an exact stale retry returns the stored revision details", %{conn: conn} do
      stale = %{
        "operation_id" => "op-stale",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100,
        "expected_revision" => 1
      }

      conn = post_batch(conn, [open_op(), pay_op(1000), stale])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "op-stale",
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          Map.merge(pay_op(500), %{"operation_id" => "op-pay-2"}),
          stale
        ])

      assert [
               %{"status" => "applied", "revision" => 3},
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = post_batch(conn, [Map.put(stale, "expected_revision", 3)])

      assert [
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      data = json_response(conn, 200)["data"]
      assert data["revision"] == 3
      assert data["deposit_paid_cents"] == 1500
    end

    test "remembers handled rejections and continues the batch", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "explode_group", "group_id" => "group-81"},
          open_op(%{"operation_id" => "op-open"})
        ])

      assert [
               %{"operation_id" => "op-unknown", "code" => "invalid_operation"},
               %{"operation_id" => "op-open", "status" => "applied"}
             ] = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          %{"operation_id" => "op-unknown", "type" => "explode_group", "group_id" => "group-81"}
        ])

      assert [
               %{
                 "operation_id" => "op-unknown",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "retains type, submitted content, and first-commit order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "op-a"}),
          %{
            "operation_id" => "op-b",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "missing",
            "amount_cents" => 100
          },
          open_op(%{"operation_id" => "op-c", "group_id" => "group-82"})
        ])

      assert conn.status == 200

      records =
        GroupStay.Groups.Operation
        |> GroupStay.Repo.all()
        |> Enum.sort_by(& &1.id)

      assert Enum.map(records, & &1.operation_id) == ["op-a", "op-b", "op-c"]
      assert Enum.map(records, & &1.type) == ["open_group", "record_cash_payment", "open_group"]

      payload_b = Enum.at(records, 1).payload
      assert payload_b["operation_id"] == "op-b"
      assert payload_b["group_id"] == "missing"
      assert payload_b["amount_cents"] == 100
      assert payload_b["type"] == "record_cash_payment"

      conn = get(conn, "/api/v1/operations/op-b")
      body = json_response(conn, 200)
      assert body == %{"data" => body["data"]}
      refute Map.has_key?(body["data"], "payload")
      refute Map.has_key?(body["data"], "type")
    end

    test "an unexpected fault rolls back and is not remembered", %{conn: _conn} do
      assert [%{"status" => "applied"}] = GroupStay.Groups.submit_batch([open_op()])

      assert_raise Ecto.ChangeError, fn ->
        GroupStay.Groups.submit_batch([Map.put(pay_op(1000), "probe", self())])
      end

      assert GroupStay.Groups.get_operation_result("op-pay") == nil
      assert GroupStay.Groups.get_operation_result("op-1001")["status"] == "applied"
      assert GroupStay.Groups.get_by_group_id("group-81").deposit_paid_cents == 0
    end
  end

  defp open_and_return(conn, operations) do
    conn = post_batch(conn, operations)
    assert conn.status == 200
    {:ok, conn}
  end

  defp post_batch(conn, operations) do
    post_batch_raw(conn, %{"operations" => operations})
  end

  defp post_batch_raw(conn, body) do
    post_json_string(conn, Jason.encode!(body))
  end

  defp post_json_string(conn, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp open_op(overrides \\ %{}) do
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

  defp pay_op(amount_cents) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, occurred_on, refund_method \\ nil) do
    op = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-81"
    }

    if refund_method, do: Map.put(op, "refund_method", refund_method), else: op
  end

  defp credit_op(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
