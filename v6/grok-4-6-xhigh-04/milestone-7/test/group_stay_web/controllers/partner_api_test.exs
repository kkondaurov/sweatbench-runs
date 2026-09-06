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
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15000,
                     "status" => "active",
                     "deposit_due_cents" => 9000,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17500,
                     "status" => "active",
                     "deposit_due_cents" => 10500,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 5500,
                 "credit_shortfall_cents" => 0
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

  describe "room accounting and payment reductions" do
    test "allocates cash to rooms in original order", %{conn: conn} do
      conn = post_batch(conn, [open_op(), pay_op(10000)])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "deposit_due_cents" => 19500,
                 "cash_paid_cents" => 10000,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "active",
                     "deposit_due_cents" => 9000,
                     "cash_paid_cents" => 9000,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "active",
                     "deposit_due_cents" => 10500,
                     "cash_paid_cents" => 1000,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = json_response(conn, 200)
    end

    test "legacy unattributed funding is a senior block before durable payments", %{conn: conn} do
      {:ok, _} =
        %GroupStay.Groups.Group{}
        |> GroupStay.Groups.Group.changeset(%{
          group_id: "legacy-fund",
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
          deposit_paid_cents: 5000,
          cash_paid_cents: 5000,
          rooms: [
            %{room_id: "room-a", nightly_rate_cents: 15000},
            %{room_id: "room-b", nightly_rate_cents: 17500}
          ]
        })
        |> GroupStay.Repo.insert()

      conn = get(conn, "/api/v1/groups/legacy-fund")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 5000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 5000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "pay-new",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "legacy-fund",
            "amount_cents" => 4000
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/legacy-fund")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 9000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "cancel_rooms settles selected rooms and keeps the others", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-b", "room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "operation_id" => "cancel-a",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "cancelled_room_ids" => ["room-a", "room-b"],
                   "refunded_cents" => 10000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "lodging_total_cents" => 0,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{"room_id" => "room-a", "status" => "cancelled", "cash_paid_cents" => 0},
                   %{"room_id" => "room-b", "status" => "cancelled", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "cancel_rooms of one room leaves the group active with remaining totals", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "cancelled_room_ids" => ["room-a"],
                   "refunded_cents" => 9000,
                   "retained_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 52500,
                 "deposit_due_cents" => 10500,
                 "deposit_paid_cents" => 1000,
                 "cash_paid_cents" => 1000,
                 "outstanding_deposit_cents" => 9500,
                 "revision" => 3,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "cancelled",
                     "deposit_due_cents" => 9000,
                     "cash_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "active",
                     "deposit_due_cents" => 10500,
                     "cash_paid_cents" => 1000
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 1000,
                 "cash_refunded_cents" => 9000,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "cancel_rooms issues one hotel-credit bonus on combined cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 25},
              %{"room_id" => "room-b", "nightly_rate_cents" => 25}
            ]
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10
          },
          %{
            "operation_id" => "cancel-rooms",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "credit_issued_cents" => 11,
                   "refunded_cents" => 0,
                   "retained_cents" => 0
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects cancel_rooms with invalid room identifiers", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "dup",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a", "room-a"]
          },
          %{
            "operation_id" => "missing",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-z"]
          },
          %{
            "operation_id" => "empty",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => []
          },
          %{
            "operation_id" => "ok",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "already",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"operation_id" => "dup", "code" => "invalid_rooms"},
                 %{"operation_id" => "missing", "code" => "invalid_rooms"},
                 %{"operation_id" => "empty", "code" => "invalid_rooms"},
                 %{"operation_id" => "ok", "status" => "applied", "revision" => 2},
                 %{"operation_id" => "already", "code" => "invalid_rooms"}
               ]
             } = json_response(conn, 200)
    end

    test "cancel_group settles only remaining active rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "cancel-rest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"refunded_cents" => 9000},
                 %{
                   "status" => "applied",
                   "refunded_cents" => 1000,
                   "retained_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "cancelled", "revision" => 4}} = json_response(conn, 200)
    end

    test "reduce_cash_payment removes held cash in reverse fill order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1500
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "operation_id" => "reduce-1",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "amount_cents" => 1500,
                   "outstanding_deposit_cents" => 11000,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 8500,
                 "outstanding_deposit_cents" => 11000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 8500},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 8500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1500,
                 "charged_back_cents" => 0
               }
             }

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 8500,
                 "cash_reduced_cents" => 1500,
                 "cash_refunded_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "successive reductions compose and a full remaining amount is valid", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 3000
          },
          %{
            "operation_id" => "reduce-2",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 7000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "amount_cents" => 3000, "revision" => 3},
                 %{
                   "status" => "applied",
                   "amount_cents" => 7000,
                   "outstanding_deposit_cents" => 19500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "reduced_cents" => 10000,
                 "recorded_cents" => 10000
               }
             } = json_response(conn, 200)
    end

    test "reduce_cash_payment rejection codes", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "no-op",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "missing-pay",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "not-pay",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-1001",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "zero",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "over",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1001
          },
          %{
            "operation_id" => "all",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "gone",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"operation_id" => "no-op", "code" => "operation_not_found"},
                 %{"operation_id" => "not-pay", "code" => "payment_not_reducible"},
                 %{"operation_id" => "zero", "code" => "invalid_amount"},
                 %{"operation_id" => "over", "code" => "reduction_exceeds_held_cash"},
                 %{"operation_id" => "all", "status" => "applied"},
                 %{"operation_id" => "gone", "code" => "payment_not_reducible"}
               ]
             } = json_response(conn, 200)
    end

    test "retrying the original payment after a reduction returns the original result", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_op(), pay_op(10000)])
      original = Enum.at(json_response(conn, 200)["results"], 1)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [pay_op(10000)])
      assert json_response(conn, 200) == %{"results" => [original]}

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"cash_paid_cents" => 8000, "revision" => 3}} = json_response(conn, 200)
    end

    test "cancel_rooms and reduce_cash_payment are durably idempotent", %{conn: conn} do
      cancel = %{
        "operation_id" => "cancel-a",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      }

      reduce = %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 500
      }

      conn = post_batch(conn, [open_op(), pay_op(10000), cancel, reduce])
      results = json_response(conn, 200)["results"]
      cancel_result = Enum.at(results, 2)
      reduce_result = Enum.at(results, 3)

      conn = post_batch(conn, [cancel, reduce])
      assert json_response(conn, 200) == %{"results" => [cancel_result, reduce_result]}

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 500}} = json_response(conn, 200)
    end

    test "charge_back_payment reverses held cash and reopens outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "operation_id" => "cb-1",
                   "status" => "applied",
                   "payment_operation_id" => "op-pay",
                   "group_id" => "group-81",
                   "charged_back_cents" => 10000,
                   "outstanding_deposit_cents" => 19500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "status" => "active",
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500,
                 "revision" => 3
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert %{
               "data" => %{
                 "recorded_cents" => 10000,
                 "held_cents" => 0,
                 "charged_back_cents" => 10000,
                 "reduced_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_charged_back_cents" => 10000,
                 "cash_reduced_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "chargeback reclassifies refunded cash and skips already reduced cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1500
          },
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"refunded_cents" => 8500},
                 %{
                   "status" => "applied",
                   "charged_back_cents" => 8500,
                   "revision" => 5
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1500,
                 "charged_back_cents" => 8500
               }
             }

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_reduced_cents" => 1500,
                 "cash_charged_back_cents" => 8500
               }
             } = json_response(conn, 200)
    end

    test "chargeback of converted cash revokes unspent credit entitlement", %{conn: conn} do
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
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"credit_issued_cents" => 5500},
                 %{"status" => "applied", "charged_back_cents" => 5000, "revision" => 4}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-03")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-03")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 5000,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"status" => "cancelled", "revision" => 4}} = json_response(conn, 200)
    end

    test "chargeback clawback creates a shortfall on applied credit and absorbs restorations", %{
      conn: conn
    } do
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
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 4000
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "p1"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"revision" => 1},
                 %{"revision" => 2},
                 %{"status" => "applied", "charged_back_cents" => 5000, "revision" => 4}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/dest")

      assert %{
               "data" => %{"credit_paid_cents" => 4000, "revision" => 2, "status" => "active"}
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-04")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 4000,
                 "credit_shortfall_cents" => 4000,
                 "cash_charged_back_cents" => 5000
               }
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-05",
            "group_id" => "dest"
          }
        ])

      assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-05")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-05")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "non-refundable settlement of applied credit clears shortfall", %{conn: conn} do
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
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "p1"
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-05",
            "group_id" => "dest"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 5)["status"] == "applied"
      assert Enum.at(results, 6)["status"] == "applied"

      conn = get(conn, "/api/v1/ledger?on=2027-05-05")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "telescoping entitlements across two payments in one lot", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "pay-a",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 10000
          },
          %{
            "operation_id" => "pay-b",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => [_, _, _, %{"credit_issued_cents" => 16500}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cb-a",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-a"
          }
        ])

      assert %{"results" => [%{"charged_back_cents" => 10000}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-05")
      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cb-b",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-b"
          }
        ])

      assert %{"results" => [%{"charged_back_cents" => 5000}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-05")
      assert %{"data" => %{"available_cents" => 0}} = json_response(conn, 200)
    end

    test "chargeback rejection codes and cancelled groups remain chargeable", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          %{
            "operation_id" => "missing",
            "type" => "charge_back_payment",
            "payment_operation_id" => "no-such"
          },
          %{
            "operation_id" => "not-pay",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-1001"
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          },
          %{
            "operation_id" => "cb-2",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"code" => "operation_not_found"},
                 %{"code" => "payment_not_chargeable"},
                 %{"status" => "applied", "refunded_cents" => 5000},
                 %{"status" => "applied", "charged_back_cents" => 5000, "revision" => 4},
                 %{"code" => "payment_not_chargeable"}
               ]
             } = json_response(conn, 200)
    end

    test "GET payment is 404 or 422 for unusable identifiers", %{conn: conn} do
      conn = post_batch(conn, [open_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

      conn = get(conn, "/api/v1/payments/op-1001")
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    test "stale revision is checked before reduce and chargeback domain rules", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          %{
            "operation_id" => "stale-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 0,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "stale-cb",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2,
                   "group_id" => "group-81"
                 },
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "charge_back_payment is durably idempotent and fully reduced payments are not chargeable",
         %{conn: conn} do
      charge = %{
        "operation_id" => "cb-1",
        "type" => "charge_back_payment",
        "payment_operation_id" => "op-pay"
      }

      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "pay-gone",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "reduce-all",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "pay-gone",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cb-gone",
            "type" => "charge_back_payment",
            "payment_operation_id" => "pay-gone"
          },
          pay_op(5000),
          charge
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.at(results, 3)["code"] == "payment_not_chargeable"
      charge_result = Enum.at(results, 5)
      assert charge_result["status"] == "applied"
      assert charge_result["charged_back_cents"] == 5000

      conn = post_batch(conn, [charge])
      assert json_response(conn, 200) == %{"results" => [charge_result]}

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 5, "cash_paid_cents" => 0}} = json_response(conn, 200)
    end

    test "restoring credit to an expired shortfalled lot absorbs clawback first", %{conn: conn} do
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
            "operation_id" => "p2",
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
            "amount_cents" => 10000
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "p1"
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2028-05-10",
            "group_id" => "dest"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 6)["status"] == "applied"
      assert Enum.at(results, 7)["status"] == "applied"

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2028-05-10")
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2028-05-10")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "excess restored to a shortfalled lot before expiry becomes available", %{conn: conn} do
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
            "operation_id" => "p2",
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
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-05-04",
            "group_id" => "dest",
            "amount_cents" => 10000
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "p1"
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-05",
            "group_id" => "dest"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 6)["status"] == "applied"
      assert Enum.at(results, 7)["status"] == "applied"

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2027-05-05")
      assert %{"data" => %{"available_cents" => 5500}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2027-05-05")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 5500,
                 "credit_shortfall_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "new funding after a reduction fills rooms in original order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1500
          },
          %{
            "operation_id" => "pay-2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "amount_cents" => 1500
          }
        ])

      assert %{"results" => [_, _, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 10000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 1000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "transfer_deposit moves held cash between active groups of the same guest", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op()
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "xfer-1",
                   "status" => "applied",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-92",
                   "amount_cents" => 1000,
                   "source_outstanding_deposit_cents" => 10500,
                   "destination_outstanding_deposit_cents" => 18500,
                   "source_revision" => 3,
                   "destination_revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 9000,
                 "outstanding_deposit_cents" => 10500,
                 "revision" => 3,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 1000,
                 "outstanding_deposit_cents" => 18500,
                 "revision" => 2,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 1000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 10000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "transfer draws mixed funding in reverse allocation order and fills destination in room order",
         %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "credit-src",
            "operation_id" => "open-credit-src",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 5000}]
          }),
          %{
            "operation_id" => "pay-credit-src",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "credit-src",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-credit-src",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "credit-src",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "source",
            "operation_id" => "open-source",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
            ]
          }),
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "source",
            "amount_cents" => 1500
          },
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "source",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "pay-2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "source",
            "amount_cents" => 500
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "open-dest",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
              %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
            ]
          }),
          transfer_op(%{
            "source_group_id" => "source",
            "destination_group_id" => "dest",
            "amount_cents" => 1200
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 8)["status"] == "applied"
      assert Enum.at(results, 8)["amount_cents"] == 1200

      conn = get(conn, "/api/v1/groups/source")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 1500,
                 "credit_paid_cents" => 300,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 1500,
                     "credit_paid_cents" => 300
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/dest")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 500,
                 "credit_paid_cents" => 700,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 500,
                     "credit_paid_cents" => 700
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "transfer rejection order and codes", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          open_op(%{
            "group_id" => "other-guest",
            "operation_id" => "open-other",
            "guest_id" => "guest-99"
          }),
          transfer_op(%{
            "operation_id" => "same",
            "destination_group_id" => "group-81",
            "amount_cents" => 100
          }),
          transfer_op(%{
            "operation_id" => "other-guest",
            "destination_group_id" => "other-guest",
            "amount_cents" => 100
          }),
          transfer_op(%{
            "operation_id" => "missing-source",
            "source_group_id" => "no-source",
            "destination_group_id" => "no-dest",
            "amount_cents" => 100
          }),
          transfer_op(%{
            "operation_id" => "missing-dest",
            "destination_group_id" => "no-dest",
            "amount_cents" => 100
          }),
          transfer_op(%{
            "operation_id" => "stale-source",
            "expected_revision" => 1,
            "destination_expected_revision" => 99,
            "amount_cents" => 100
          }),
          transfer_op(%{
            "operation_id" => "stale-dest",
            "expected_revision" => 2,
            "destination_expected_revision" => 99,
            "amount_cents" => 100
          }),
          transfer_op(%{"operation_id" => "zero", "amount_cents" => 0}),
          transfer_op(%{"operation_id" => "over-held", "amount_cents" => 1001}),
          %{
            "operation_id" => "pay-dest",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-92",
            "amount_cents" => 19000
          },
          transfer_op(%{"operation_id" => "exceed-dest", "amount_cents" => 1000})
        ])

      assert %{
               "results" => results
             } = json_response(conn, 200)

      assert Enum.at(results, 4)["code"] == "invalid_transfer"
      assert Enum.at(results, 5)["code"] == "invalid_transfer"

      assert Enum.at(results, 6) == %{
               "operation_id" => "missing-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "no-source"
             }

      assert Enum.at(results, 7) == %{
               "operation_id" => "missing-dest",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "no-dest"
             }

      assert Enum.at(results, 8)["code"] == "stale_revision"
      assert Enum.at(results, 8)["group_id"] == "group-81"
      assert Enum.at(results, 8)["expected_revision"] == 1
      assert Enum.at(results, 8)["actual_revision"] == 2

      assert Enum.at(results, 9)["code"] == "stale_revision"
      assert Enum.at(results, 9)["group_id"] == "group-92"
      assert Enum.at(results, 9)["expected_revision"] == 99
      assert Enum.at(results, 9)["actual_revision"] == 1

      assert Enum.at(results, 10)["code"] == "invalid_amount"
      assert Enum.at(results, 11)["code"] == "transfer_exceeds_held_funding"
      assert Enum.at(results, 13)["code"] == "transfer_exceeds_outstanding"
    end

    test "group_not_active names the inactive group, source first", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          %{
            "operation_id" => "cancel-source",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          transfer_op(%{"operation_id" => "src-inactive", "amount_cents" => 100})
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "code" => "group_not_active",
                   "group_id" => "group-81"
                 }
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_op(%{"group_id" => "group-93", "operation_id" => "open-93"}),
          %{
            "operation_id" => "pay-93",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-93",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-92"
          },
          transfer_op(%{
            "operation_id" => "dest-inactive",
            "source_group_id" => "group-93",
            "amount_cents" => 100
          })
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 %{"code" => "group_not_active", "group_id" => "group-92"}
               ]
             } = json_response(conn, 200)
    end

    test "payment statement gains held_by_group after any transfer of that payment", %{
      conn: conn
    } do
      conn = post_batch(conn, [open_op(), pay_op(10000)])
      assert %{"results" => [_, _]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")
      statement = json_response(conn, 200)["data"]
      refute Map.has_key?(statement, "held_by_group")

      conn = post_batch(conn, [open_dest(), transfer_op()])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "payment_operation_id" => "op-pay",
                 "original_group_id" => "group-81",
                 "recorded_cents" => 10000,
                 "held_cents" => 10000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "group-81", "amount_cents" => 9000},
                   %{"group_id" => "group-92", "amount_cents" => 1000}
                 ]
               }
             }

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-all-held",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 10000
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "reduced_cents" => 10000,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)
    end

    test "reductions follow transferred cash in reverse allocation order across groups", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op(),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 500
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "outstanding_deposit_cents" => 10500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 500,
                 "revision" => 3,
                 "outstanding_deposit_cents" => 19000
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 9000,
                 "revision" => 4
               }
             } = json_response(conn, 200)
    end

    test "chargeback of transferred cash updates both groups and reports the original group's revision",
         %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op(),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "status" => "applied",
                   "group_id" => "group-81",
                   "charged_back_cents" => 10000,
                   "outstanding_deposit_cents" => 19500,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500,
                 "revision" => 4
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500,
                 "revision" => 3
               }
             } = json_response(conn, 200)
    end

    test "transferred cash settles under the destination policy and can convert with a bonus", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(%{
            "rate_plan" => "advance_purchase",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13"
          }),
          transfer_op(),
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-92"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"refunded_cents" => 0, "retained_cents" => 1000, "credit_issued_cents" => 0}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          open_op(%{"group_id" => "group-94", "operation_id" => "open-94"}),
          %{
            "operation_id" => "pay-94",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-94",
            "amount_cents" => 2000
          },
          open_op(%{
            "group_id" => "group-95",
            "operation_id" => "open-95",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          transfer_op(%{
            "operation_id" => "xfer-convert",
            "source_group_id" => "group-94",
            "destination_group_id" => "group-95",
            "amount_cents" => 2000
          }),
          %{
            "operation_id" => "cancel-95",
            "type" => "cancel_group",
            "occurred_on" => "2027-05-01",
            "group_id" => "group-95",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 2200
                 }
               ]
             } = json_response(conn, 200)
    end

    test "transferred hotel credit restores to its original lot without a second bonus", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(%{
            "group_id" => "credit-src",
            "operation_id" => "open-credit-src",
            "arrival_on" => "2026-12-20",
            "departure_on" => "2026-12-21",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
          }),
          %{
            "operation_id" => "pay-credit-src",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "credit-src",
            "amount_cents" => 1000
          },
          %{
            "operation_id" => "cancel-credit-src",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "credit-src",
            "refund_method" => "hotel_credit"
          },
          open_op(%{"group_id" => "source", "operation_id" => "open-source"}),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "source",
            "amount_cents" => 1100
          },
          open_dest(),
          transfer_op(%{
            "source_group_id" => "source",
            "destination_group_id" => "group-92",
            "amount_cents" => 1100
          }),
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-07",
            "group_id" => "group-92"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 6)["status"] == "applied"

      assert Enum.at(results, 7)["status"] == "applied"
      assert Enum.at(results, 7)["refunded_cents"] == 0
      assert Enum.at(results, 7)["credit_issued_cents"] == 0

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-10-07")

      assert %{
               "data" => %{
                 "available_cents" => 1100,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-credit-src",
                     "remaining_cents" => 1100,
                     "expires_on" => "2027-10-05"
                   }
                 ]
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger?on=2026-10-07")

      assert %{
               "data" => %{
                 "credit_liability_cents" => 1100
               }
             } = json_response(conn, 200)
    end

    test "chargeback reclassifies dest-settled transferred cash on the groups that hold it", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op(),
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-92"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{"refunded_cents" => 1000},
                 %{
                   "status" => "applied",
                   "charged_back_cents" => 10000,
                   "group_id" => "group-81",
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-92")
      assert %{"data" => %{"status" => "cancelled", "revision" => 4}} = json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "charged_back_cents" => 10000,
                 "held_by_group" => []
               }
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 10000
               }
             } = json_response(conn, 200)
    end

    test "reduce expected_revision is checked only against the original payment group", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op(),
          %{
            "operation_id" => "stale-on-dest-rev",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 500,
            "expected_revision" => 2
          },
          %{
            "operation_id" => "ok-on-source-rev",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 500,
            "expected_revision" => 3
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 _,
                 %{
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "actual_revision" => 3
                 },
                 %{"status" => "applied", "revision" => 4}
               ]
             } = json_response(conn, 200)
    end

    test "destination fill continues in original room order after existing dest funding", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          %{
            "operation_id" => "pay-dest",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-92",
            "amount_cents" => 9000
          },
          transfer_op()
        ])

      assert %{"results" => [_, _, _, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/groups/group-92")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 1000}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "transfer_deposit is durably idempotent and visible later in the same batch", %{
      conn: conn
    } do
      xfer = transfer_op()

      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          open_dest(),
          xfer,
          %{
            "operation_id" => "pay-after",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-92",
            "amount_cents" => 500
          }
        ])

      results = json_response(conn, 200)["results"]
      xfer_result = Enum.at(results, 3)
      assert xfer_result["status"] == "applied"
      assert Enum.at(results, 4)["status"] == "applied"
      assert Enum.at(results, 4)["outstanding_deposit_cents"] == 18000

      conn = post_batch(conn, [xfer])
      assert json_response(conn, 200) == %{"results" => [xfer_result]}

      conn = get(conn, "/api/v1/groups/group-92")
      assert %{"data" => %{"cash_paid_cents" => 1500, "revision" => 3}} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "xfer-1", "amount_cents" => 2000})
        ])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)
    end

    test "reduce does not move settled cash from cancelled rooms", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10000),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          },
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"refunded_cents" => 9000},
                 %{"code" => "reduction_exceeds_held_cash"}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "reduce-held",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          }
        ])

      assert %{"results" => [%{"status" => "applied", "amount_cents" => 1000}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/payments/op-pay")

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "refunded_cents" => 9000,
                 "reduced_cents" => 1000,
                 "recorded_cents" => 10000
               }
             } = json_response(conn, 200)
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

  defp open_dest(overrides \\ %{}) do
    open_op(
      Map.merge(
        %{
          "operation_id" => "op-1002",
          "group_id" => "group-92",
          "property_id" => "rot-centre"
        },
        overrides
      )
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "xfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 1000
      },
      overrides
    )
  end
end
