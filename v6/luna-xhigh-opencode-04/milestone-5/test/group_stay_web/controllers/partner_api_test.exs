defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditLot,
    Group,
    LedgerEntry,
    OperationRecord,
    Repo,
    Room
  }

  test "transfers held cash in reverse allocation order and exposes transferred payments", %{
    conn: conn
  } do
    source =
      open_group("transfer-source-open")
      |> Map.merge(%{
        "group_id" => "transfer-source",
        "guest_id" => "transfer-guest",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "source-a", "nightly_rate_cents" => 50},
          %{"room_id" => "source-b", "nightly_rate_cents" => 50}
        ]
      })

    destination =
      open_group("transfer-destination-open")
      |> Map.merge(%{
        "group_id" => "transfer-destination",
        "guest_id" => "transfer-guest",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "destination-a", "nightly_rate_cents" => 50},
          %{"room_id" => "destination-b", "nightly_rate_cents" => 50}
        ]
      })

    payment =
      payment_for("transfer-payment", "transfer-source", 15, "2026-10-03")
      |> Map.put("expected_revision", 1)

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}, %{"revision" => 2}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [source, destination, payment]
             })

    assert %{"data" => payment_statement} =
             conn |> get("/api/v1/payments/transfer-payment") |> json_response(200)

    refute Map.has_key?(payment_statement, "held_by_group")

    transfer = %{
      "operation_id" => "deposit-transfer",
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-04",
      "source_group_id" => "transfer-source",
      "destination_group_id" => "transfer-destination",
      "amount_cents" => 12,
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    }

    assert %{"results" => [transfer_result]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [transfer]})

    assert %{
             "status" => "applied",
             "source_outstanding_deposit_cents" => 17,
             "destination_outstanding_deposit_cents" => 8,
             "source_revision" => 3,
             "destination_revision" => 2
           } = transfer_result

    assert 12 ==
             Repo.one(
               from allocation in CashAllocation,
                 join: group in Group,
                 on: group.id == allocation.group_id,
                 where:
                   allocation.payment_operation_id == "transfer-payment" and
                     group.group_id == "transfer-destination",
                 select: sum(allocation.amount_cents)
             )

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "source-a", "cash_paid_cents" => 3},
                 %{"room_id" => "source-b", "cash_paid_cents" => 0}
               ]
             }
           } = conn |> get("/api/v1/groups/transfer-source") |> json_response(200)

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "destination-a", "cash_paid_cents" => 10},
                 %{"room_id" => "destination-b", "cash_paid_cents" => 2}
               ]
             }
           } = conn |> get("/api/v1/groups/transfer-destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 15,
               "held_by_group" => [
                 %{"group_id" => "transfer-destination", "amount_cents" => 12},
                 %{"group_id" => "transfer-source", "amount_cents" => 3}
               ]
             }
           } = conn |> get("/api/v1/payments/transfer-payment") |> json_response(200)

    assert %{"results" => [^transfer_result]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [transfer]})

    assert transfer_result["source_revision"] == 3
    assert transfer_result["destination_revision"] == 2

    assert 15 ==
             Repo.all(
               from allocation in CashAllocation,
                 where: allocation.payment_operation_id == "transfer-payment",
                 select: allocation.amount_cents
             )
             |> Enum.sum()
  end

  test "transfers credit and cash without changing the lot or ledger", %{conn: conn} do
    credit_source =
      open_group("transfer-credit-source-open")
      |> Map.merge(%{
        "group_id" => "transfer-credit-source",
        "guest_id" => "mixed-transfer-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 25}]
      })

    mixed_source =
      open_group("mixed-source-open")
      |> Map.merge(%{
        "group_id" => "mixed-source",
        "guest_id" => "mixed-transfer-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    destination =
      open_group("mixed-destination-open")
      |> Map.merge(%{
        "group_id" => "mixed-destination",
        "guest_id" => "mixed-transfer-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-20",
        "departure_on" => "2027-03-21",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 credit_source,
                 Map.merge(
                   payment_for(
                     "credit-source-payment",
                     "transfer-credit-source",
                     5,
                     "2027-01-01"
                   ),
                   %{
                     "expected_revision" => 1
                   }
                 )
               ]
             })

    assert %{"results" => [%{"credit_issued_cents" => 6}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "credit-source-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "transfer-credit-source",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 mixed_source,
                 destination
               ]
             })

    assert %{"results" => [%{"revision" => 2}, %{"revision" => 3}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 Map.merge(payment_for("mixed-cash", "mixed-source", 5, "2027-01-01"), %{
                   "expected_revision" => 1
                 }),
                 %{
                   "operation_id" => "mixed-credit",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "mixed-source",
                   "amount_cents" => 5,
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{"data" => %{"available_cents" => 1}} =
             conn
             |> get("/api/v1/guests/mixed-transfer-guest/credit?on=2027-01-02")
             |> json_response(200)

    transfer = %{
      "operation_id" => "mixed-transfer",
      "type" => "transfer_deposit",
      "occurred_on" => "2027-01-03",
      "source_group_id" => "mixed-source",
      "destination_group_id" => "mixed-destination",
      "amount_cents" => 8,
      "expected_revision" => 3,
      "destination_expected_revision" => 1
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "source_outstanding_deposit_cents" => 18,
                 "destination_outstanding_deposit_cents" => 12,
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [transfer]})

    assert %{
             "data" => %{
               "cash_paid_cents" => 2,
               "credit_paid_cents" => 0
             }
           } = conn |> get("/api/v1/groups/mixed-source") |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 3,
               "credit_paid_cents" => 5
             }
           } = conn |> get("/api/v1/groups/mixed-destination") |> json_response(200)

    assert %{"data" => %{"available_cents" => 1}} =
             conn
             |> get("/api/v1/guests/mixed-transfer-guest/credit?on=2027-01-03")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 6}} =
             conn |> get("/api/v1/ledger?on=2027-01-03") |> json_response(200)

    assert [%{funding_operation_id: "mixed-credit", amount_cents: 5}] =
             Repo.all(
               from allocation in CreditAllocation,
                 join: group in Group,
                 on: group.id == allocation.group_id,
                 where: group.group_id == "mixed-destination",
                 select: %{
                   funding_operation_id: allocation.funding_operation_id,
                   amount_cents: allocation.amount_cents
                 }
             )

    assert %{"results" => [%{"refunded_cents" => 3, "credit_issued_cents" => 0, "revision" => 3}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "mixed-destination-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-03",
                   "group_id" => "mixed-destination",
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{"data" => %{"available_cents" => 6}} =
             conn
             |> get("/api/v1/guests/mixed-transfer-guest/credit?on=2027-01-03")
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 2,
               "cash_refunded_cents" => 3,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }
           } = conn |> get("/api/v1/ledger?on=2027-01-03") |> json_response(200)
  end

  test "reduces and charges back held cash wherever the payment currently funds", %{conn: conn} do
    source =
      open_group("correction-source-open")
      |> Map.merge(%{
        "group_id" => "correction-source",
        "guest_id" => "correction-guest",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    destination =
      open_group("correction-destination-open")
      |> Map.merge(%{
        "group_id" => "correction-destination",
        "guest_id" => "correction-guest",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
      })

    payment =
      payment_for("correction-payment", "correction-source", 15, "2026-10-03")
      |> Map.put("expected_revision", 1)

    transfer = %{
      "operation_id" => "correction-transfer",
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-04",
      "source_group_id" => "correction-source",
      "destination_group_id" => "correction-destination",
      "amount_cents" => 10,
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    }

    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"source_revision" => 3}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [source, destination, payment, transfer]
             })

    reduction = %{
      "operation_id" => "correction-reduction",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => "correction-payment",
      "amount_cents" => 7,
      "expected_revision" => 3
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "correction-source",
                 "outstanding_deposit_cents" => 15,
                 "revision" => 4
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [reduction]})

    assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 17}} =
             conn |> get("/api/v1/groups/correction-destination") |> json_response(200)

    assert %{"data" => %{"held_cents" => 8, "reduced_cents" => 7}} =
             conn |> get("/api/v1/payments/correction-payment") |> json_response(200)

    chargeback = %{
      "operation_id" => "correction-chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => "correction-payment",
      "expected_revision" => 4
    }

    assert %{"results" => [%{"charged_back_cents" => 8, "revision" => 5}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [chargeback]})

    assert %{"data" => %{"revision" => 4, "outstanding_deposit_cents" => 20}} =
             conn |> get("/api/v1/groups/correction-destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 0,
               "reduced_cents" => 7,
               "charged_back_cents" => 8,
               "held_by_group" => []
             }
           } = conn |> get("/api/v1/payments/correction-payment") |> json_response(200)

    assert %{"data" => %{"cash_reduced_cents" => 7, "cash_charged_back_cents" => 8}} =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

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
               "cash_paid_cents" => 0,
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
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
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

  test "allocates cash by room and settles selected rooms", %{conn: conn} do
    open =
      open_group("open-rooms")
      |> Map.merge(%{
        "group_id" => "rooms",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 50},
          %{"room_id" => "room-b", "nightly_rate_cents" => 50}
        ]
      })

    payment =
      payment_for("rooms-payment", "rooms", 15, "2027-01-01")
      |> Map.put("expected_revision", 1)

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open, payment]})

    cancel = %{
      "operation_id" => "rooms-cancel",
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-01",
      "group_id" => "rooms",
      "room_ids" => ["room-b"],
      "expected_revision" => 2
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-b"],
                 "refunded_cents" => 5,
                 "revision" => 3
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [cancel]})

    assert %{
             "data" => %{
               "deposit_due_cents" => 10,
               "deposit_paid_cents" => 10,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "active",
                   "deposit_due_cents" => 10,
                   "cash_paid_cents" => 10
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "cancelled",
                   "deposit_due_cents" => 10,
                   "cash_paid_cents" => 0
                 }
               ]
             }
           } = conn |> get("/api/v1/groups/rooms") |> json_response(200)
  end

  test "reduces held cash and chargebacks its remaining payment history", %{conn: conn} do
    open =
      open_group("open-payment")
      |> Map.merge(%{
        "group_id" => "payment-group",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
      })

    payment =
      payment_for("payment-to-reconcile", "payment-group", 150, "2026-10-03")
      |> Map.put("expected_revision", 1)

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open, payment]})

    reduce = %{
      "operation_id" => "payment-reduction",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-04",
      "payment_operation_id" => "payment-to-reconcile",
      "amount_cents" => 50,
      "expected_revision" => 2
    }

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [reduce]})

    assert %{
             "data" => %{
               "payment_operation_id" => "payment-to-reconcile",
               "original_group_id" => "payment-group",
               "recorded_cents" => 150,
               "held_cents" => 100,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 50,
               "charged_back_cents" => 0
             }
           } =
             conn
             |> get("/api/v1/payments/payment-to-reconcile")
             |> json_response(200)

    chargeback = %{
      "operation_id" => "payment-chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => "payment-to-reconcile",
      "expected_revision" => 3
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 100,
                 "outstanding_deposit_cents" => 300,
                 "revision" => 4
               }
             ]
           } = post_json(conn, "/api/v1/partner-batches", %{"operations" => [chargeback]})

    assert %{"data" => %{"reduced_cents" => 50, "charged_back_cents" => 100}} =
             conn |> get("/api/v1/payments/payment-to-reconcile") |> json_response(200)
  end

  test "reports and absorbs credit shortfall after a payment chargeback", %{conn: conn} do
    source =
      open_group("shortfall-source")
      |> Map.merge(%{
        "group_id" => "shortfall-source",
        "guest_id" => "shortfall-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
      })

    target =
      open_group("shortfall-target")
      |> Map.merge(%{
        "group_id" => "shortfall-target",
        "guest_id" => "shortfall-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 550}]
      })

    payment =
      payment_for("shortfall-payment", "shortfall-source", 100, "2027-01-01")
      |> Map.put("expected_revision", 1)

    cancel_source = %{
      "operation_id" => "shortfall-credit",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-01",
      "group_id" => "shortfall-source",
      "refund_method" => "hotel_credit",
      "expected_revision" => 2
    }

    apply_credit = %{
      "operation_id" => "shortfall-application",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-01",
      "group_id" => "shortfall-target",
      "amount_cents" => 110,
      "expected_revision" => 1
    }

    assert %{"results" => results} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [source, payment, cancel_source, target, apply_credit]
             })

    assert %{"status" => "applied", "credit_issued_cents" => 110} = Enum.at(results, 2)
    assert %{"status" => "applied", "amount_cents" => 110} = Enum.at(results, 4)

    chargeback = %{
      "operation_id" => "shortfall-chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-02",
      "payment_operation_id" => "shortfall-payment",
      "expected_revision" => 3
    }

    assert %{"results" => [%{"status" => "applied", "revision" => 4}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [chargeback]})

    assert %{"data" => %{"credit_shortfall_cents" => 110, "credit_liability_cents" => 110}} =
             conn |> get("/api/v1/ledger") |> json_response(200)

    cancel_target = %{
      "operation_id" => "shortfall-target-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "shortfall-target",
      "expected_revision" => 2
    }

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [cancel_target]})

    assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}} =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "brings legacy and durable funding into ordered room allocations", %{conn: conn} do
    group =
      Repo.insert!(%Group{
        group_id: "legacy-group",
        guest_id: "legacy-guest",
        property_id: "legacy-property",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-11],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "active",
        revision: 1,
        lodging_total_cents: 1_000,
        deposit_due_cents: 200,
        deposit_paid_cents: 150,
        cash_paid_cents: 100,
        credit_paid_cents: 50
      })

    room_a =
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: "room-a",
        nightly_rate_cents: 500,
        position: 0,
        status: "active",
        deposit_due_cents: 100,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })

    room_b =
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: "room-b",
        nightly_rate_cents: 500,
        position: 1,
        status: "active",
        deposit_due_cents: 100,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })

    lot =
      Repo.insert!(%CreditLot{
        guest_id: "legacy-guest",
        source_operation_id: "legacy-lot",
        remaining_cents: 0,
        expires_on: ~D[2028-01-01],
        unrecovered_clawback_cents: 0
      })

    Repo.insert!(%CreditAllocation{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: 50
    })

    Repo.insert!(%LedgerEntry{group_id: group.id, kind: "held", amount_cents: 100})

    payment = payment_for("legacy-payment", "legacy-group", 25, "2026-10-03")

    Repo.insert!(%OperationRecord{
      operation_id: "legacy-payment",
      type: "record_cash_payment",
      payload: payment,
      result: %{
        "operation_id" => "legacy-payment",
        "status" => "applied",
        "group_id" => "legacy-group",
        "amount_cents" => 25,
        "outstanding_deposit_cents" => 25,
        "revision" => 2
      }
    })

    assert %{
             "data" => %{
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 75, "credit_paid_cents" => 25},
                 %{"room_id" => "room-b", "cash_paid_cents" => 25, "credit_paid_cents" => 25}
               ]
             }
           } = conn |> get("/api/v1/groups/legacy-group") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 100}} =
             conn |> get("/api/v1/ledger") |> json_response(200)

    assert Repo.get!(Room, room_a.id).cash_paid_cents == 75
    assert Repo.get!(Room, room_b.id).cash_paid_cents == 25

    assert %{"results" => [%{"status" => "applied"}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "legacy-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-01",
                   "group_id" => "legacy-group"
                 }
               ]
             })

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 100,
               "cash_reduced_cents" => 0
             }
           } = conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "chargebacks a payment after a cash refund", %{conn: conn} do
    open =
      open_group("refunded-payment")
      |> Map.put("group_id", "refunded-group")

    payment =
      payment_for("refunded-payment-record", "refunded-group", 100, "2026-10-03")
      |> Map.put("expected_revision", 1)

    cancel = %{
      "operation_id" => "refunded-group-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-01",
      "group_id" => "refunded-group",
      "expected_revision" => 2
    }

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open, payment, cancel]})

    chargeback = %{
      "operation_id" => "refunded-payment-chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-11-02",
      "payment_operation_id" => "refunded-payment-record",
      "expected_revision" => 3
    }

    assert %{"results" => [%{"charged_back_cents" => 100, "revision" => 4}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [chargeback]})

    assert %{
             "data" => %{
               "held_cents" => 0,
               "refunded_cents" => 0,
               "charged_back_cents" => 100
             }
           } = conn |> get("/api/v1/payments/refunded-payment-record") |> json_response(200)

    assert %{"data" => %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 100}} =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "uses stable reduction and chargeback rejection codes", %{conn: conn} do
    open = open_group("rejection-group") |> Map.put("group_id", "rejection-group")

    payment =
      payment_for("rejection-payment", "rejection-group", 100, "2026-10-03")
      |> Map.put("expected_revision", 1)

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_json(conn, "/api/v1/partner-batches", %{"operations" => [open, payment]})

    invalid_reduction = %{
      "operation_id" => "invalid-reduction",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-04",
      "payment_operation_id" => "rejection-payment",
      "amount_cents" => 0,
      "expected_revision" => 2
    }

    excessive_reduction =
      %{invalid_reduction | "operation_id" => "excessive-reduction", "amount_cents" => 101}

    assert %{
             "results" => [
               %{"code" => "invalid_amount"},
               %{"code" => "reduction_exceeds_held_cash"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [invalid_reduction, excessive_reduction]
             })

    assert %{
             "results" => [
               %{"code" => "payment_not_chargeable"},
               %{"code" => "operation_not_found"}
             ]
           } =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "open-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-10-04",
                   "payment_operation_id" => "rejection-group",
                   "expected_revision" => 2
                 },
                 %{
                   "operation_id" => "missing-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-10-04",
                   "payment_operation_id" => "missing-payment"
                 }
               ]
             })

    assert %{"results" => [%{"code" => "invalid_amount"}]} =
             post_json(conn, "/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "rejected-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "rejection-group",
                   "amount_cents" => 0,
                   "expected_revision" => 2
                 }
               ]
             })

    assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
             conn |> get("/api/v1/payments/rejected-payment") |> json_response(422)

    assert %{"data" => %{"revision" => 2}} =
             conn |> get("/api/v1/groups/rejection-group") |> json_response(200)
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
