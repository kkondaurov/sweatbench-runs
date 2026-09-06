defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.{OperationRecord, Repo}

  test "opens a group and returns its calculated totals", %{conn: conn} do
    operation = open_group("open-1")

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

    assert %{
             "data" => %{
               "group_id" => "group-81",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 1,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "processes payment, rescheduling, cancellation, and ledger settlement in order", %{
    conn: conn
  } do
    operations = [
      open_group("open-1"),
      Map.merge(payment("payment-1", 5_000), %{"expected_revision" => 1}),
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-12",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "expected_revision" => 3
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               },
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-12",
                 "new_departure_on" => "2026-12-15",
                 "revision" => 3
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 4,
               "cash_paid_cents" => 5_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "rejects stale revisions before domain validation and continues the batch", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open_group("open-1")]})

    operations = [
      Map.merge(payment("payment-1", 99_999), %{"expected_revision" => 0}),
      Map.merge(payment("payment-2", 5_000), %{"expected_revision" => 1})
    ]

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-1",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{"operation_id" => "payment-2", "status" => "applied", "revision" => 2}
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "returns stable errors for invalid batches and missing groups", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", Jason.encode!(%{}))
             |> json_response(422)

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/missing") |> json_response(404)
  end

  test "uses operation-specific validation codes without changing the group", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open_group("open-1")]})

    operations = [
      Map.drop(payment("missing-amount", 1), ["amount_cents"]),
      payment("invalid-amount", 0),
      payment("too-much", 99_999),
      %{
        "operation_id" => "invalid-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-10-03"
      },
      %{"operation_id" => "unknown", "type" => "unknown"}
    ]

    assert %{
             "results" => [
               %{"code" => "invalid_operation"},
               %{"code" => "invalid_amount"},
               %{"code" => "payment_exceeds_outstanding"},
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_operation"}
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0, "status" => "active"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "retains an advance-purchase payment on late cancellation", %{conn: conn} do
    operation =
      open_group("open-1")
      |> Map.put("rate_plan", "advance_purchase")
      |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])
      |> Map.put("departure_on", "2026-12-11")

    operations = [
      operation,
      Map.merge(payment("payment-1", 10_000), %{"expected_revision" => 1}),
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "expected_revision" => 2
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "deposit_due_cents" => 10_000},
               %{"status" => "applied", "outstanding_deposit_cents" => 0},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 10_000}
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 10_000
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "rounds each flexible room deposit before summing", %{conn: conn} do
    operation =
      open_group("open-1")
      |> Map.put("arrival_on", "2026-12-10")
      |> Map.put("departure_on", "2026-12-11")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 2},
        %{"room_id" => "room-b", "nightly_rate_cents" => 2}
      ])

    assert %{
             "results" => [%{"status" => "applied", "deposit_due_cents" => 0, "revision" => 1}]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [operation]})
  end

  test "does not apply a duplicate open or invalid room data", %{conn: conn} do
    duplicate = open_group("duplicate")

    invalid_rooms =
      open_group("bad-rooms")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 10},
        %{"room_id" => "room-a", "nightly_rate_cents" => 10}
      ])

    invalid_stay = Map.put(open_group("bad-stay"), "departure_on", "2026-12-10")
    invalid_rate_plan = Map.put(open_group("bad-rate"), "rate_plan", "nonrefundable")

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_already_exists"},
               %{"status" => "rejected", "code" => "invalid_rooms"},
               %{"status" => "rejected", "code" => "invalid_stay"},
               %{"status" => "rejected", "code" => "invalid_rate_plan"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 open_group("open-1"),
                 duplicate,
                 invalid_rooms,
                 invalid_stay,
                 invalid_rate_plan
               ]
             })

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/bad-rooms") |> json_response(404)
  end

  test "fixes the cancellation policy at booking and reports it after rescheduling", %{
    conn: conn
  } do
    old_policy =
      open_group("open-old")
      |> Map.merge(%{
        "group_id" => "group-old",
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-02-10",
        "departure_on" => "2027-02-11"
      })

    new_policy =
      open_group("open-new")
      |> Map.merge(%{
        "group_id" => "group-new",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-10",
        "departure_on" => "2027-02-11"
      })

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [old_policy, new_policy]
             })

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-27"
             }
           } = conn |> get("/api/v1/groups/group-old") |> json_response(200)

    move = %{
      "operation_id" => "move-new",
      "type" => "reschedule_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "group-new",
      "new_arrival_on" => "2027-02-12",
      "expected_revision" => 1
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-01-13",
                 "revision" => 2
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [move]})
  end

  test "issues, applies, restores, and expires hotel credit", %{conn: conn} do
    source =
      open_group("open-source")
      |> Map.merge(%{
        "group_id" => "source",
        "guest_id" => "guest-credit",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
      })

    target =
      open_group("open-target")
      |> Map.merge(%{
        "group_id" => "target",
        "guest_id" => "guest-credit",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-10",
        "departure_on" => "2027-02-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    operations = [
      source,
      Map.merge(payment_for("source-payment", "source", 5, "2027-01-01"), %{
        "expected_revision" => 1
      }),
      %{
        "operation_id" => "source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      target,
      %{
        "operation_id" => "credit-payment",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => "target",
        "amount_cents" => 6,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "target-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "target",
        "expected_revision" => 2
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied", "amount_cents" => 5},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 6
               },
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "amount_cents" => 6,
                 "outstanding_deposit_cents" => 14,
                 "revision" => 2
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{
             "data" => %{
               "deposit_paid_cents" => 6,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 6,
               "status" => "cancelled"
             }
           } = conn |> get("/api/v1/groups/target") |> json_response(200)

    assert %{
             "data" => %{
               "guest_id" => "guest-credit",
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "source-cancel",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-01-03"
                 }
               ]
             }
           } =
             conn
             |> get("/api/v1/guests/guest-credit/credit?on=2028-01-02")
             |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             conn
             |> get("/api/v1/guests/guest-credit/credit?on=2028-01-03")
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }
           } = conn |> get("/api/v1/ledger?on=2028-01-02") |> json_response(200)
  end

  test "consumes credit on non-refundable cancellation and rejects credit refunds", %{conn: conn} do
    source =
      open_group("open-source")
      |> Map.merge(%{
        "group_id" => "source",
        "guest_id" => "guest-nonref",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
      })

    target =
      open_group("open-target")
      |> Map.merge(%{
        "group_id" => "target",
        "guest_id" => "guest-nonref",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [source, target]})

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied", "credit_issued_cents" => 6},
               %{"status" => "applied"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 Map.merge(payment_for("source-payment", "source", 5, "2027-01-01"), %{
                   "expected_revision" => 1
                 }),
                 %{
                   "operation_id" => "source-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "source",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 },
                 %{
                   "operation_id" => "target-payment",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "amount_cents" => 6,
                   "expected_revision" => 1
                 }
               ]
             })

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "refund_method_not_available",
                 "group_id" => "target"
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "target-credit-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-10",
                   "group_id" => "target",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 },
                 %{
                   "operation_id" => "target-cash-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-10",
                   "group_id" => "target",
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             conn
             |> get("/api/v1/guests/guest-nonref/credit?on=2027-01-10")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             conn |> get("/api/v1/ledger?on=2027-01-10") |> json_response(200)
  end

  test "does not advance credit revisions for stale or insufficient applications", %{conn: conn} do
    source =
      open_group("open-source")
      |> Map.merge(%{
        "group_id" => "source",
        "guest_id" => "guest-expiry",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
      })

    target =
      open_group("open-target")
      |> Map.merge(%{
        "group_id" => "target",
        "guest_id" => "guest-expiry",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2028-02-10",
        "departure_on" => "2028-02-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [source, target]})

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied", "credit_issued_cents" => 6},
               %{"status" => "applied"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 Map.merge(payment_for("source-payment", "source", 5, "2027-01-01"), %{
                   "expected_revision" => 1
                 }),
                 %{
                   "operation_id" => "source-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "source",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 },
                 %{
                   "operation_id" => "target-credit",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "amount_cents" => 2,
                   "expected_revision" => 1
                 }
               ]
             })

    assert %{
             "results" => [
               %{"code" => "stale_revision", "actual_revision" => 2},
               %{"code" => "insufficient_credit", "group_id" => "target"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "stale-credit",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "amount_cents" => 2,
                   "expected_revision" => 1
                 },
                 %{
                   "operation_id" => "too-much-credit",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "amount_cents" => 7,
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "revision" => 3,
                 "outstanding_deposit_cents" => 16
               },
               %{"status" => "applied", "revision" => 4}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "target-credit-retry",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "amount_cents" => 2,
                   "expected_revision" => 2
                 },
                 %{
                   "operation_id" => "target-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2028-01-03",
                   "group_id" => "target",
                   "expected_revision" => 3
                 }
               ]
             })

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             conn
             |> get("/api/v1/guests/guest-expiry/credit?on=2028-01-03")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             conn |> get("/api/v1/ledger?on=2028-01-03") |> json_response(200)
  end

  test "consumes equal-expiry credit lots by source operation and restores them", %{conn: conn} do
    source_a = credit_source("source-a", "open-a", "guest-order")
    source_b = credit_source("source-b", "open-b", "guest-order")

    target =
      open_group("open-target")
      |> Map.merge(%{
        "group_id" => "target",
        "guest_id" => "guest-order",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-10",
        "departure_on" => "2027-02-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    operations = [
      source_a,
      Map.merge(payment_for("payment-a", "source-a", 5, "2027-01-01"), %{
        "expected_revision" => 1
      }),
      credit_cancellation("z-lot", "source-a", 2),
      source_b,
      Map.merge(payment_for("payment-b", "source-b", 5, "2027-01-01"), %{
        "expected_revision" => 1
      }),
      credit_cancellation("a-lot", "source-b", 2),
      target,
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-02",
        "group_id" => "target",
        "amount_cents" => 7,
        "expected_revision" => 1
      }
    ]

    assert %{"results" => results} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert %{"status" => "applied", "credit_issued_cents" => 6} = Enum.at(results, 2)
    assert %{"status" => "applied", "credit_issued_cents" => 6} = Enum.at(results, 5)
    assert %{"status" => "applied", "amount_cents" => 7, "revision" => 2} = Enum.at(results, 7)

    assert %{
             "data" => %{
               "available_cents" => 5,
               "lots" => [
                 %{
                   "source_operation_id" => "z-lot",
                   "remaining_cents" => 5,
                   "expires_on" => "2028-01-03"
                 }
               ]
             }
           } = conn |> get("/api/v1/guests/guest-order/credit") |> json_response(200)

    assert %{
             "results" => [%{"status" => "applied", "revision" => 3}]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "cancel-target",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{
             "data" => %{
               "available_cents" => 12,
               "lots" => [
                 %{"source_operation_id" => "a-lot", "remaining_cents" => 6},
                 %{"source_operation_id" => "z-lot", "remaining_cents" => 6}
               ]
             }
           } = conn |> get("/api/v1/guests/guest-order/credit") |> json_response(200)
  end

  test "returns the original result for an applied retry without applying it again", %{conn: conn} do
    open = open_group("open-1")
    assert first = post_json(conn, "/api/v1/partner-batches", %{"operations" => [open]})
    assert ^first = post_json(conn, "/api/v1/partner-batches", %{"operations" => [open]})

    payment = Map.merge(payment("payment-1", 5_000), %{"expected_revision" => 1})

    assert payment_result =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [payment]})

    assert ^payment_result =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [payment]})

    assert %{
             "data" => %{
               "revision" => 2,
               "deposit_paid_cents" => 5_000,
               "cash_paid_cents" => 5_000
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "remembers rejections, preserves their original details, and rejects conflicts", %{
    conn: conn
  } do
    open = open_group("open-1")

    assert %{"results" => [%{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open]})

    stale = Map.merge(payment("payment-1", 5_000), %{"expected_revision" => 0})

    assert %{"results" => [stale_result]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [stale]})

    assert stale_result == %{
             "operation_id" => "payment-1",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    payment = Map.merge(payment("payment-2", 5_000), %{"expected_revision" => 1})

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [payment]})

    assert %{"results" => [^stale_result]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [stale]})

    conflict = Map.put(stale, "expected_revision", 1)

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-1",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [conflict]})

    assert %{"data" => ^stale_result} =
             conn |> get("/api/v1/operations/payment-1") |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             conn |> get("/api/v1/operations/missing") |> json_response(404)

    assert [
             %OperationRecord{operation_id: "open-1", type: "open_group", payload: ^open},
             %OperationRecord{
               operation_id: "payment-1",
               type: "record_cash_payment",
               payload: ^stale
             },
             %OperationRecord{
               operation_id: "payment-2",
               type: "record_cash_payment",
               payload: ^payment
             }
           ] =
             Repo.all(from record in OperationRecord, order_by: [asc: record.id])
  end

  defp open_group(operation_id) do
    %{
      "operation_id" => operation_id,
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
    }
  end

  defp payment(operation_id, amount_cents) do
    payment_for(operation_id, "group-81", amount_cents, "2026-10-03")
  end

  defp payment_for(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp credit_source(group_id, operation_id, guest_id) do
    open_group(operation_id)
    |> Map.merge(%{
      "group_id" => group_id,
      "guest_id" => guest_id,
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-02-01",
      "departure_on" => "2027-02-02",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
    })
  end

  defp credit_cancellation(operation_id, group_id, day) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => "2027-01-0#{day}",
      "group_id" => group_id,
      "refund_method" => "hotel_credit",
      "expected_revision" => 2
    }
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
    |> json_response(200)
  end
end
