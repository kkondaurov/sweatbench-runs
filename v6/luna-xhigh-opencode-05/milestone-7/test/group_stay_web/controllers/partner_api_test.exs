defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  test "opens, funds, reschedules, cancels, and exposes ledger totals", %{conn: conn} do
    open = open_operation("open-1", "group-1")

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = submit(conn, [open])

    assert %{
             "data" => %{
               "group_id" => "group-1",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 1,
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = get_group(conn, "group-1")

    assert %{
             "results" => [
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-1",
                 "amount_cents" => 5_000,
                 "expected_revision" => 1
               }
             ])

    assert %{
             "results" => [
               %{
                 "operation_id" => "move-1",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "move-1",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group-1",
                 "new_arrival_on" => "2026-12-20",
                 "expected_revision" => 2
               }
             ])

    assert %{
             "results" => [
               %{
                 "operation_id" => "cancel-1",
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-1",
                 "expected_revision" => 3
               }
             ])

    assert %{
             "data" => %{
               "status" => "cancelled",
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }
           } = get_group(conn, "group-1")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           } =
             get_ledger(conn)
  end

  test "processes operations in order and continues after rejections", %{conn: conn} do
    results =
      submit(conn, [
        open_operation("open-2", "group-2"),
        %{
          "operation_id" => "bad-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-2",
          "amount_cents" => 100_000
        },
        %{
          "operation_id" => "pay-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-2",
          "amount_cents" => 1_000
        }
      ])

    assert [
             %{"status" => "applied", "revision" => 1},
             %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
             %{"status" => "applied", "revision" => 2}
           ] =
             results["results"]
  end

  test "rejects stale revisions before domain validation", %{conn: conn} do
    submit(conn, [open_operation("open-3", "group-3")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale-3",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-3",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "stale-3",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-3",
                 "amount_cents" => 0,
                 "expected_revision" => 0
               }
             ])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "expected_revision" => nil,
                 "actual_revision" => 1
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "null-revision",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-3",
                 "expected_revision" => nil
               }
             ])
  end

  test "rejects invalid batches and missing groups", %{conn: conn} do
    assert response = post(conn, "/api/v1/partner-batches", json: %{})
    assert response.status == 422
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}

    assert %{
             "results" => [
               %{"operation_id" => "missing", "status" => "rejected", "code" => "group_not_found"}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "missing",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "does-not-exist"
               }
             ])

    assert response = get(conn, "/api/v1/groups/does-not-exist")
    assert response.status == 404
    assert json_response(response, 404) == %{"error" => %{"code" => "group_not_found"}}

    assert response = get(conn, "/api/v1/operations/does-not-exist")
    assert response.status == 404
    assert json_response(response, 404) == %{"error" => %{"code" => "operation_not_found"}}

    assert response = get(conn, "/api/v1/ledger?on=not-a-date")
    assert response.status == 422
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_date"}}

    assert response = get(conn, "/api/v1/guests/guest-22/credit?on=not-a-date")
    assert response.status == 422
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_date"}}
  end

  test "uses full deposits for advance purchase and rounds each flexible room separately", %{
    conn: conn
  } do
    advance = open_operation("open-5", "group-5")

    assert %{"results" => [%{"deposit_due_cents" => 97_500, "revision" => 1}]} =
             submit(conn, [%{advance | "rate_plan" => "advance_purchase"}])

    flexible = %{
      open_operation("open-6", "group-6")
      | "rooms" => [
          %{"room_id" => "one", "nightly_rate_cents" => 1},
          %{"room_id" => "two", "nightly_rate_cents" => 1},
          %{"room_id" => "three", "nightly_rate_cents" => 1}
        ],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11"
    }

    assert %{"results" => [%{"deposit_due_cents" => 0}]} = submit(conn, [flexible])
  end

  test "returns the documented validation codes", %{conn: conn} do
    invalid_stay = %{
      open_operation("invalid-stay", "invalid-stay-group")
      | "arrival_on" => "2026-12-13",
        "departure_on" => "2026-12-13"
    }

    invalid_rooms = %{
      open_operation("invalid-rooms", "invalid-rooms-group")
      | "rooms" => [
          %{"room_id" => "duplicate", "nightly_rate_cents" => 100},
          %{"room_id" => "duplicate", "nightly_rate_cents" => 200}
        ]
    }

    invalid_rate_plan = %{
      open_operation("invalid-rate", "invalid-rate-group")
      | "rate_plan" => "non_refundable"
    }

    assert [
             %{"code" => "invalid_stay"},
             %{"code" => "invalid_rooms"},
             %{"code" => "invalid_rate_plan"}
           ] =
             submit(conn, [invalid_stay, invalid_rooms, invalid_rate_plan])["results"]

    submit(conn, [open_operation("valid-validation", "validation-group")])

    assert %{"results" => [%{"code" => "group_already_exists"}]} =
             submit(conn, [open_operation("duplicate", "validation-group")])

    assert [%{"code" => "invalid_amount"}, %{"code" => "invalid_operation"}] =
             submit(conn, [
               %{
                 "operation_id" => "invalid-amount",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "validation-group",
                 "amount_cents" => 0
               },
               %{
                 "operation_id" => "invalid-op",
                 "type" => "unknown",
                 "occurred_on" => "2026-10-04"
               }
             ])["results"]
  end

  test "rejects inactive groups and invalid reschedules", %{conn: conn} do
    submit(conn, [open_operation("open-7", "group-7")])

    submit(conn, [
      %{
        "operation_id" => "cancel-7",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-7"
      }
    ])

    assert [
             %{"code" => "group_not_active"},
             %{"code" => "group_not_active"},
             %{"code" => "group_not_active"}
           ] =
             submit(conn, [
               %{
                 "operation_id" => "pay-after",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-12-02",
                 "group_id" => "group-7",
                 "amount_cents" => 1
               },
               %{
                 "operation_id" => "move-after",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-12-02",
                 "group_id" => "group-7",
                 "new_arrival_on" => "2026-12-20"
               },
               %{
                 "operation_id" => "cancel-after",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-02",
                 "group_id" => "group-7"
               }
             ])["results"]

    submit(conn, [open_operation("open-8", "group-8")])

    assert %{"results" => [%{"code" => "invalid_stay"}]} =
             submit(conn, [
               %{
                 "operation_id" => "move-8",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "group-8",
                 "new_arrival_on" => "2026-10-03"
               }
             ])
  end

  test "makes earlier operations visible to later expected revisions", %{conn: conn} do
    results =
      submit(conn, [
        open_operation("open-9", "group-9"),
        %{
          "operation_id" => "pay-9",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-9",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "stale-9",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-9",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }
      ])

    assert [
             %{"status" => "applied", "revision" => 1},
             %{"status" => "applied", "revision" => 2},
             %{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2}
           ] = results["results"]
  end

  test "cancellation retains non-refundable cash", %{conn: conn} do
    submit(conn, [open_operation("open-4", "group-4")])

    submit(conn, [
      %{
        "operation_id" => "pay-4",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-4",
        "amount_cents" => 1_000
      }
    ])

    assert %{"results" => [%{"refunded_cents" => 0, "retained_cents" => 1_000, "revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "cancel-4",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "group-4"
               }
             ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 1_000
             }
           } =
             get_ledger(conn)
  end

  test "fixes policy versions at booking and recomputes the refundable date on reschedule", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation("policy-old", "policy-old")])

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26"
             }
           } = get_group(conn, "policy-old")

    new_group = %{
      open_operation("policy-new", "policy-new")
      | "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-02-15",
        "departure_on" => "2027-02-16"
    }

    submit(conn, [new_group])

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-01-16"
             }
           } = get_group(conn, "policy-new")

    assert %{
             "results" => [
               %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-01-21",
                 "revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "move-policy-new",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "policy-new",
                 "new_arrival_on" => "2027-02-20",
                 "expected_revision" => 1
               }
             ])
  end

  test "issues, applies, restores, and expires hotel credit", %{conn: conn} do
    submit(conn, [open_operation("credit-source", "credit-source")])

    submit(conn, [
      %{
        "operation_id" => "credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-source",
        "amount_cents" => 1_000
      }
    ])

    assert %{
             "results" => [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 1_100,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "available_cents" => 1_100,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-cancel",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }
           } = get_credit(conn, "guest-22", "2026-11-01")

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get_credit(conn, "guest-22", "2026-10-31")

    target = %{open_operation("credit-target", "credit-target") | "guest_id" => "guest-22"}
    submit(conn, [target])

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "insufficient_credit"
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "too-much-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-target",
                 "amount_cents" => 2_000,
                 "expected_revision" => 1
               }
             ])

    assert %{
             "results" => [
               %{
                 "amount_cents" => 500,
                 "outstanding_deposit_cents" => 19_000,
                 "revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "target-cash",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-target",
                 "amount_cents" => 500,
                 "expected_revision" => 1
               }
             ])

    assert %{
             "results" => [
               %{
                 "amount_cents" => 600,
                 "outstanding_deposit_cents" => 18_400,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-target",
                 "amount_cents" => 600,
                 "expected_revision" => 2
               }
             ])

    assert %{
             "results" => [
               %{
                 "amount_cents" => 400,
                 "outstanding_deposit_cents" => 18_000,
                 "revision" => 4
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "apply-credit-again",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-target",
                 "amount_cents" => 400,
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"available_cents" => 100}} =
             get_credit(conn, "guest-22", "2026-11-01")

    assert %{"data" => %{"credit_liability_cents" => 1_100}} =
             get_ledger(conn, "2026-11-01")

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get_ledger(conn, "2026-10-31")

    assert %{
             "results" => [
               %{
                 "refunded_cents" => 500,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 5
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "restore-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "credit-target",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => %{"available_cents" => 1_100}} =
             get_credit(conn, "guest-22", "2026-11-02")

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get_credit(conn, "guest-22", "2027-11-02")

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get_ledger(conn, "2027-11-02")
  end

  test "rejects hotel credit for a non-refundable cancellation without advancing revision", %{
    conn: conn
  } do
    advance = %{
      open_operation("nonrefundable", "nonrefundable")
      | "rate_plan" => "advance_purchase"
    }

    submit(conn, [advance])

    submit(conn, [
      %{
        "operation_id" => "nonrefundable-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "nonrefundable",
        "amount_cents" => 1_000
      }
    ])

    assert %{"results" => [%{"code" => "refund_method_not_available"}]} =
             submit(conn, [
               %{
                 "operation_id" => "unavailable-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "nonrefundable",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               }
             ])

    assert %{"results" => [%{"retained_cents" => 1_000, "revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "nonrefundable-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "nonrefundable",
                 "expected_revision" => 2
               }
             ])
  end

  test "consumes applied credit when an advance-purchase group is cancelled", %{conn: conn} do
    submit(conn, [open_operation("consumption-source", "consumption-source")])

    submit(conn, [
      %{
        "operation_id" => "consumption-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "consumption-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "consumption-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "consumption-source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }
    ])

    target = %{
      open_operation("consumption-target", "consumption-target")
      | "guest_id" => "guest-22",
        "rate_plan" => "advance_purchase"
    }

    submit(conn, [target])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "consumption-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "consumption-target",
                 "amount_cents" => 1_000,
                 "expected_revision" => 1
               }
             ])

    assert %{"results" => [%{"retained_cents" => 0, "credit_issued_cents" => 0, "revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "consumption-cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "consumption-target",
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"available_cents" => 100}} =
             get_credit(conn, "guest-22", "2026-12-01")

    assert %{"data" => %{"credit_liability_cents" => 100}} =
             get_ledger(conn, "2026-12-01")
  end

  test "consumes credit lots by expiry and source operation id", %{conn: conn} do
    for {group_id, payment_id, cancel_id, amount} <- [
          {"fifo-first", "fifo-payment-z", "z-cancel", 100},
          {"fifo-second", "fifo-payment-a", "a-cancel", 200}
        ] do
      submit(conn, [open_operation(group_id, group_id)])

      submit(conn, [
        %{
          "operation_id" => payment_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount
        },
        %{
          "operation_id" => cancel_id,
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => group_id,
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])
    end

    assert %{
             "data" => %{
               "lots" => [
                 %{
                   "source_operation_id" => "a-cancel",
                   "remaining_cents" => 220
                 },
                 %{
                   "source_operation_id" => "z-cancel",
                   "remaining_cents" => 110
                 }
               ]
             }
           } = get_credit(conn, "guest-22", "2026-11-01")

    submit(conn, [open_operation("fifo-target", "fifo-target")])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "fifo-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "fifo-target",
                 "amount_cents" => 250,
                 "expected_revision" => 1
               }
             ])

    assert %{
             "data" => %{
               "available_cents" => 80,
               "lots" => [
                 %{
                   "source_operation_id" => "z-cancel",
                   "remaining_cents" => 80
                 }
               ]
             }
           } = get_credit(conn, "guest-22", "2026-11-01")
  end

  test "returns the original result for equivalent retries and rejects conflicting payloads", %{
    conn: conn
  } do
    operation = open_operation("durable-open", "durable-group")

    assert %{"results" => [original]} = submit(conn, [operation])
    assert %{"data" => ^original} = get_operation(conn, "durable-open")

    assert %{"results" => [^original]} = submit(conn, [operation])

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get_group(conn, "durable-group")

    conflicting_operation = %{operation | "guest_id" => "another-guest"}

    assert %{
             "results" => [
               %{
                 "operation_id" => "durable-open",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = submit(conn, [conflicting_operation])

    assert %{"data" => ^original} = get_operation(conn, "durable-open")
  end

  test "canonicalizes object keys, preserves array significance, and remembers rejections", %{
    conn: conn
  } do
    first_payload =
      ~s({"operation_id":"durable-invalid","type":"unknown","occurred_on":"2026-10-04","metadata":{"b":2,"a":1},"items":[1,2]})

    reordered_payload =
      ~s({"items":[1,2],"metadata":{"a":1,"b":2},"occurred_on":"2026-10-04","type":"unknown","operation_id":"durable-invalid"})

    assert %{"results" => [original]} = submit_json(conn, first_payload)
    assert %{"results" => [^original]} = submit_json(conn, reordered_payload)

    changed_array_payload =
      ~s({"operation_id":"durable-invalid","type":"unknown","occurred_on":"2026-10-04","metadata":{"a":1,"b":2},"items":[2,1]})

    assert %{
             "results" => [
               %{
                 "operation_id" => "durable-invalid",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = submit_json(conn, changed_array_payload)

    assert %{"data" => ^original} = get_operation(conn, "durable-invalid")
  end

  test "replays a rejection without consulting later domain state", %{conn: conn} do
    submit(conn, [open_operation("durable-rejection-open", "durable-rejection-group")])

    stale_operation = %{
      "operation_id" => "durable-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "durable-rejection-group",
      "amount_cents" => 0,
      "expected_revision" => 0
    }

    assert %{"results" => [original]} = submit(conn, [stale_operation])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "durable-rejection-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "durable-rejection-group",
                 "amount_cents" => 1_000
               }
             ])

    assert %{"results" => [^original]} = submit(conn, [stale_operation])
    assert %{"data" => ^original} = get_operation(conn, "durable-stale")

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             get_group(conn, "durable-rejection-group")
  end

  test "allocates funding by room and settles only selected rooms", %{conn: conn} do
    operation = %{
      open_operation("rooms-open", "rooms-group")
      | "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "first", "nightly_rate_cents" => 10_000},
          %{"room_id" => "second", "nightly_rate_cents" => 20_000}
        ]
    }

    assert %{"results" => [%{"revision" => 1}]} = submit(conn, [operation])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "rooms-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "rooms-group",
                 "amount_cents" => 5_000
               }
             ])

    assert %{
             "data" => %{
               "deposit_due_cents" => 6_000,
               "deposit_paid_cents" => 5_000,
               "rooms" => [
                 %{
                   "room_id" => "first",
                   "status" => "active",
                   "lodging_cents" => 10_000,
                   "deposit_due_cents" => 2_000,
                   "cash_paid_cents" => 2_000,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "second",
                   "cash_paid_cents" => 3_000,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = get_group(conn, "rooms-group")

    assert %{
             "results" => [
               %{
                 "cancelled_room_ids" => ["second"],
                 "refunded_cents" => 3_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "rooms-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "rooms-group",
                 "room_ids" => ["second"],
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "status" => "active",
               "lodging_total_cents" => 10_000,
               "deposit_due_cents" => 2_000,
               "deposit_paid_cents" => 2_000,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{"room_id" => "first", "status" => "active", "cash_paid_cents" => 2_000},
                 %{"room_id" => "second", "status" => "cancelled", "cash_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "rooms-group")
  end

  test "rejects invalid room selections atomically", %{conn: conn} do
    submit(conn, [open_operation("room-validation-open", "room-validation-group")])

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "invalid_rooms"
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "room-validation-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "room-validation-group",
                 "room_ids" => ["room-a", "room-a"],
                 "expected_revision" => 1
               }
             ])

    assert %{"data" => %{"status" => "active", "revision" => 1}} =
             get_group(conn, "room-validation-group")
  end

  test "transfers held cash between same-guest groups and exposes current payment holders", %{
    conn: conn
  } do
    submit(conn, [open_operation("transfer-source-open", "transfer-source")])
    submit(conn, [open_operation("transfer-destination-open", "transfer-destination")])

    submit(conn, [
      %{
        "operation_id" => "transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-source",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      }
    ])

    assert %{"data" => %{"cash_held_cents" => 5_000}} = get_ledger(conn)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "source_group_id" => "transfer-source",
                 "destination_group_id" => "transfer-destination",
                 "amount_cents" => 2_000,
                 "source_outstanding_deposit_cents" => 16_500,
                 "destination_outstanding_deposit_cents" => 17_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "transfer-cash",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "transfer-source",
                 "destination_group_id" => "transfer-destination",
                 "amount_cents" => 2_000,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               }
             ])

    assert %{
             "data" => %{
               "revision" => 3,
               "deposit_paid_cents" => 3_000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 3_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "transfer-source")

    assert %{
             "data" => %{
               "revision" => 2,
               "deposit_paid_cents" => 2_000,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "transfer-destination")

    assert %{
             "data" => %{
               "held_cents" => 5_000,
               "held_by_group" => [
                 %{"group_id" => "transfer-destination", "amount_cents" => 2_000},
                 %{"group_id" => "transfer-source", "amount_cents" => 3_000}
               ]
             }
           } = get_payment(conn, "transfer-payment")

    assert %{"data" => %{"cash_held_cents" => 5_000}} = get_ledger(conn)
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    submit(conn, [
      open_operation("correction-transfer-source-open", "correction-transfer-source")
    ])

    submit(conn, [
      open_operation("correction-transfer-destination-open", "correction-transfer-destination")
    ])

    submit(conn, [
      %{
        "operation_id" => "correction-transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "correction-transfer-source",
        "amount_cents" => 5_000
      },
      %{
        "operation_id" => "correction-transfer-operation",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-04",
        "source_group_id" => "correction-transfer-source",
        "destination_group_id" => "correction-transfer-destination",
        "amount_cents" => 2_000,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }
    ])

    assert %{
             "results" => [
               %{
                 "group_id" => "correction-transfer-source",
                 "outstanding_deposit_cents" => 16_500,
                 "revision" => 4
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "correction-after-transfer-reduction",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "correction-transfer-payment",
                 "amount_cents" => 1_500,
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 500}} =
             get_group(conn, "correction-transfer-destination")

    assert %{
             "results" => [
               %{
                 "charged_back_cents" => 3_500,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 5
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "correction-after-transfer-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "correction-transfer-payment",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => %{"revision" => 4, "deposit_paid_cents" => 0}} =
             get_group(conn, "correction-transfer-destination")

    assert %{
             "data" => %{
               "held_cents" => 0,
               "reduced_cents" => 1_500,
               "charged_back_cents" => 3_500,
               "held_by_group" => []
             }
           } = get_payment(conn, "correction-transfer-payment")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_reduced_cents" => 1_500,
               "cash_charged_back_cents" => 3_500
             }
           } = get_ledger(conn)
  end

  test "transfers only fill destination rooms that are still active", %{conn: conn} do
    submit(conn, [
      open_operation("active-room-transfer-source-open", "active-room-transfer-source")
    ])

    destination = %{
      open_operation("active-room-transfer-destination-open", "active-room-transfer-destination")
      | "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "cancelled-destination-room", "nightly_rate_cents" => 5_000},
          %{"room_id" => "active-destination-room", "nightly_rate_cents" => 5_000}
        ]
    }

    submit(conn, [destination])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "cancel-destination-room-before-transfer",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "active-room-transfer-destination",
                 "room_ids" => ["cancelled-destination-room"],
                 "expected_revision" => 1
               }
             ])

    submit(conn, [
      %{
        "operation_id" => "active-room-transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "active-room-transfer-source",
        "amount_cents" => 1_000
      }
    ])

    assert %{"results" => [%{"destination_revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "active-room-transfer",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "active-room-transfer-source",
                 "destination_group_id" => "active-room-transfer-destination",
                 "amount_cents" => 1_000,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "status" => "active",
               "rooms" => [
                 %{
                   "room_id" => "cancelled-destination-room",
                   "status" => "cancelled",
                   "cash_paid_cents" => 0
                 },
                 %{
                   "room_id" => "active-destination-room",
                   "status" => "active",
                   "cash_paid_cents" => 1_000
                 }
               ]
             }
           } = get_group(conn, "active-room-transfer-destination")
  end

  test "transfers mixed funding in reverse source order and fills destination rooms in draw order",
       %{
         conn: conn
       } do
    submit(conn, [open_operation("transfer-credit-open", "transfer-credit")])

    submit(conn, [
      %{
        "operation_id" => "transfer-credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-credit",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "transfer-credit-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-credit",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      }
    ])

    source = %{
      open_operation("transfer-mixed-source-open", "transfer-mixed-source")
      | "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "source-one", "nightly_rate_cents" => 10_000},
          %{"room_id" => "source-two", "nightly_rate_cents" => 10_000},
          %{"room_id" => "source-three", "nightly_rate_cents" => 10_000}
        ]
    }

    destination = %{
      open_operation("transfer-mixed-destination-open", "transfer-mixed-destination")
      | "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "destination-one", "nightly_rate_cents" => 5_000},
          %{"room_id" => "destination-two", "nightly_rate_cents" => 5_000},
          %{"room_id" => "destination-three", "nightly_rate_cents" => 5_000}
        ]
    }

    submit(conn, [source, %{destination | "guest_id" => "guest-22"}])

    submit(conn, [
      %{
        "operation_id" => "transfer-mixed-cash",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-mixed-source",
        "amount_cents" => 2_500,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "transfer-mixed-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-mixed-source",
        "amount_cents" => 1_000,
        "expected_revision" => 2
      }
    ])

    assert %{"data" => %{"cash_held_cents" => 2_500, "credit_liability_cents" => 1_100}} =
             get_ledger(conn, "2026-10-04")

    assert %{
             "results" => [
               %{
                 "amount_cents" => 2_500,
                 "source_outstanding_deposit_cents" => 5_000,
                 "destination_outstanding_deposit_cents" => 500,
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "transfer-mixed",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "transfer-mixed-source",
                 "destination_group_id" => "transfer-mixed-destination",
                 "amount_cents" => 2_500,
                 "expected_revision" => 3,
                 "destination_expected_revision" => 1
               }
             ])

    assert %{
             "data" => %{
               "deposit_paid_cents" => 1_000,
               "rooms" => [
                 %{"room_id" => "source-one", "cash_paid_cents" => 1_000},
                 %{"room_id" => "source-two", "cash_paid_cents" => 0},
                 %{"room_id" => "source-three", "cash_paid_cents" => 0}
               ]
             }
           } = get_group(conn, "transfer-mixed-source")

    assert %{
             "data" => %{
               "deposit_paid_cents" => 2_500,
               "rooms" => [
                 %{
                   "room_id" => "destination-one",
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 1_000
                 },
                 %{
                   "room_id" => "destination-two",
                   "cash_paid_cents" => 1_000,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "destination-three",
                   "cash_paid_cents" => 500,
                   "credit_paid_cents" => 0
                 }
               ]
             }
           } = get_group(conn, "transfer-mixed-destination")

    assert %{
             "data" => %{
               "held_by_group" => [
                 %{"group_id" => "transfer-mixed-destination", "amount_cents" => 1_500},
                 %{"group_id" => "transfer-mixed-source", "amount_cents" => 1_000}
               ]
             }
           } = get_payment(conn, "transfer-mixed-cash")

    assert %{"results" => [%{"refunded_cents" => 1_500, "revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "transfer-mixed-destination-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "transfer-mixed-destination",
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"available_cents" => 1_100}} =
             get_credit(conn, "guest-22", "2026-10-05")

    assert %{
             "data" => %{
               "held_cents" => 1_000,
               "refunded_cents" => 1_500,
               "held_by_group" => [
                 %{"group_id" => "transfer-mixed-source", "amount_cents" => 1_000}
               ]
             }
           } = get_payment(conn, "transfer-mixed-cash")
  end

  test "checks transfer existence and revisions before transfer rules", %{conn: conn} do
    submit(conn, [open_operation("transfer-validation-source", "transfer-validation-source")])

    submit(conn, [
      open_operation("transfer-validation-destination", "transfer-validation-destination")
    ])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "group_id" => "transfer-validation-source",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "transfer-source-stale",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "transfer-validation-source",
                 "destination_group_id" => "transfer-validation-source",
                 "amount_cents" => 0,
                 "expected_revision" => 0
               }
             ])

    assert %{
             "results" => [
               %{
                 "code" => "group_not_found",
                 "group_id" => "missing-transfer-destination"
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "missing-transfer-destination-op",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "transfer-validation-source",
                 "destination_group_id" => "missing-transfer-destination",
                 "amount_cents" => 1
               }
             ])

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "group_id" => "transfer-validation-destination",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "transfer-destination-stale",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "transfer-validation-source",
                 "destination_group_id" => "transfer-validation-destination",
                 "amount_cents" => 0,
                 "expected_revision" => 1,
                 "destination_expected_revision" => 0
               }
             ])
  end

  test "reduces held cash and reconciles the original payment", %{conn: conn} do
    submit(conn, [open_operation("reduction-open", "reduction-group")])

    submit(conn, [
      %{
        "operation_id" => "reduction-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "reduction-group",
        "amount_cents" => 5_000
      }
    ])

    assert %{
             "results" => [
               %{
                 "payment_operation_id" => "reduction-payment",
                 "amount_cents" => 2_000,
                 "outstanding_deposit_cents" => 16_500,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "reduction-one",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "reduction-payment",
                 "amount_cents" => 2_000,
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "payment_operation_id" => "reduction-payment",
               "original_group_id" => "reduction-group",
               "recorded_cents" => 5_000,
               "held_cents" => 3_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2_000,
               "charged_back_cents" => 0
             }
           } = get_payment(conn, "reduction-payment")

    assert %{"results" => [%{"amount_cents" => 3_000, "revision" => 4}]} =
             submit(conn, [
               %{
                 "operation_id" => "reduction-two",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "reduction-payment",
                 "amount_cents" => 3_000,
                 "expected_revision" => 3
               }
             ])

    assert %{"data" => %{"held_cents" => 0, "reduced_cents" => 5_000}} =
             get_payment(conn, "reduction-payment")

    assert %{"results" => [%{"code" => "payment_not_reducible"}]} =
             submit(conn, [
               %{
                 "operation_id" => "reduction-after",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-07",
                 "payment_operation_id" => "reduction-payment",
                 "amount_cents" => 1,
                 "expected_revision" => 4
               }
             ])
  end

  test "validates correction dates and distinguishes non-payment chargeback targets", %{
    conn: conn
  } do
    submit(conn, [open_operation("correction-validation-open", "correction-validation-group")])

    submit(conn, [
      %{
        "operation_id" => "correction-validation-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "correction-validation-group",
        "amount_cents" => 1_000
      }
    ])

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [
               %{
                 "operation_id" => "correction-invalid-reduction-date",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "not-a-date",
                 "payment_operation_id" => "correction-validation-payment",
                 "amount_cents" => 1
               }
             ])

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [
               %{
                 "operation_id" => "correction-invalid-chargeback-date",
                 "type" => "charge_back_payment",
                 "occurred_on" => "not-a-date",
                 "payment_operation_id" => "correction-validation-payment"
               }
             ])

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
             submit(conn, [
               %{
                 "operation_id" => "correction-open-target",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "correction-validation-open"
               }
             ])
  end

  test "prioritizes invalid selected rooms over a refund policy error", %{conn: conn} do
    advance = %{
      open_operation("room-policy-open", "room-policy-group")
      | "rate_plan" => "advance_purchase"
    }

    submit(conn, [advance])

    assert %{"results" => [%{"code" => "invalid_rooms"}]} =
             submit(conn, [
               %{
                 "operation_id" => "room-policy-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "room-policy-group",
                 "room_ids" => ["not-a-room"],
                 "refund_method" => "hotel_credit"
               }
             ])
  end

  test "chargebacks reverse a payment without rewriting its original result", %{conn: conn} do
    submit(conn, [open_operation("chargeback-open", "chargeback-group")])

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "chargeback-group",
                 "amount_cents" => 5_000
               }
             ])

    assert %{
             "results" => [
               %{
                 "payment_operation_id" => "chargeback-payment",
                 "charged_back_cents" => 5_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-one",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-05",
                 "payment_operation_id" => "chargeback-payment",
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"charged_back_cents" => 5_000, "held_cents" => 0}} =
             get_payment(conn, "chargeback-payment")

    assert %{"data" => %{"cash_charged_back_cents" => 5_000}} = get_ledger(conn)

    assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
             submit(conn, [
               %{
                 "operation_id" => "chargeback-two",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "chargeback-payment",
                 "expected_revision" => 3
               }
             ])
  end

  test "clawbacks credit entitlement and absorbs it when credit is restored", %{conn: conn} do
    submit(conn, [open_operation("clawback-source", "clawback-source")])

    submit(conn, [
      %{
        "operation_id" => "clawback-payment-one",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "clawback-source",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "clawback-payment-two",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "clawback-source",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "clawback-source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "clawback-source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 3
      }
    ])

    target = %{open_operation("clawback-target", "clawback-target") | "guest_id" => "guest-22"}
    submit(conn, [target])

    submit(conn, [
      %{
        "operation_id" => "clawback-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-01",
        "group_id" => "clawback-target",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      }
    ])

    assert %{"results" => [%{"charged_back_cents" => 500, "revision" => 5}]} =
             submit(conn, [
               %{
                 "operation_id" => "clawback-payment-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-11-02",
                 "payment_operation_id" => "clawback-payment-one",
                 "expected_revision" => 4
               }
             ])

    assert %{"data" => %{"credit_shortfall_cents" => 450}} = get_ledger(conn, "2026-11-02")

    assert %{"results" => [%{"revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "clawback-target-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "clawback-target",
                 "expected_revision" => 2
               }
             ])

    assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 550}} =
             get_ledger(conn, "2026-11-02")
  end

  test "starts reporting at the committed position and clamps later postings", %{conn: conn} do
    assert %{
             "results" => [
               _,
               _,
               %{
                 "operation_id" => "finance-start",
                 "status" => "applied",
                 "starts_on" => "2026-10-10"
               },
               _
             ]
           } =
             submit(conn, [
               open_operation("finance-open", "finance-group"),
               %{
                 "operation_id" => "finance-before-start",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-20",
                 "group_id" => "finance-group",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "finance-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-10"
               },
               %{
                 "operation_id" => "finance-after-start",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-09",
                 "group_id" => "finance-group",
                 "amount_cents" => 500,
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "date" => "2026-10-10",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "movements" => %{
                     "received_cents" => 500,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 1_500
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               }
             }
           } = get_daily_report(conn, "2026-10-10")

    assert %{"data" => %{"starts_on" => "2026-10-10"}} = get_operation(conn, "finance-start")

    assert %{"results" => [original]} =
             submit(conn, [
               %{
                 "operation_id" => "finance-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-10"
               }
             ])

    assert %{"results" => [^original]} =
             submit(conn, [
               %{
                 "operation_id" => "finance-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-10"
               }
             ])

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [
               %{
                 "operation_id" => "finance-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-11"
               }
             ])

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             submit(conn, [
               %{
                 "operation_id" => "finance-second-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-11"
               }
             ])
  end

  test "validates and gates the daily finance report endpoint", %{conn: conn} do
    assert response = get(conn, "/api/v1/finance/daily-report")
    assert response.status == 422
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert response = get(conn, "/api/v1/finance/daily-report?date=not-a-date")
    assert response.status == 422
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert response = get(conn, "/api/v1/finance/daily-report?date=2026-10-10")
    assert response.status == 404
    assert json_response(response, 404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "reports cash settlement movements and credit expiry without a write", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "settlement-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("settlement-open", "settlement-group"),
      %{
        "operation_id" => "settlement-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "settlement-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "settlement-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "settlement-group",
        "expected_revision" => 2,
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{"data" => %{"credit" => %{"closing_liability_cents" => 1_100}}} =
             get_daily_report(conn, "2026-10-03")

    assert %{"data" => %{"cash" => [%{"movements" => %{"received_cents" => 1_000}}]}} =
             get_daily_report(conn, "2026-10-02")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "movements" => %{
                     "received_cents" => 0,
                     "converted_to_credit_cents" => 1_000
                   },
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = get_daily_report(conn, "2026-10-03")

    assert %{"data" => %{"credit" => %{"closing_liability_cents" => 0}}} =
             get_daily_report(conn, "2027-10-04")

    assert %{"data" => %{"credit" => %{"movements" => %{"expired_cents" => 1_100}}}} =
             get_daily_report(conn, "2027-10-04")
  end

  test "reports transfers and corrections at the properties currently holding cash", %{conn: conn} do
    source = open_operation("report-transfer-source-open", "report-transfer-source")

    destination = %{
      open_operation("report-transfer-destination-open", "report-transfer-destination")
      | "property_id" => "bru-centre"
    }

    submit(conn, [
      %{
        "operation_id" => "report-transfer-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      source,
      destination,
      %{
        "operation_id" => "report-transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "report-transfer-source",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "report-transfer-move",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-03",
        "source_group_id" => "report-transfer-source",
        "destination_group_id" => "report-transfer-destination",
        "amount_cents" => 400,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      },
      %{
        "operation_id" => "report-transfer-reduction",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-04",
        "payment_operation_id" => "report-transfer-payment",
        "amount_cents" => 300,
        "expected_revision" => 3
      }
    ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 600,
                   "movements" => %{
                     "transferred_out_cents" => 0,
                     "reduced_cents" => 0
                   },
                   "closing_held_cents" => 600
                 },
                 %{
                   "property_id" => "bru-centre",
                   "opening_held_cents" => 400,
                   "movements" => %{
                     "transferred_in_cents" => 0,
                     "reduced_cents" => 300
                   },
                   "closing_held_cents" => 100
                 }
               ]
             }
           } = get_daily_report(conn, "2026-10-04")
  end

  test "keeps pre-report settlement provenance for a later chargeback", %{conn: conn} do
    source = open_operation("provenance-source-open", "provenance-source")

    destination = %{
      open_operation("provenance-destination-open", "provenance-destination")
      | "property_id" => "bru-centre"
    }

    submit(conn, [source, destination])

    submit(conn, [
      %{
        "operation_id" => "provenance-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "provenance-source",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "provenance-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-03",
        "source_group_id" => "provenance-source",
        "destination_group_id" => "provenance-destination",
        "amount_cents" => 400,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      },
      %{
        "operation_id" => "provenance-destination-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "provenance-destination",
        "expected_revision" => 2
      }
    ])

    submit(conn, [
      %{
        "operation_id" => "provenance-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-10"
      }
    ])

    assert %{"results" => [%{"charged_back_cents" => 1_000}]} =
             submit(conn, [
               %{
                 "operation_id" => "provenance-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-11",
                 "payment_operation_id" => "provenance-payment",
                 "expected_revision" => 3
               }
             ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 600,
                   "movements" => %{"charged_back_cents" => 600},
                   "closing_held_cents" => 0
                 },
                 %{
                   "property_id" => "bru-centre",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "refunded_cents" => -400,
                     "charged_back_cents" => 400
                   },
                   "closing_held_cents" => 0
                 }
               ]
             }
           } = get_daily_report(conn, "2026-10-11")
  end

  test "shows credit expiring on the reporting inception date", %{conn: conn} do
    submit(conn, [
      open_operation("inception-expiry-open", "inception-expiry-group"),
      %{
        "operation_id" => "inception-expiry-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2025-10-04",
        "group_id" => "inception-expiry-group",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "inception-expiry-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2025-10-09",
        "group_id" => "inception-expiry-group",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "inception-expiry-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-10"
      }
    ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 1_100,
                 "movements" => %{"expired_cents" => 1_100},
                 "closing_liability_cents" => 0
               }
             }
           } = get_daily_report(conn, "2026-10-10")
  end

  test "reports credit consumption and revocation as liability movements", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "credit-report-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("credit-report-open", "credit-report-group"),
      %{
        "operation_id" => "credit-report-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "credit-report-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "credit-report-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "credit-report-group",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "credit-report-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-04",
        "payment_operation_id" => "credit-report-payment",
        "expected_revision" => 3
      }
    ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "movements" => %{
                     "converted_to_credit_cents" => -1_000,
                     "charged_back_cents" => 1_000
                   }
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 1_100,
                 "movements" => %{"revoked_cents" => 1_100},
                 "closing_liability_cents" => 0
               }
             }
           } = get_daily_report(conn, "2026-10-04")
  end

  test "closes reports durably and posts later old-dated operations as late adjustments", %{
    conn: conn
  } do
    assert %{
             "results" => [
               %{"operation_id" => "period-start", "status" => "applied"},
               %{"operation_id" => "period-open", "revision" => 1},
               %{"operation_id" => "period-payment", "revision" => 2},
               close_result
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "period-start",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2026-10-01"
               },
               open_operation("period-open", "period-group"),
               %{
                 "operation_id" => "period-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "period-group",
                 "amount_cents" => 1_000,
                 "expected_revision" => 1
               },
               %{
                 "operation_id" => "period-close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-03"
               }
             ])

    assert Map.keys(close_result) |> Enum.sort() == ["operation_id", "period_end_on", "status"]

    assert close_result == %{
             "operation_id" => "period-close",
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    closed_before = get_daily_report(conn, "2026-10-02")

    assert %{"data" => %{"status" => "closed", "cash" => [%{"movements" => movements}]}} =
             closed_before

    assert movements["received_cents"] == 1_000

    assert %{"data" => %{"status" => "closed"}} = get_daily_report(conn, "2026-10-01")
    assert %{"data" => %{"status" => "closed"}} = get_daily_report(conn, "2026-10-03")
    assert %{"data" => %{"status" => "open"}} = get_daily_report(conn, "2026-10-04")

    assert %{"results" => [%{"revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "period-late-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-02",
                 "group_id" => "period-group",
                 "amount_cents" => 500,
                 "expected_revision" => 2
               }
             ])

    assert get_daily_report(conn, "2026-10-02") == closed_before

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [%{"opening_held_cents" => 1_000, "closing_held_cents" => 1_500}],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"received_cents" => 500}
                   }
                 ],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = get_daily_report(conn, "2026-10-04")

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "period-close-later",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-04"
               }
             ])

    assert %{"data" => %{"status" => "closed"}} = get_daily_report(conn, "2026-10-04")
  end

  test "enforces close cutoffs and remembers rejected and applied closes", %{conn: conn} do
    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             submit(conn, [
               %{
                 "operation_id" => "close-before-start",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-01"
               }
             ])

    submit(conn, [
      %{
        "operation_id" => "cutoff-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-10"
      }
    ])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             submit(conn, [
               %{
                 "operation_id" => "close-before-start-date",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-09"
               }
             ])

    assert %{"results" => [original]} =
             submit(conn, [
               %{
                 "operation_id" => "cutoff-close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-10"
               }
             ])

    assert %{"results" => [^original]} =
             submit(conn, [
               %{
                 "operation_id" => "cutoff-close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-10"
               }
             ])

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [
               %{
                 "operation_id" => "cutoff-close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-11"
               }
             ])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             submit(conn, [
               %{
                 "operation_id" => "cutoff-same",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-10"
               }
             ])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             submit(conn, [
               %{
                 "operation_id" => "cutoff-earlier",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-09"
               }
             ])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             submit(conn, [
               %{
                 "operation_id" => "close-before-start",
                 "type" => "close_finance_period",
                 "period_end_on" => "2026-10-01"
               }
             ])
  end

  test "keeps late refund reversals classified independently", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "late-reversal-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      open_operation("late-reversal-open", "late-reversal-group"),
      %{
        "operation_id" => "late-reversal-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-02",
        "group_id" => "late-reversal-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "late-reversal-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-02",
        "group_id" => "late-reversal-group",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "late-reversal-close",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-05"
      }
    ])

    submit(conn, [
      %{
        "operation_id" => "late-reversal-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-02",
        "payment_operation_id" => "late-reversal-payment",
        "expected_revision" => 3
      }
    ])

    assert %{
             "data" => %{
               "cash" => [%{"opening_held_cents" => 0, "closing_held_cents" => 0}],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "movements" => %{
                       "refunded_cents" => -1_000,
                       "charged_back_cents" => 1_000
                     }
                   }
                 ]
               }
             }
           } = get_daily_report(conn, "2026-10-06")
  end

  test "does not synthesize a second expiry for a late credit issue", %{conn: conn} do
    submit(conn, [
      %{
        "operation_id" => "late-credit-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      %{open_operation("late-credit-open", "late-credit-group") | "arrival_on" => "2026-12-10"},
      %{
        "operation_id" => "late-credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "late-credit-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "late-credit-close",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-02"
      }
    ])

    assert %{"results" => [%{"credit_issued_cents" => 1_100}]} =
             submit(conn, [
               %{
                 "operation_id" => "late-credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-01-01",
                 "group_id" => "late-credit-group",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{"issued_cents" => 0, "expired_cents" => 0},
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "credit" => %{"issued_cents" => 1_100, "expired_cents" => 1_100}
               }
             }
           } = get_daily_report(conn, "2027-01-03")
  end

  test "expires only the available portion after credit is consumed", %{conn: conn} do
    source =
      open_operation("partial-expiry-source", "partial-expiry-source")
      |> Map.merge(%{"occurred_on" => "2026-01-01"})

    target =
      open_operation("partial-expiry-target", "partial-expiry-target")
      |> Map.merge(%{"guest_id" => "guest-22"})

    submit(conn, [
      %{
        "operation_id" => "partial-expiry-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      source,
      %{
        "operation_id" => "partial-expiry-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-01",
        "group_id" => "partial-expiry-source",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "partial-expiry-cancel-source",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-01",
        "group_id" => "partial-expiry-source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      target,
      %{
        "operation_id" => "partial-expiry-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-30",
        "group_id" => "partial-expiry-target",
        "amount_cents" => 500,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "partial-expiry-cancel-target",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-31",
        "group_id" => "partial-expiry-target",
        "expected_revision" => 2
      }
    ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 600,
                 "movements" => %{"expired_cents" => 600},
                 "closing_liability_cents" => 0
               }
             }
           } = get_daily_report(conn, "2027-01-02")
  end

  test "does not let a late restoration change an already expired available balance", %{
    conn: conn
  } do
    source =
      open_operation("late-restore-source", "late-restore-source")
      |> Map.merge(%{"occurred_on" => "2026-01-01"})

    target =
      open_operation("late-restore-target", "late-restore-target")
      |> Map.merge(%{
        "guest_id" => "guest-22",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-04"
      })

    submit(conn, [
      %{
        "operation_id" => "late-restore-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-01-01"
      },
      source,
      %{
        "operation_id" => "late-restore-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-01",
        "group_id" => "late-restore-source",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "late-restore-cancel-source",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-01",
        "group_id" => "late-restore-source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      target,
      %{
        "operation_id" => "late-restore-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-30",
        "group_id" => "late-restore-target",
        "amount_cents" => 500,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "late-restore-close",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-02"
      }
    ])

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "late-restore-cancel-target",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-31",
                 "group_id" => "late-restore-target",
                 "expected_revision" => 2
               }
             ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 500,
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "credit" => %{"expired_cents" => 500}
               }
             }
           } = get_daily_report(conn, "2027-01-03")
  end

  defp open_operation(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
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

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
  end

  defp get_ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
  end

  defp get_ledger(conn, on) do
    conn
    |> get("/api/v1/ledger?on=#{on}")
    |> json_response(200)
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
  end

  defp get_credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
  end

  defp get_daily_report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
  end

  defp submit_json(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", ~s({"operations":[#{payload}]}))
    |> json_response(200)
  end

  defp get_operation(conn, operation_id) do
    conn
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
  end
end
