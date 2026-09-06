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
               "deposit_paid_cents" => 5_000,
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

  defp get_credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
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
