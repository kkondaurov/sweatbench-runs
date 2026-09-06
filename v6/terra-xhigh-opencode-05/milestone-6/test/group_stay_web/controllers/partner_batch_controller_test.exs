defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Repo
  alias GroupStay.Reservations.PartnerOperation

  test "opens a group and returns its calculated totals and rooms", %{conn: conn} do
    conn = post_batch(conn, [open_group("open-1")])

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
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/groups/group-1")

    assert %{
             "data" => %{
               "group_id" => "group-1",
               "guest_id" => "guest-1",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             }
           } = json_response(conn, 200)
  end

  test "processes dependent operations in order and increments revisions", %{conn: conn} do
    operations = [
      open_group("open-1"),
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-1",
        "new_arrival_on" => "2026-12-15",
        "expected_revision" => 2
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "payment-1",
                 "status" => "applied",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "move-1",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-15",
                 "new_departure_on" => "2026-12-18",
                 "revision" => 3
               }
             ]
           } = post_batch(conn, operations) |> json_response(200)

    conn = get(build_conn(), "/api/v1/groups/group-1")

    assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 18_500}} =
             json_response(conn, 200)
  end

  test "rejects stale revisions before other domain validation without changing the group", %{
    conn: conn
  } do
    post_batch(conn, [open_group("open-1")])

    stale_payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "not-a-date",
      "group_id" => "group-1",
      "amount_cents" => -10,
      "expected_revision" => 0
    }

    assert %{
             "results" => [
               %{
                 "operation_id" => "payment-1",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               }
             ]
           } = post_batch(build_conn(), [stale_payment]) |> json_response(200)

    conn = get(build_conn(), "/api/v1/groups/group-1")
    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = json_response(conn, 200)
  end

  test "settles cancellation cash and reports ledger totals", %{conn: conn} do
    operations = [
      open_group("open-1"),
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-1"
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "operation_id" => "cancel-1",
                 "status" => "applied",
                 "refunded_cents" => 1_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ]
           } = post_batch(conn, operations) |> json_response(200)

    conn = get(build_conn(), "/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 1_000,
               "cash_retained_cents" => 0
             }
           } = json_response(conn, 200)

    assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    cancelled_payment = %{
      "operation_id" => "payment-2",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-27",
      "group_id" => "group-1",
      "amount_cents" => 1
    }

    assert %{"results" => [%{"status" => "rejected", "code" => "group_not_active"}]} =
             post_batch(build_conn(), [cancelled_payment]) |> json_response(200)
  end

  test "retains advance-purchase cash on cancellation", %{conn: conn} do
    open_group = Map.put(open_group("open-1"), "rate_plan", "advance_purchase")

    payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => 1_000
    }

    cancellation = %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1"
    }

    assert %{
             "results" => [
               %{"deposit_due_cents" => 97_500},
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 1_000}
             ]
           } = post_batch(conn, [open_group, payment, cancellation]) |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 0, "cash_retained_cents" => 1_000}} =
             get(build_conn(), "/api/v1/ledger") |> json_response(200)
  end

  test "keeps earlier operations when an operation is invalid and continues the batch", %{
    conn: conn
  } do
    operations = [
      open_group("open-1"),
      %{"operation_id" => "bad-1", "type" => "unknown"},
      %{
        "operation_id" => "payment-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 500
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{
                 "operation_id" => "bad-1",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"status" => "applied", "outstanding_deposit_cents" => 19_000}
             ]
           } = post_batch(conn, operations) |> json_response(200)
  end

  test "returns the original applied result for equivalent retries and retains the audit record",
       %{
         conn: conn
       } do
    operation = open_group("open-1")

    assert %{"results" => [original_result]} = post_batch(conn, [operation]) |> json_response(200)

    payment = cash_payment("payment-1", "group-1", "2026-10-04", 1_000)

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
             post_batch(build_conn(), [payment]) |> json_response(200)

    equivalent_operation = %{
      "rooms" => [
        %{"nightly_rate_cents" => 15_000, "room_id" => "room-a"},
        %{"nightly_rate_cents" => 17_500, "room_id" => "room-b"}
      ],
      "rate_plan" => "flexible",
      "departure_on" => "2026-12-13",
      "arrival_on" => "2026-12-10",
      "property_id" => "ams-canal",
      "guest_id" => "guest-1",
      "group_id" => "group-1",
      "occurred_on" => "2026-10-03",
      "type" => "open_group",
      "operation_id" => "open-1"
    }

    assert %{"results" => [^original_result]} =
             post_batch(build_conn(), [equivalent_operation]) |> json_response(200)

    assert %{"data" => ^original_result} =
             get(build_conn(), "/api/v1/operations/open-1") |> json_response(200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    records = Repo.all(PartnerOperation) |> Enum.sort_by(& &1.id)

    assert Enum.map(records, & &1.operation_id) == ["open-1", "payment-1"]
    assert Enum.map(records, & &1.operation_type) == ["open_group", "record_cash_payment"]
    assert Jason.decode!(hd(records).submitted_payload) == operation
  end

  test "remembers rejected operations after later state changes", %{conn: conn} do
    payment = cash_payment("payment-1", "group-1", "2026-10-04", 500)

    assert %{"results" => [rejected_result]} = post_batch(conn, [payment]) |> json_response(200)

    assert rejected_result == %{
             "operation_id" => "payment-1",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "group-1"
           }

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(build_conn(), [open_group("open-1")]) |> json_response(200)

    assert %{"results" => [^rejected_result]} =
             post_batch(build_conn(), [payment]) |> json_response(200)

    assert %{"data" => ^rejected_result} =
             get(build_conn(), "/api/v1/operations/payment-1") |> json_response(200)

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
  end

  test "rejects changed retries without replacing a stored stale result", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied", "revision" => 2}]} =
             post_batch(conn, [
               open_group("open-1"),
               cash_payment("payment-1", "group-1", "2026-10-04", 1_000)
             ])
             |> json_response(200)

    stale_payment = %{
      "operation_id" => "stale-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-1",
      "amount_cents" => 1,
      "expected_revision" => 1
    }

    assert %{"results" => [stale_result]} =
             post_batch(build_conn(), [stale_payment]) |> json_response(200)

    assert stale_result == %{
             "operation_id" => "stale-payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    corrected_payment = Map.put(stale_payment, "expected_revision", 2)

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict",
                 "group_id" => "group-1"
               }
             ]
           } = post_batch(build_conn(), [corrected_payment]) |> json_response(200)

    assert %{"data" => ^stale_result} =
             get(build_conn(), "/api/v1/operations/stale-payment") |> json_response(200)

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             get(build_conn(), "/api/v1/operations/not-here") |> json_response(404)
  end

  test "rejects invalid batches and missing groups with the documented response codes", %{
    conn: conn
  } do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             post(conn, "/api/v1/partner-batches", %{}) |> json_response(422)

    missing_group_payment = %{
      "operation_id" => "payment-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "not-here",
      "amount_cents" => 500
    }

    assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
             post_batch(build_conn(), [missing_group_payment]) |> json_response(200)

    assert %{"error" => %{"code" => "group_not_found"}} =
             get(build_conn(), "/api/v1/groups/not-here") |> json_response(404)
  end

  test "rejects invalid opening data without creating a group", %{conn: conn} do
    invalid_rooms =
      open_group("open-1")
      |> Map.put("rooms", [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
      ])

    invalid_stay = open_group("open-2") |> Map.put("departure_on", "2026-12-10")
    invalid_rate_plan = open_group("open-3") |> Map.put("rate_plan", "corporate")

    assert %{
             "results" => [
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rate_plan"}
             ]
           } =
             post_batch(conn, [invalid_rooms, invalid_stay, invalid_rate_plan])
             |> json_response(200)

    assert %{"error" => %{"code" => "group_not_found"}} =
             get(build_conn(), "/api/v1/groups/group-1") |> json_response(404)
  end

  test "fixes cancellation policy at booking and recomputes its cutoff when rescheduled", %{
    conn: conn
  } do
    legacy =
      open_group("open-legacy", "legacy", %{
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-03-20",
        "departure_on" => "2027-03-23"
      })

    current =
      open_group("open-current", "current", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-20",
        "departure_on" => "2027-03-23"
      })

    advance =
      open_group("open-advance", "advance", %{
        "occurred_on" => "2027-01-01",
        "rate_plan" => "advance_purchase"
      })

    reschedule = %{
      "operation_id" => "move-legacy",
      "type" => "reschedule_group",
      "occurred_on" => "2027-01-02",
      "group_id" => "legacy",
      "new_arrival_on" => "2027-04-20"
    }

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-04-06"
               }
             ]
           } = post_batch(conn, [legacy, current, advance, reschedule]) |> json_response(200)

    assert %{"data" => %{"policy_version" => "flex-14", "refundable_until" => "2027-04-06"}} =
             get(build_conn(), "/api/v1/groups/legacy") |> json_response(200)

    assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-02-18"}} =
             get(build_conn(), "/api/v1/groups/current") |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
           } = get(build_conn(), "/api/v1/groups/advance") |> json_response(200)
  end

  test "converts refundable cash to credit, applies it, and restores it without another bonus", %{
    conn: conn
  } do
    source =
      open_group("open-source", "source", %{
        "guest_id" => "credit-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-04-15",
        "departure_on" => "2027-04-16"
      })

    target =
      open_group("open-target", "target", %{
        "guest_id" => "credit-guest",
        "occurred_on" => "2027-01-02",
        "arrival_on" => "2027-05-15",
        "departure_on" => "2027-05-16"
      })

    operations = [
      source,
      cash_payment("pay-source", "source", "2027-01-02", 5),
      %{
        "operation_id" => "cancel-source",
        "type" => "cancel_group",
        "occurred_on" => "2027-03-16",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      target,
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-03-17",
        "group_id" => "target",
        "amount_cents" => 6
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
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
                 "outstanding_deposit_cents" => 6_494,
                 "revision" => 2
               }
             ]
           } = post_batch(conn, operations) |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 6,
               "deposit_paid_cents" => 6
             }
           } = get(build_conn(), "/api/v1/groups/target") |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(build_conn(), "/api/v1/guests/credit-guest/credit") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    restore = %{
      "operation_id" => "cancel-target",
      "type" => "cancel_group",
      "occurred_on" => "2027-03-18",
      "group_id" => "target"
    }

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ]
           } = post_batch(build_conn(), [restore]) |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-03-16"
                 }
               ]
             }
           } = get(build_conn(), "/api/v1/guests/credit-guest/credit") |> json_response(200)

    nonrefundable =
      open_group("open-mixed", "mixed", %{
        "guest_id" => "credit-guest",
        "rate_plan" => "advance_purchase"
      })

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 10,
                 "credit_issued_cents" => 0
               }
             ]
           } =
             post_batch(build_conn(), [
               nonrefundable,
               cash_payment("pay-mixed", "mixed", "2027-03-19", 10),
               %{
                 "operation_id" => "apply-mixed-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-03-19",
                 "group_id" => "mixed",
                 "amount_cents" => 6
               },
               %{
                 "operation_id" => "cancel-mixed",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-03-20",
                 "group_id" => "mixed"
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(build_conn(), "/api/v1/guests/credit-guest/credit") |> json_response(200)

    assert %{
             "data" => %{
               "cash_retained_cents" => 10,
               "credit_liability_cents" => 0
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
  end

  test "consumes equal-expiry lots by source operation and rejects unavailable credit without revision changes",
       %{
         conn: conn
       } do
    source_z =
      open_group("open-z", "source-z", %{
        "guest_id" => "ordered-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16"
      })

    source_a =
      open_group("open-a", "source-a", %{
        "guest_id" => "ordered-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16"
      })

    target =
      open_group("open-target", "credit-target", %{
        "guest_id" => "ordered-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-05-15",
        "departure_on" => "2027-05-16"
      })

    operations = [
      source_z,
      cash_payment("pay-z", "source-z", "2027-01-02", 10),
      %{
        "operation_id" => "cancel-z",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-10",
        "group_id" => "source-z",
        "refund_method" => "hotel_credit"
      },
      source_a,
      cash_payment("pay-a", "source-a", "2027-01-02", 10),
      %{
        "operation_id" => "cancel-a",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-10",
        "group_id" => "source-a",
        "refund_method" => "hotel_credit"
      },
      target,
      %{
        "operation_id" => "apply-ordered-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-11",
        "group_id" => "credit-target",
        "amount_cents" => 15
      }
    ]

    assert %{"results" => results} = post_batch(conn, operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "data" => %{
               "available_cents" => 7,
               "lots" => [
                 %{"source_operation_id" => "cancel-z", "remaining_cents" => 7}
               ]
             }
           } = get(build_conn(), "/api/v1/guests/ordered-guest/credit") |> json_response(200)

    stale_and_insufficient = %{
      "operation_id" => "bad-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-11",
      "group_id" => "credit-target",
      "amount_cents" => 1,
      "expected_revision" => 1
    }

    assert %{
             "results" => [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           } = post_batch(build_conn(), [stale_and_insufficient]) |> json_response(200)

    assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 15}} =
             get(build_conn(), "/api/v1/groups/credit-target") |> json_response(200)
  end

  test "expires restored credit and leaves non-refundable hotel-credit requests unchanged", %{
    conn: conn
  } do
    source =
      open_group("open-expiring", "expiring-source", %{
        "guest_id" => "expiry-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16"
      })

    source_cancelled_on = ~D[2027-01-10]
    credit_expires_on = Date.add(source_cancelled_on, 366)
    target_cancelled_on = Date.add(credit_expires_on, 1)

    target =
      open_group("open-expiry-target", "expiry-target", %{
        "guest_id" => "expiry-guest",
        "occurred_on" => "2027-01-01",
        "arrival_on" => Date.add(target_cancelled_on, 31) |> Date.to_iso8601(),
        "departure_on" => Date.add(target_cancelled_on, 32) |> Date.to_iso8601()
      })

    operations = [
      source,
      cash_payment("pay-expiring", "expiring-source", "2027-01-02", 10),
      %{
        "operation_id" => "cancel-expiring",
        "type" => "cancel_group",
        "occurred_on" => Date.to_iso8601(source_cancelled_on),
        "group_id" => "expiring-source",
        "refund_method" => "hotel_credit"
      },
      target,
      %{
        "operation_id" => "apply-expiring-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-11",
        "group_id" => "expiry-target",
        "amount_cents" => 11
      },
      %{
        "operation_id" => "cancel-expiry-target",
        "type" => "cancel_group",
        "occurred_on" => Date.to_iso8601(target_cancelled_on),
        "group_id" => "expiry-target"
      }
    ]

    assert %{"results" => results} = post_batch(conn, operations) |> json_response(200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(
               build_conn(),
               "/api/v1/guests/expiry-guest/credit?on=#{Date.to_iso8601(target_cancelled_on)}"
             )
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(build_conn(), "/api/v1/ledger?on=#{Date.to_iso8601(target_cancelled_on)}")
             |> json_response(200)

    advance =
      open_group("open-nonrefundable", "nonrefundable", %{
        "guest_id" => "another-guest",
        "rate_plan" => "advance_purchase"
      })

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               }
             ]
           } =
             post_batch(build_conn(), [
               advance,
               cash_payment("pay-nonrefundable", "nonrefundable", "2026-10-04", 10),
               %{
                 "operation_id" => "cancel-nonrefundable",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "nonrefundable",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"status" => "active", "revision" => 2, "cash_paid_cents" => 10}} =
             get(build_conn(), "/api/v1/groups/nonrefundable") |> json_response(200)
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp open_group(operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-1",
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

  defp open_group(operation_id, group_id, overrides) do
    open_group(operation_id)
    |> Map.put("group_id", group_id)
    |> Map.merge(overrides)
  end

  defp cash_payment(operation_id, group_id, occurred_on, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
