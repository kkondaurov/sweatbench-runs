defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post_batch_raw(conn, %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a null operations value as an invalid batch", %{conn: conn} do
      conn = post_batch_raw(conn, %{"operations" => nil})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "applies an empty operations list", %{conn: conn} do
      conn = post_batch(conn, [])
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "ignores expected_revision when opening a group", %{conn: conn} do
      conn = post_batch(conn, [open_op(%{"expected_revision" => 99})])

      assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
               json_response(conn, 200)
    end

    test "opens a flexible group using the documented example", %{conn: conn} do
      conn = post_batch(conn, [open_op()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
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
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500,
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26"
               }
             }
    end

    test "requires the full lodging amount as deposit for advance_purchase", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase", "group_id" => "group-ap"})
        ])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "deposit_due_cents" => 97500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately half-up", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "group-round",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 3},
              %{"room_id" => "room-b", "nightly_rate_cents" => 2}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "rejects a duplicate group identifier without creating a second group", %{conn: conn} do
      conn = post_batch(conn, [open_op(), open_op(%{"operation_id" => "op-dup"})])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-dup",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             }
    end

    test "rejects stays shorter than one night", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"})
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects empty rooms, duplicate room ids, and negative rates", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"operation_id" => "op-empty", "group_id" => "g1", "rooms" => []}),
          open_op(%{
            "operation_id" => "op-dup-rooms",
            "group_id" => "g2",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 100},
              %{"room_id" => "room-a", "nightly_rate_cents" => 200}
            ]
          }),
          open_op(%{
            "operation_id" => "op-neg",
            "group_id" => "g3",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]
          })
        ])

      assert %{
               "results" => [
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects an unknown rate plan without creating a group", %{conn: conn} do
      conn = post_batch(conn, [open_op(%{"rate_plan" => "nonrefundable"})])

      assert %{"results" => [%{"code" => "invalid_rate_plan"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "records cash against an active group's outstanding deposit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10000
          }
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 10000,
                   "outstanding_deposit_cents" => 9500,
                   "revision" => 2
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 10000,
                 "cash_paid_cents" => 10000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 9500,
                 "revision" => 2
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 10000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "rejects payments that cannot apply", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "missing",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "no-such",
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
            "operation_id" => "negative",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => -1
          },
          %{
            "operation_id" => "over",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19501
          },
          %{
            "operation_id" => "full",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19500
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"operation_id" => "missing", "code" => "group_not_found"},
                 %{"operation_id" => "zero", "code" => "invalid_amount"},
                 %{"operation_id" => "negative", "code" => "invalid_amount"},
                 %{"operation_id" => "over", "code" => "payment_exceeds_outstanding"},
                 %{
                   "operation_id" => "full",
                   "status" => "applied",
                   "outstanding_deposit_cents" => 0,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "reschedules an active group by the same number of days", %{conn: conn} do
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

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
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
             }

      conn = get(conn, "/api/v1/groups/group-81")

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

    test "rejects a reschedule when the new arrival is not after the operation date", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-20",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert %{"results" => [_, %{"code" => "invalid_stay", "status" => "rejected"}]} =
               json_response(conn, 200)
    end

    test "refunds flexible cash cancelled at least 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(19500),
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
                   "refunded_cents" => 19500,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19500,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "retains flexible cash cancelled fewer than 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
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
                   "retained_cents" => 5000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 5000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "cancels unpaid deposit without moving cash", %{conn: conn} do
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

      assert %{
               "results" => [
                 _,
                 %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}
               ]
             } = json_response(conn, 200)

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

    test "never refunds advance_purchase cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(97500),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"refunded_cents" => 0, "retained_cents" => 97500, "revision" => 3}
               ]
             } = json_response(conn, 200)
    end

    test "rejects later operations against a cancelled group", %{conn: conn} do
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
            "operation_id" => "op-cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"status" => "applied", "revision" => 2},
                 %{"operation_id" => "op-pay", "code" => "group_not_active"},
                 %{"operation_id" => "op-move", "code" => "group_not_active"},
                 %{"operation_id" => "op-cancel-2", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)
    end

    test "returns group_not_found before comparing revisions", %{conn: conn} do
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

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }
    end

    test "rejects a stale revision before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "fresh-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500,
            "expected_revision" => 2
          }
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 1000,
                   "outstanding_deposit_cents" => 18500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "stale-pay",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "fresh-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 500,
                   "outstanding_deposit_cents" => 18000,
                   "revision" => 3
                 }
               ]
             }
    end

    test "rejects unknown types and incomplete operations then continues the batch", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          %{"operation_id" => "incomplete", "type" => "record_cash_payment"},
          open_op()
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
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns 404 for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "GET /api/v1/ledger" do
    test "sums cash across active and cancelled groups", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"group_id" => "held", "operation_id" => "o1"}),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "held",
            "amount_cents" => 1000
          },
          open_op(%{"group_id" => "refunded", "operation_id" => "o2"}),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "refunded",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "c2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "refunded"
          },
          open_op(%{
            "group_id" => "retained",
            "operation_id" => "o3",
            "rate_plan" => "advance_purchase"
          }),
          %{
            "operation_id" => "p3",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "retained",
            "amount_cents" => 3000
          },
          %{
            "operation_id" => "c3",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "retained"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 1000,
                 "cash_refunded_cents" => 2000,
                 "cash_retained_cents" => 3000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

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
  end

  describe "policy versions" do
    test "assigns flex-14 before 2027 and flex-30 on or after", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "operation_id" => "o-14",
            "group_id" => "g-14",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-16"
          }),
          open_op(%{
            "operation_id" => "o-30",
            "group_id" => "g-30",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-15",
            "departure_on" => "2027-03-16"
          }),
          open_op(%{
            "operation_id" => "o-ap",
            "group_id" => "g-ap",
            "rate_plan" => "advance_purchase"
          })
        ])

      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/g-14")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-01"
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/g-30")

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-02-13"
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/g-ap")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = json_response(conn, 200)
    end

    test "rescheduling keeps the original policy and recomputes refundable_until", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-02-10",
            "departure_on" => "2027-02-13"
          }),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-15",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-03-20"
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-03-06",
                   "new_arrival_on" => "2027-03-20",
                   "new_departure_on" => "2027-03-23"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-06"
               }
             } = json_response(conn, 200)
    end

    test "legacy groups without a stored policy use the original booking date", %{conn: conn} do
      {:ok, _} =
        %GroupStay.Groups.Group{}
        |> GroupStay.Groups.Group.changeset(%{
          group_id: "legacy-flex",
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
          deposit_paid_cents: 1000,
          cash_paid_cents: 1000,
          rooms: [%{room_id: "room-a", nightly_rate_cents: 15000}]
        })
        |> GroupStay.Repo.insert()

      conn = get(conn, "/api/v1/groups/legacy-flex")

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "cash_paid_cents" => 1000,
                 "credit_paid_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "flex-30 is refundable on the 30th day before arrival and not the day after", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "g-ok",
            "operation_id" => "o1",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-02",
            "departure_on" => "2027-03-03"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-02",
            "group_id" => "g-ok",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "c1",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-31",
            "group_id" => "g-ok"
          },
          open_op(%{
            "group_id" => "g-late",
            "operation_id" => "o2",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-02",
            "departure_on" => "2027-03-03"
          }),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-02",
            "group_id" => "g-late",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "c2",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-01",
            "group_id" => "g-late"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 5000, "retained_cents" => 0},
                 _,
                 _,
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5000}
               ]
             } = json_response(conn, 200)
    end

    test "flex-30 is non-refundable 14 days before arrival", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-02",
            "departure_on" => "2027-03-03"
          }),
          pay_op(5000),
          %{
            "operation_id" => "op-credit",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-16",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-16",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"code" => "refund_method_not_available"},
                 %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5000}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "hotel credit" do
    test "issues 110% credit from cash and moves ledger totals", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
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
                   "operation_id" => "cancel-17",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 5500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"status" => "cancelled", "revision" => 3}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-03")

      assert json_response(conn, 200) == %{
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
             }

      conn = get(conn, "/api/v1/ledger?on=2027-05-03")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             }
    end

    test "rounds the 10% bonus half-up and omits refund_method as cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "g-round",
            "operation_id" => "o1",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-round",
            "amount_cents" => 15
          },
          %{
            "operation_id" => "c1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "g-round",
            "refund_method" => "hotel_credit"
          },
          open_op(%{"group_id" => "g-cash", "operation_id" => "o2"}),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-cash",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "c2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "g-cash"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"credit_issued_cents" => 17, "refunded_cents" => 0, "retained_cents" => 0},
                 _,
                 _,
                 %{"credit_issued_cents" => 0, "refunded_cents" => 1000, "retained_cents" => 0}
               ]
             } = json_response(conn, 200)
    end

    test "rejects hotel credit on a non-refundable cancellation without changing state", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(5000),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          }
        ])

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"status" => "active", "revision" => 2}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 5000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "checks stale revision before refund_method_not_available", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit",
            "expected_revision" => 9
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 9,
                   "actual_revision" => 1,
                   "group_id" => "group-81"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "applies unexpired credit to an active group and pauses expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "arrival_on" => "2028-06-10",
            "departure_on" => "2028-06-13"
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 4000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"revision" => 1},
                 %{
                   "operation_id" => "credit-1",
                   "status" => "applied",
                   "group_id" => "dest",
                   "amount_cents" => 4000,
                   "outstanding_deposit_cents" => 15500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/dest")

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 4000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 4000,
                 "outstanding_deposit_cents" => 15500,
                 "revision" => 2
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-04")

      assert %{
               "data" => %{
                 "available_cents" => 1500,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-17",
                     "remaining_cents" => 1500,
                     "expires_on" => "2028-05-02"
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2028-05-03")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 4000
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-04")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 5500,
                 "cash_held_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "consumes lots by earliest expiry then source_operation_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "g-a",
            "operation_id" => "o-a",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-11",
            "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
          }),
          %{
            "operation_id" => "p-a",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-a",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-b",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-10",
            "group_id" => "g-a",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "g-b",
            "operation_id" => "o-b",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-11",
            "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
          }),
          %{
            "operation_id" => "p-b",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-b",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-10",
            "group_id" => "g-b",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "g-c",
            "operation_id" => "o-c",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-11",
            "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
          }),
          %{
            "operation_id" => "p-c",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g-c",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-early",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-05",
            "group_id" => "g-c",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o-d",
            "arrival_on" => "2027-08-10",
            "departure_on" => "2027-08-11",
            "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 20000}]
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-01-11",
            "group_id" => "dest",
            "amount_cents" => 1500
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-11")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 1800,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 700,
                     "expires_on" => "2028-01-10"
                   },
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 1100,
                     "expires_on" => "2028-01-10"
                   }
                 ]
               }
             }
    end

    test "restores applied credit on refundable cancel without a second bonus", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "arrival_on" => "2027-08-10",
            "departure_on" => "2027-08-13"
          }),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 3000
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-05",
            "group_id" => "dest",
            "refund_method" => "hotel_credit"
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
                   "retained_cents" => 0,
                   "credit_issued_cents" => 2200,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-05")

      assert %{
               "data" => %{
                 "available_cents" => 7700,
                 "lots" => lots
               }
             } = json_response(conn, 200)

      by_id = Map.new(lots, &{&1["source_operation_id"], &1})
      assert by_id["cancel-17"]["remaining_cents"] == 5500
      assert by_id["cancel-17"]["expires_on"] == "2028-05-02"
      assert by_id["cancel-dest"]["remaining_cents"] == 2200
      assert by_id["cancel-dest"]["expires_on"] == "2028-05-04"

      conn = get(conn, "/api/v1/ledger?on=2027-05-05")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 7000,
                 "credit_liability_cents" => 7700,
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "expires restored credit immediately when the original lot is past", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "occurred_on" => "2027-05-04",
            "arrival_on" => "2028-06-10",
            "departure_on" => "2028-06-13"
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2028-04-01",
            "group_id" => "dest",
            "amount_cents" => 5500
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2028-05-10",
            "group_id" => "dest"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2028-05-10")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      conn = get(conn, "/api/v1/ledger?on=2028-05-10")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "cash_converted_to_credit_cents" => 5000
               }
             } = json_response(conn, 200)
    end

    test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "rate_plan" => "advance_purchase",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-05",
            "group_id" => "dest"
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
                 %{"refunded_cents" => 0, "retained_cents" => 1000, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-05")

      assert %{
               "data" => %{
                 "available_cents" => 3500,
                 "lots" => [%{"remaining_cents" => 3500}]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-05")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_retained_cents" => 1000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 3500
               }
             } = json_response(conn, 200)
    end

    test "rejects apply_hotel_credit with existing payment errors and insufficient credit", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "missing",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "no-such",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "zero",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "over",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 19501
          },
          %{
            "operation_id" => "no-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "inactive",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{"operation_id" => "missing", "code" => "group_not_found"},
                 %{"operation_id" => "zero", "code" => "invalid_amount"},
                 %{"operation_id" => "over", "code" => "payment_exceeds_outstanding"},
                 %{"operation_id" => "no-credit", "code" => "insufficient_credit"},
                 %{"operation_id" => "op-cancel", "status" => "applied", "revision" => 2},
                 %{"operation_id" => "inactive", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)
    end

    test "does not increment revision on insufficient credit or rejected refund method", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "no-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 100,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "late-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          },
          pay_op(100)
        ])

      assert %{
               "results" => [
                 %{"revision" => 1},
                 %{"code" => "insufficient_credit"},
                 %{"code" => "refund_method_not_available"},
                 %{"status" => "applied", "revision" => 2}
               ]
             } = json_response(conn, 200)
    end

    test "checks stale revision before insufficient credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "stale",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 100,
            "expected_revision" => 9
          }
        ])

      assert %{
               "results" => [
                 _,
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 9,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "evaluates credit expiry from occurred_on and omits expired lots", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "arrival_on" => "2028-06-10",
            "departure_on" => "2028-06-13"
          }),
          %{
            "operation_id" => "too-late",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2028-05-03",
            "group_id" => "dest",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "on-time",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2028-05-02",
            "group_id" => "dest",
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"operation_id" => "too-late", "code" => "insufficient_credit"},
                 %{"operation_id" => "on-time", "status" => "applied", "revision" => 2}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2028-05-02")

      assert %{"data" => %{"available_cents" => 5400, "lots" => [_lot]}} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2028-05-03")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)
    end

    test "returns empty credit for an unknown guest and orders lots by expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "g1",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-11",
            "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 5000}]
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-late",
            "type" => "cancel_group",
            "occurred_on" => "2027-02-01",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "g2",
            "operation_id" => "o2",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-11",
            "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 5000}]
          }),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "g2",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-early",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-01",
            "group_id" => "g2",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-02-01")

      assert %{
               "data" => %{
                 "lots" => [
                   %{"source_operation_id" => "cancel-early", "expires_on" => "2028-01-01"},
                   %{"source_operation_id" => "cancel-late", "expires_on" => "2028-02-01"}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/nobody/credit")

      assert json_response(conn, 200) == %{
               "data" => %{"guest_id" => "nobody", "available_cents" => 0, "lots" => []}
             }
    end

    test "does not apply one guest's credit to another guest's group", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "other",
            "operation_id" => "o2",
            "guest_id" => "guest-99"
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "other",
            "amount_cents" => 1000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"code" => "insufficient_credit"}
               ]
             } = json_response(conn, 200)
    end

    test "refundable cash cancellation refunds cash and restores credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-03",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "arrival_on" => "2027-08-10",
            "departure_on" => "2027-08-13"
          }),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 3000
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-05",
            "group_id" => "dest",
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
                   "refunded_cents" => 2000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-05")

      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-05")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 2000,
                 "cash_converted_to_credit_cents" => 5000,
                 "credit_liability_cents" => 5500
               }
             } = json_response(conn, 200)
    end
  end

  describe "durable operations" do
    test "retries of an equivalent payload return the original result without reapplying", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_op(), pay_op(1000)])
      first = json_response(conn, 200)

      conn = post_batch(conn, [pay_op(1000)])
      assert json_response(conn, 200) == %{"results" => [List.last(first["results"])]}

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 1000,
                 "outstanding_deposit_cents" => 18500,
                 "revision" => 2
               }
             } = json_response(conn, 200)
    end

    test "object key order does not affect payload equivalence", %{conn: conn} do
      conn = post_batch(conn, [open_op()])
      first_open = hd(json_response(conn, 200)["results"])

      reordered_rooms = """
      {"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"nightly_rate_cents":17500,"room_id":"room-b"}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2026-10-03","type":"open_group","operation_id":"op-1001"}]}
      """

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", reordered_rooms)

      assert json_response(conn, 200) == %{"results" => [first_open]}

      reordered = """
      {"operations":[{"amount_cents":1000,"group_id":"group-81","occurred_on":"2026-10-04","operation_id":"op-pay","type":"record_cash_payment"}]}
      """

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", reordered)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "amount_cents" => 1000,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      same_keys_reordered = """
      {"operations":[{"type":"record_cash_payment","operation_id":"op-pay","occurred_on":"2026-10-04","group_id":"group-81","amount_cents":1000}]}
      """

      conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", same_keys_reordered)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "amount_cents" => 1000,
                   "outstanding_deposit_cents" => 18500,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"deposit_paid_cents" => 1000, "revision" => 2}} =
               json_response(conn, 200)
    end

    test "array order is significant for payload equivalence", %{conn: conn} do
      conn = post_batch(conn, [open_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_op(%{
            "rooms" => [
              %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
            ]
          })
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      conn = get(conn, "/api/v1/operations/op-1001")

      assert %{
               "data" => %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "revision" => 1
               }
             } = json_response(conn, 200)
    end

    test "remembered rejections are returned even after they would now be valid", %{conn: conn} do
      pay_missing = %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1000
      }

      conn = post_batch(conn, [pay_missing])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }

      conn = post_batch(conn, [open_op(), pay_missing])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} = json_response(conn, 200)
    end

    test "a conflicting payload does not replace the original record", %{conn: conn} do
      conn = post_batch(conn, [open_op()])
      original = hd(json_response(conn, 200)["results"])

      conn = post_batch(conn, [open_op(%{"group_id" => "group-other"})])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      conn = get(conn, "/api/v1/operations/op-1001")
      assert json_response(conn, 200) == %{"data" => original}

      conn = post_batch(conn, [open_op()])
      assert json_response(conn, 200) == %{"results" => [original]}

      conn = get(conn, "/api/v1/groups/group-other")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "GET returns the stored result and 404 when missing", %{conn: conn} do
      conn = post_batch(conn, [open_op()])
      result = hd(json_response(conn, 200)["results"])

      conn = get(conn, "/api/v1/operations/op-1001")
      assert json_response(conn, 200) == %{"data" => result}

      conn = get(conn, "/api/v1/operations/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "GET returns a stored rejection", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "unknown",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          }
        ])

      rejected = hd(json_response(conn, 200)["results"])
      assert rejected["code"] == "invalid_operation"

      conn = get(conn, "/api/v1/operations/unknown")
      assert json_response(conn, 200) == %{"data" => rejected}
    end

    test "a stale-revision retry returns the original actual_revision verbatim", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500,
            "expected_revision" => 1
          }
        ])

      stale = Enum.at(json_response(conn, 200)["results"], 2)

      assert stale == %{
               "operation_id" => "stale-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "fresh-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500
          }
        ])

      assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500,
            "expected_revision" => 1
          }
        ])

      assert json_response(conn, 200) == %{"results" => [stale]}

      conn = get(conn, "/api/v1/operations/stale-pay")
      assert json_response(conn, 200) == %{"data" => stale}
    end

    test "retrying a stale operation with a corrected expected_revision conflicts", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500,
            "expected_revision" => 1
          }
        ])

      assert %{"results" => [_, _, %{"code" => "stale_revision"}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500,
            "expected_revision" => 2
          }
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "stale-pay",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"deposit_paid_cents" => 1000, "revision" => 2}} =
               json_response(conn, 200)
    end

    test "an exact reschedule retry does not consult current group state", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "op-move-2",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-25"
          }
        ])

      first_move = Enum.at(json_response(conn, 200)["results"], 1)

      assert first_move["new_arrival_on"] == "2026-12-20"
      assert first_move["revision"] == 2

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert json_response(conn, 200) == %{"results" => [first_move]}

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "arrival_on" => "2026-12-25",
                 "departure_on" => "2026-12-28",
                 "revision" => 3
               }
             } = json_response(conn, 200)
    end

    test "duplicate identifiers in one batch return the stored result the second time", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_op(), open_op()])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1}} = json_response(conn, 200)
    end

    test "retrying a credit-issuing cancellation does not issue a second lot", %{conn: conn} do
      cancel = %{
        "operation_id" => "cancel-17",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "refund_method" => "hotel_credit"
      }

      conn = post_batch(conn, [open_op(), pay_op(5000), cancel])

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
                 %{"operation_id" => "cancel-17", "credit_issued_cents" => 5500, "revision" => 3}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-05")
      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)
    end

    test "durable records retain type, payload, and first-commit order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "bad",
            "type" => "explode_group",
            "occurred_on" => "2026-10-03"
          },
          pay_op(1000)
        ])

      assert %{"results" => [_, %{"code" => "invalid_operation"}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      records =
        GroupStay.Groups.Operation
        |> GroupStay.Repo.all()
        |> Enum.sort_by(& &1.id)

      assert Enum.map(records, & &1.operation_id) == ["op-1001", "bad", "op-pay"]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "explode_group",
               "record_cash_payment"
             ]

      assert hd(records).payload["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
             ]
    end
  end

  defp post_batch(conn, operations) do
    post_batch_raw(conn, %{"operations" => operations})
  end

  defp post_batch_raw(conn, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
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
end
