defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = submit_body(conn, %{"operations" => %{}})

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "opens a group, uses per-room deposit rounding, and exposes the group", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 103},
              %{"room_id" => "room-b", "nightly_rate_cents" => 103}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 42,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), ~p"/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-1",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-11",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 103},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 103}
                 ],
                 "lodging_total_cents" => 206,
                 "deposit_due_cents" => 42,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 42
               }
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "processes changes in array order and increments the revision for each applied operation",
         %{
           conn: conn
         } do
      conn =
        submit(conn, [
          open_group(),
          %{
            "operation_id" => "payment-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 60,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "reschedule-1",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-12-15",
            "expected_revision" => 2
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-1", "revision" => 1, "deposit_due_cents" => 200},
                 %{
                   "operation_id" => "payment-1",
                   "status" => "applied",
                   "amount_cents" => 60,
                   "outstanding_deposit_cents" => 140,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "reschedule-1",
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-15",
                   "new_departure_on" => "2026-12-17",
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 3,
                 "arrival_on" => "2026-12-15",
                 "departure_on" => "2026-12-17",
                 "deposit_paid_cents" => 60,
                 "outstanding_deposit_cents" => 140
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 60,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "rejects stale revisions before other validation and leaves state untouched", %{
      conn: conn
    } do
      submit(conn, [open_group()])

      conn =
        submit(build_conn(), [
          %{
            "operation_id" => "payment-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 10
          },
          %{
            "operation_id" => "stale-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-1",
            "amount_cents" => 999,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "missing-group",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "does-not-exist",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "payment-1", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "stale-payment",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-1",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "missing-group",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "deposit_paid_cents" => 10,
                 "outstanding_deposit_cents" => 190
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 10,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "settles refundable and non-refundable cancellations and prevents later active-only work",
         %{
           conn: conn
         } do
      submit(conn, [open_group(), payment("payment-1", "group-1", 100)])

      conn =
        submit(build_conn(), [
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-1",
            "expected_revision" => 2
          },
          payment("payment-after-cancel", "group-1", 1),
          %{
            "operation_id" => "reschedule-after-cancel",
            "type" => "reschedule_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "cancel-after-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-1"
          }
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-1",
                   "status" => "applied",
                   "refunded_cents" => 100,
                   "retained_cents" => 0,
                   "revision" => 3
                 },
                 %{"operation_id" => "payment-after-cancel", "code" => "group_not_active"},
                 %{"operation_id" => "reschedule-after-cancel", "code" => "group_not_active"},
                 %{"operation_id" => "cancel-after-cancel", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 3,
                 "deposit_paid_cents" => 100,
                 "outstanding_deposit_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)

      conn =
        submit(build_conn(), [
          open_group(%{
            "operation_id" => "open-advance",
            "group_id" => "group-advance",
            "rate_plan" => "advance_purchase"
          }),
          payment("payment-advance", "group-advance", 500),
          %{
            "operation_id" => "cancel-advance",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-advance"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-advance", "deposit_due_cents" => 1_000},
                 %{"operation_id" => "payment-advance", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-advance",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 500
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 500
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)

      conn =
        submit(build_conn(), [
          open_group(%{
            "operation_id" => "open-late-flexible",
            "group_id" => "group-late-flexible"
          }),
          payment("payment-late-flexible", "group-late-flexible", 200),
          %{
            "operation_id" => "cancel-late-flexible",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-late-flexible"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-late-flexible", "status" => "applied"},
                 %{"operation_id" => "payment-late-flexible", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-late-flexible",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 200
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 700
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "rejects invalid operations without rolling back earlier work or blocking later work", %{
      conn: conn
    } do
      conn =
        submit(conn, [
          %{"operation_id" => "unknown", "type" => "mystery"},
          open_group(%{
            "operation_id" => "bad-stay",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          }),
          open_group(%{"operation_id" => "bad-date", "arrival_on" => "not-a-calendar-date"}),
          open_group(%{"operation_id" => "bad-rate-plan", "rate_plan" => "member-special"}),
          open_group(%{
            "operation_id" => "bad-rooms",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 500}
            ]
          }),
          open_group(),
          %{
            "operation_id" => "missing-data",
            "type" => "record_cash_payment",
            "group_id" => "group-1"
          },
          open_group(%{"operation_id" => "duplicate", "group_id" => "group-1"}),
          %{
            "operation_id" => "too-much",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 201
          },
          %{
            "operation_id" => "zero-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "invalid-reschedule",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-10-04"
          },
          %{
            "operation_id" => "missing-reschedule-date",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "unknown", "code" => "invalid_operation"},
                 %{"operation_id" => "bad-stay", "code" => "invalid_stay"},
                 %{"operation_id" => "bad-date", "code" => "invalid_stay"},
                 %{"operation_id" => "bad-rate-plan", "code" => "invalid_rate_plan"},
                 %{"operation_id" => "bad-rooms", "code" => "invalid_rooms"},
                 %{"operation_id" => "open-1", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "missing-data", "code" => "invalid_operation"},
                 %{"operation_id" => "duplicate", "code" => "group_already_exists"},
                 %{"operation_id" => "too-much", "code" => "payment_exceeds_outstanding"},
                 %{"operation_id" => "zero-payment", "code" => "invalid_amount"},
                 %{"operation_id" => "invalid-reschedule", "code" => "invalid_stay"},
                 %{"operation_id" => "missing-reschedule-date", "code" => "invalid_operation"}
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)
    end

    test "fixes policy versions at opening and recomputes their refundable dates on reschedule",
         %{
           conn: conn
         } do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-legacy-flex",
            "group_id" => "legacy-flex",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-12"
          }),
          open_group(%{
            "operation_id" => "open-new-flex",
            "group_id" => "new-flex",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-12"
          }),
          open_group(%{
            "operation_id" => "open-advance-policy",
            "group_id" => "advance-policy",
            "rate_plan" => "advance_purchase"
          }),
          %{
            "operation_id" => "move-legacy-flex",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-02",
            "group_id" => "legacy-flex",
            "new_arrival_on" => "2027-04-10",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-legacy-flex", "revision" => 1},
                 %{"operation_id" => "open-new-flex", "revision" => 1},
                 %{"operation_id" => "open-advance-policy", "revision" => 1},
                 %{
                   "operation_id" => "move-legacy-flex",
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-03-27",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "arrival_on" => "2027-04-10",
                 "refundable_until" => "2027-03-27"
               }
             } = get(build_conn(), ~p"/api/v1/groups/legacy-flex") |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-02-08"
               }
             } = get(build_conn(), ~p"/api/v1/groups/new-flex") |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get(build_conn(), ~p"/api/v1/groups/advance-policy") |> json_response(200)
    end

    test "converts refundable cash to credit and restores applied credit on a refundable cancellation",
         %{
           conn: conn
         } do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-credit-source",
            "group_id" => "credit-source",
            "guest_id" => "guest-credit"
          }),
          payment("fund-credit-source", "credit-source", 100),
          %{
            "operation_id" => "cancel-credit-source",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "credit-source",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          },
          open_group(%{
            "operation_id" => "open-credit-target",
            "group_id" => "credit-target",
            "guest_id" => "guest-credit"
          }),
          %{
            "operation_id" => "apply-credit-target",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-02",
            "group_id" => "credit-target",
            "amount_cents" => 80,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "cancel-credit-target",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-03",
            "group_id" => "credit-target",
            "expected_revision" => 2
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-credit-source", "status" => "applied"},
                 %{"operation_id" => "fund-credit-source", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-credit-source",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 110,
                   "revision" => 3
                 },
                 %{"operation_id" => "open-credit-target", "status" => "applied"},
                 %{
                   "operation_id" => "apply-credit-target",
                   "status" => "applied",
                   "amount_cents" => 80,
                   "outstanding_deposit_cents" => 120,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "cancel-credit-target",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 80,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 80,
                 "outstanding_deposit_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/credit-target") |> json_response(200)

      assert %{
               "data" => %{
                 "guest_id" => "guest-credit",
                 "available_cents" => 110,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-credit-source",
                     "remaining_cents" => 110,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-credit/credit?on=2027-11-01")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 100,
                 "credit_liability_cents" => 110
               }
             } =
               get(build_conn(), "/api/v1/ledger?on=2027-11-01") |> json_response(200)
    end

    test "rejects unavailable credit refunds without advancing a revision and consumes credit on a non-refundable cancellation",
         %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-nonref-source",
            "group_id" => "nonref-source",
            "guest_id" => "guest-nonref"
          }),
          payment("fund-nonref-source", "nonref-source", 100),
          %{
            "operation_id" => "cancel-nonref-source",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "nonref-source",
            "refund_method" => "hotel_credit"
          },
          open_group(%{
            "operation_id" => "open-nonref-target",
            "group_id" => "nonref-target",
            "guest_id" => "guest-nonref",
            "rate_plan" => "advance_purchase"
          }),
          %{
            "operation_id" => "apply-nonref-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-02",
            "group_id" => "nonref-target",
            "amount_cents" => 40
          },
          %{
            "operation_id" => "stale-credit-refund",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-03",
            "group_id" => "nonref-target",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          },
          %{
            "operation_id" => "unavailable-credit-refund",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-03",
            "group_id" => "nonref-target",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          },
          %{
            "operation_id" => "insufficient-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-03",
            "group_id" => "nonref-target",
            "amount_cents" => 100,
            "expected_revision" => 2
          },
          %{
            "operation_id" => "cancel-nonref-target",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-03",
            "group_id" => "nonref-target",
            "expected_revision" => 2
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-nonref-source", "status" => "applied"},
                 %{"operation_id" => "fund-nonref-source", "status" => "applied"},
                 %{"operation_id" => "cancel-nonref-source", "credit_issued_cents" => 110},
                 %{"operation_id" => "open-nonref-target", "revision" => 1},
                 %{"operation_id" => "apply-nonref-credit", "revision" => 2},
                 %{
                   "operation_id" => "stale-credit-refund",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "unavailable-credit-refund",
                   "code" => "refund_method_not_available"
                 },
                 %{"operation_id" => "insufficient-credit", "code" => "insufficient_credit"},
                 %{
                   "operation_id" => "cancel-nonref-target",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 3,
                 "credit_paid_cents" => 40
               }
             } = get(build_conn(), ~p"/api/v1/groups/nonref-target") |> json_response(200)

      assert %{
               "data" => %{
                 "guest_id" => "guest-nonref",
                 "available_cents" => 70,
                 "lots" => [%{"remaining_cents" => 70}]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-nonref/credit?on=2027-11-01")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 70}} =
               get(build_conn(), "/api/v1/ledger?on=2027-11-01") |> json_response(200)
    end

    test "expires available credit on reads and expires restored credit when its original lot has passed",
         %{
           conn: conn
         } do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-expiring-source",
            "group_id" => "expiring-source",
            "guest_id" => "guest-expiring"
          }),
          payment("fund-expiring-source", "expiring-source", 100),
          %{
            "operation_id" => "cancel-expiring-source",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "expiring-source",
            "refund_method" => "hotel_credit"
          },
          open_group(%{
            "operation_id" => "open-expiring-target",
            "group_id" => "expiring-target",
            "guest_id" => "guest-expiring",
            "arrival_on" => "2027-12-30",
            "departure_on" => "2028-01-01"
          }),
          %{
            "operation_id" => "apply-expiring-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-02",
            "group_id" => "expiring-target",
            "amount_cents" => 50
          },
          %{
            "operation_id" => "cancel-expiring-target",
            "type" => "cancel_group",
            "occurred_on" => "2027-11-02",
            "group_id" => "expiring-target"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-expiring-source", "status" => "applied"},
                 %{"operation_id" => "fund-expiring-source", "status" => "applied"},
                 %{"operation_id" => "cancel-expiring-source", "credit_issued_cents" => 110},
                 %{"operation_id" => "open-expiring-target", "status" => "applied"},
                 %{"operation_id" => "apply-expiring-credit", "amount_cents" => 50},
                 %{"operation_id" => "cancel-expiring-target", "status" => "applied"}
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get(build_conn(), "/api/v1/guests/guest-expiring/credit?on=2027-11-02")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get(build_conn(), "/api/v1/ledger?on=2027-11-02") |> json_response(200)
    end

    test "orders equal-expiry lots by source operation and consumes them in that order", %{
      conn: conn
    } do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-lot-z",
            "group_id" => "lot-z",
            "guest_id" => "guest-lot-order"
          }),
          payment("fund-lot-z", "lot-z", 10),
          %{
            "operation_id" => "cancel-z",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "lot-z",
            "refund_method" => "hotel_credit"
          },
          open_group(%{
            "operation_id" => "open-lot-a",
            "group_id" => "lot-a",
            "guest_id" => "guest-lot-order"
          }),
          payment("fund-lot-a", "lot-a", 10),
          %{
            "operation_id" => "cancel-a",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "lot-a",
            "refund_method" => "hotel_credit"
          },
          open_group(%{
            "operation_id" => "open-lot-target",
            "group_id" => "lot-target",
            "guest_id" => "guest-lot-order"
          }),
          %{
            "operation_id" => "apply-ordered-lots",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-02",
            "group_id" => "lot-target",
            "amount_cents" => 15
          }
        ])

      assert %{
               "results" => [
                 %{},
                 %{},
                 %{},
                 %{},
                 %{},
                 %{},
                 %{},
                 %{"operation_id" => "apply-ordered-lots", "status" => "applied"}
               ]
             } =
               json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 7,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-z",
                     "remaining_cents" => 7,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-lot-order/credit?on=2027-11-01")
               |> json_response(200)
    end

    test "replays an equivalent operation verbatim without applying it twice", %{conn: conn} do
      first_payload =
        ~s({"operations":[{"operation_id":"retry-open","type":"open_group","occurred_on":"2026-10-03","group_id":"retry-group","guest_id":"retry-guest","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-12","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":500}]}]})

      reordered_payload =
        ~s({"operations":[{"rooms":[{"nightly_rate_cents":500,"room_id":"room-a"}],"rate_plan":"flexible","departure_on":"2026-12-12","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"retry-guest","group_id":"retry-group","occurred_on":"2026-10-03","type":"open_group","operation_id":"retry-open"}]})

      first_result =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/partner-batches", first_payload)
        |> json_response(200)

      second_result =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/partner-batches", reordered_payload)
        |> json_response(200)

      assert second_result == first_result

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/groups/retry-group") |> json_response(200)

      assert %{"results" => [result]} = first_result

      assert %{"data" => ^result} =
               get(build_conn(), ~p"/api/v1/operations/retry-open") |> json_response(200)

      remembered = GroupStay.Operations.get_operation("retry-open")

      assert remembered.operation_type == "open_group"
      assert remembered.submitted_payload == Jason.decode!(first_payload)["operations"] |> hd()

      submit(build_conn(), [%{"operation_id" => "retry-audit-second", "type" => "unknown"}])

      assert remembered.id < GroupStay.Operations.get_operation("retry-audit-second").id
    end

    test "remembers rejections and replays their original state-dependent result", %{conn: conn} do
      missing_payment = payment("remembered-missing", "later-group", 10)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-missing",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } =
               submit(conn, [missing_payment]) |> json_response(200)

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(build_conn(), [
                 open_group(%{"operation_id" => "open-later", "group_id" => "later-group"})
               ])
               |> json_response(200)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-missing",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } =
               submit(build_conn(), [missing_payment]) |> json_response(200)

      assert %{
               "data" => %{
                 "operation_id" => "remembered-missing",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             } =
               get(build_conn(), ~p"/api/v1/operations/remembered-missing") |> json_response(200)
    end

    test "rejects conflicting identifier reuse without replacing the remembered operation", %{
      conn: conn
    } do
      original = open_group(%{"operation_id" => "conflicting-id", "group_id" => "original-group"})

      assert %{"results" => [%{"status" => "applied", "group_id" => "original-group"}]} =
               submit(conn, [original]) |> json_response(200)

      conflict = Map.put(original, "group_id", "conflicting-group")

      assert %{
               "results" => [
                 %{
                   "operation_id" => "conflicting-id",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } =
               submit(build_conn(), [conflict]) |> json_response(200)

      assert %{"error" => %{"code" => "group_not_found"}} =
               get(build_conn(), ~p"/api/v1/groups/conflicting-group") |> json_response(404)

      assert %{
               "data" => %{
                 "operation_id" => "conflicting-id",
                 "status" => "applied",
                 "group_id" => "original-group",
                 "revision" => 1
               }
             } = get(build_conn(), ~p"/api/v1/operations/conflicting-id") |> json_response(200)
    end

    test "replays stale revisions with the originally observed revision", %{conn: conn} do
      submit(conn, [open_group(%{"operation_id" => "stale-open"})])
      submit(build_conn(), [payment("stale-first-payment", "group-1", 10)])

      stale_payment = %{
        "operation_id" => "remembered-stale",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-1",
        "amount_cents" => 10,
        "expected_revision" => 1
      }

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-1",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } =
               submit(build_conn(), [stale_payment]) |> json_response(200)

      submit(build_conn(), [payment("stale-second-payment", "group-1", 10)])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-1",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             } =
               submit(build_conn(), [stale_payment]) |> json_response(200)

      corrected_revision = Map.put(stale_payment, "expected_revision", 3)

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-stale",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } =
               submit(build_conn(), [corrected_revision]) |> json_response(200)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the documented not-found response", %{conn: conn} do
      assert %{"error" => %{"code" => "operation_not_found"}} =
               get(conn, ~p"/api/v1/operations/no-such-operation") |> json_response(404)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the documented not-found response", %{conn: conn} do
      assert %{"error" => %{"code" => "group_not_found"}} =
               get(conn, ~p"/api/v1/groups/no-such-group") |> json_response(404)
    end
  end

  defp submit(conn, operations), do: submit_body(conn, %{"operations" => operations})

  defp submit_body(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
