defmodule GroupStayWeb.PartnerOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.PartnerOperation

  test "opens a group, calculates deposits per room, and exposes it in the read API", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("group-81",
          rooms: rooms_for_rounding(),
          departure_on: "2026-12-11"
        )
      ])

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-group-81",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 2,
                 "revision" => 1
               }
             ]
           }

    group = get(conn, "/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert group == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-11",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 1,
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 3},
               %{"room_id" => "room-b", "nightly_rate_cents" => 3}
             ],
             "lodging_total_cents" => 6,
             "deposit_due_cents" => 2,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 2,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26"
           }
  end

  test "processes a batch in order and lets later operations observe an opening", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-81"),
        %{
          "operation_id" => "payment-81",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 1_000
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "open-group-81",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             },
             %{
               "operation_id" => "payment-81",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 18_500,
               "revision" => 2
             }
           ]

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 1_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "rejects an invalid operation without undoing neighboring operations", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-81"),
        %{
          "operation_id" => "too-much",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 19_501
        },
        %{
          "operation_id" => "valid-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 500
        }
      ])

    assert Enum.map(response["results"], &Map.take(&1, ["operation_id", "status", "code"])) == [
             %{"operation_id" => "open-group-81", "status" => "applied"},
             %{
               "operation_id" => "too-much",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             },
             %{"operation_id" => "valid-payment", "status" => "applied"}
           ]

    assert get(conn, "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2
  end

  test "enforces expected revisions before later domain checks", %{conn: conn} do
    submit(conn, [open_operation("group-81")])

    submit(conn, [
      %{
        "operation_id" => "payment-81",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      }
    ])

    response =
      submit(conn, [
        %{
          "operation_id" => "stale-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "not-a-date",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "missing-group",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "missing-group",
          "expected_revision" => 1
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             },
             %{
               "operation_id" => "missing-group",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "missing-group"
             }
           ]

    assert get(conn, "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2
  end

  test "reschedules an active group without changing its price", %{conn: conn} do
    submit(conn, [
      open_operation("group-81", arrival_on: "2026-12-10", departure_on: "2026-12-13")
    ])

    response =
      submit(conn, [
        %{
          "operation_id" => "move-81",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 1
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "move-81",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }
           ]

    group = get(conn, "/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["lodging_total_cents"] == 97_500
    assert group["deposit_due_cents"] == 19_500
    assert group["arrival_on"] == "2026-12-20"
    assert group["departure_on"] == "2026-12-23"
  end

  test "cancellation settles paid cash as a refund or retention and clears the outstanding amount",
       %{conn: conn} do
    submit(conn, [open_operation("refundable")])
    submit(conn, [open_operation("non-refundable", rate_plan: "advance_purchase")])

    submit(conn, [
      payment_operation("refundable", 1_000),
      payment_operation("non-refundable", 10_000)
    ])

    response =
      submit(conn, [
        %{
          "operation_id" => "cancel-refund",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "refundable",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "cancel-retain",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "non-refundable",
          "expected_revision" => 2
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "cancel-refund",
               "status" => "applied",
               "group_id" => "refundable",
               "refunded_cents" => 1_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             },
             %{
               "operation_id" => "cancel-retain",
               "status" => "applied",
               "group_id" => "non-refundable",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ]

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 1_000,
               "cash_retained_cents" => 10_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }

    group = get(conn, "/api/v1/groups/refundable") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["deposit_paid_cents"] == 1_000
    assert group["outstanding_deposit_cents"] == 0

    rejected =
      submit(conn, [
        payment_operation("refundable", 1)
        |> Map.put("operation_id", "payment-after-cancellation-refundable")
      ])

    assert rejected["results"] == [
             %{
               "operation_id" => "payment-after-cancellation-refundable",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "refundable"
             }
           ]
  end

  test "fixes cancellation policies at booking and reports their rescheduled refund dates", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("legacy-flex",
        occurred_on: "2026-12-31",
        arrival_on: "2027-03-20",
        departure_on: "2027-03-23"
      ),
      open_operation("new-flex",
        occurred_on: "2027-01-01",
        arrival_on: "2027-03-20",
        departure_on: "2027-03-23"
      ),
      open_operation("advance", rate_plan: "advance_purchase")
    ])

    assert get(conn, "/api/v1/groups/legacy-flex")
           |> json_response(200)
           |> get_in(["data", "policy_version"]) == "flex-14"

    assert get(conn, "/api/v1/groups/legacy-flex")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == "2027-03-06"

    assert get(conn, "/api/v1/groups/new-flex")
           |> json_response(200)
           |> get_in(["data", "policy_version"]) == "flex-30"

    assert get(conn, "/api/v1/groups/new-flex")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == "2027-02-18"

    assert get(conn, "/api/v1/groups/advance")
           |> json_response(200)
           |> Map.fetch!("data")
           |> Map.take(["policy_version", "refundable_until"]) == %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           }

    response =
      submit(conn, [
        %{
          "operation_id" => "move-new-flex",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "new-flex",
          "new_arrival_on" => "2027-05-01",
          "expected_revision" => 1
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "move-new-flex",
               "status" => "applied",
               "group_id" => "new-flex",
               "new_arrival_on" => "2027-05-01",
               "new_departure_on" => "2027-05-04",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-04-01",
               "revision" => 2
             }
           ]
  end

  test "converts refundable cash into hotel credit and reports its liability", %{conn: conn} do
    submit(conn, [open_operation("credit-source")])
    submit(conn, [payment_operation("credit-source", 1_000)])

    response =
      submit(conn, [
        %{
          "operation_id" => "cancel-to-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "credit-source",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "cancel-to-credit",
               "status" => "applied",
               "group_id" => "credit-source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_100,
               "revision" => 3
             }
           ]

    assert get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-27") |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 1_100,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-to-credit",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }
           }

    assert get(conn, "/api/v1/ledger?on=2026-11-27") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_000,
               "credit_liability_cents" => 1_100
             }
           }
  end

  test "uses credit lots by expiry and source, then restores refundable credit without a second bonus",
       %{conn: conn} do
    submit(conn, [
      open_operation("source-z",
        occurred_on: "2026-01-01",
        arrival_on: "2026-03-01",
        departure_on: "2026-03-04"
      ),
      open_operation("source-a",
        occurred_on: "2026-01-01",
        arrival_on: "2026-03-01",
        departure_on: "2026-03-04"
      )
    ])

    submit(conn, [
      Map.put(payment_operation("source-z", 100), "occurred_on", "2026-01-02"),
      Map.put(payment_operation("source-a", 100), "occurred_on", "2026-01-02")
    ])

    submit(conn, [
      %{
        "operation_id" => "credit-z",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "source-z",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "credit-a",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "source-a",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      open_operation("credit-target",
        occurred_on: "2026-01-04",
        arrival_on: "2026-03-10",
        departure_on: "2026-03-13"
      )
    ])

    response =
      submit(conn, [
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-01-05",
          "group_id" => "credit-target",
          "amount_cents" => 200,
          "expected_revision" => 1
        }
      ])

    assert response["results"] == [
             %{
               "operation_id" => "apply-credit",
               "status" => "applied",
               "group_id" => "credit-target",
               "amount_cents" => 200,
               "outstanding_deposit_cents" => 19_300,
               "revision" => 2
             }
           ]

    assert get(conn, "/api/v1/guests/guest-22/credit?on=2026-01-06") |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 20,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-z",
                   "remaining_cents" => 20,
                   "expires_on" => "2027-01-04"
                 }
               ]
             }
           }

    group = get(conn, "/api/v1/groups/credit-target") |> json_response(200) |> Map.fetch!("data")

    assert Map.take(group, ["cash_paid_cents", "credit_paid_cents", "deposit_paid_cents"]) == %{
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 200,
             "deposit_paid_cents" => 0
           }

    assert get(conn, "/api/v1/ledger?on=2026-01-06")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 220

    restored =
      submit(conn, [
        %{
          "operation_id" => "cancel-credit-target",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-06",
          "group_id" => "credit-target",
          "expected_revision" => 2
        }
      ])

    assert restored["results"] == [
             %{
               "operation_id" => "cancel-credit-target",
               "status" => "applied",
               "group_id" => "credit-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ]

    assert get(conn, "/api/v1/guests/guest-22/credit?on=2026-01-06") |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 220,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-a",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-01-04"
                 },
                 %{
                   "source_operation_id" => "credit-z",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-01-04"
                 }
               ]
             }
           }
  end

  test "rejects hotel credit for non-refundable cancellation and consumes it when cancelled", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("credit-source",
        occurred_on: "2026-01-01",
        arrival_on: "2026-03-01",
        departure_on: "2026-03-04"
      )
    ])

    submit(conn, [Map.put(payment_operation("credit-source", 100), "occurred_on", "2026-01-02")])

    submit(conn, [
      %{
        "operation_id" => "credit-source-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      open_operation("advance-credit-target",
        occurred_on: "2026-01-04",
        rate_plan: "advance_purchase",
        arrival_on: "2026-03-10",
        departure_on: "2026-03-13"
      )
    ])

    applied =
      submit(conn, [
        %{
          "operation_id" => "apply-advance-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-01-05",
          "group_id" => "advance-credit-target",
          "amount_cents" => 100,
          "expected_revision" => 1
        }
      ])

    assert applied["results"] |> hd() |> Map.take(["status", "revision"]) == %{
             "status" => "applied",
             "revision" => 2
           }

    rejected =
      submit(conn, [
        %{
          "operation_id" => "bad-credit-refund",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-06",
          "group_id" => "advance-credit-target",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert rejected["results"] == [
             %{
               "operation_id" => "bad-credit-refund",
               "status" => "rejected",
               "code" => "refund_method_not_available",
               "group_id" => "advance-credit-target"
             }
           ]

    assert get(conn, "/api/v1/groups/advance-credit-target")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    cancelled =
      submit(conn, [
        %{
          "operation_id" => "cancel-advance-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-06",
          "group_id" => "advance-credit-target",
          "expected_revision" => 2
        }
      ])

    assert cancelled["results"] == [
             %{
               "operation_id" => "cancel-advance-credit",
               "status" => "applied",
               "group_id" => "advance-credit-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }
           ]

    assert get(conn, "/api/v1/guests/guest-22/credit?on=2026-01-06")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 10

    assert get(conn, "/api/v1/ledger?on=2026-01-06")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 10
  end

  test "excludes expired lots and expires paused credit when a refundable group is cancelled late",
       %{conn: conn} do
    submit(conn, [
      open_operation("expiring-source",
        occurred_on: "2026-01-01",
        arrival_on: "2026-03-01",
        departure_on: "2026-03-04"
      )
    ])

    submit(conn, [Map.put(payment_operation("expiring-source", 100), "occurred_on", "2026-01-02")])

    submit(conn, [
      %{
        "operation_id" => "issue-expiring-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "expiring-source",
        "refund_method" => "hotel_credit",
        "expected_revision" => 2
      },
      open_operation("paused-credit-target",
        occurred_on: "2026-01-04",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-04"
      )
    ])

    submit(conn, [
      %{
        "operation_id" => "apply-paused-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-05",
        "group_id" => "paused-credit-target",
        "amount_cents" => 110,
        "expected_revision" => 1
      }
    ])

    assert get(conn, "/api/v1/guests/guest-22/credit?on=2027-01-04") |> json_response(200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    assert get(conn, "/api/v1/ledger?on=2027-01-04")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 110

    rejected =
      submit(conn, [
        %{
          "operation_id" => "stale-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "not-a-date",
          "group_id" => "paused-credit-target",
          "amount_cents" => 1,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "expired-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-04",
          "group_id" => "paused-credit-target",
          "amount_cents" => 1,
          "expected_revision" => 2
        }
      ])

    assert rejected["results"] == [
             %{
               "operation_id" => "stale-credit",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "paused-credit-target",
               "expected_revision" => 1,
               "actual_revision" => 2
             },
             %{
               "operation_id" => "expired-credit",
               "status" => "rejected",
               "code" => "insufficient_credit",
               "group_id" => "paused-credit-target"
             }
           ]

    expired =
      submit(conn, [
        %{
          "operation_id" => "cancel-after-credit-expiry",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "paused-credit-target",
          "expected_revision" => 2
        }
      ])

    assert expired["results"] |> hd() |> Map.take(["status", "refunded_cents", "revision"]) == %{
             "status" => "applied",
             "refunded_cents" => 0,
             "revision" => 3
           }

    assert get(conn, "/api/v1/ledger?on=2027-01-04")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "returns the documented errors for invalid batches and missing groups", %{conn: conn} do
    assert post(conn, "/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert get(conn, "/api/v1/groups/unknown") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "replays an applied operation verbatim without observing later group changes", %{
    conn: conn
  } do
    submit(conn, [open_operation("replay-group")])

    payment = %{
      "operation_id" => "replay-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "replay-group",
      "amount_cents" => 1_000
    }

    original = submit(conn, [payment]) |> get_in(["results", Access.at(0)])

    submit(conn, [
      %{
        "operation_id" => "later-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "replay-group",
        "amount_cents" => 500,
        "expected_revision" => 2
      }
    ])

    reordered_retry = Map.new(Enum.reverse(Map.to_list(payment)))

    assert submit(conn, [reordered_retry])["results"] == [original]

    assert get(conn, "/api/v1/operations/replay-payment") |> json_response(200) == %{
             "data" => original
           }

    assert get(conn, "/api/v1/groups/replay-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 3
  end

  test "remembers a rejection even after later operations would make it valid", %{conn: conn} do
    missing_payment = %{
      "operation_id" => "missing-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "later-group",
      "amount_cents" => 100
    }

    original = submit(conn, [missing_payment]) |> get_in(["results", Access.at(0)])

    submit(conn, [open_operation("later-group")])

    assert submit(conn, [missing_payment])["results"] == [original]

    assert get(conn, "/api/v1/operations/missing-payment") |> json_response(200) == %{
             "data" => original
           }

    assert get(conn, "/api/v1/groups/later-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1
  end

  test "rejects a changed retry without replacing the original operation record", %{conn: conn} do
    operation = open_operation("conflict-group")
    original = submit(conn, [operation]) |> get_in(["results", Access.at(0)])

    changed =
      operation
      |> Map.put("rooms", Enum.reverse(operation["rooms"]))

    assert submit(conn, [changed])["results"] == [
             %{
               "operation_id" => "open-conflict-group",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ]

    assert get(conn, "/api/v1/operations/open-conflict-group") |> json_response(200) == %{
             "data" => original
           }

    group = get(conn, "/api/v1/groups/conflict-group") |> json_response(200) |> Map.fetch!("data")

    assert Map.take(group, ["arrival_on", "departure_on", "revision"]) == %{
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "revision" => 1
           }
  end

  test "preserves stale-revision details and conflicts with a corrected retry", %{conn: conn} do
    submit(conn, [open_operation("stale-group")])

    submit(conn, [
      %{
        "operation_id" => "advance-stale-group",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "stale-group",
        "amount_cents" => 100
      }
    ])

    stale = %{
      "operation_id" => "stale-retry",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "stale-group",
      "amount_cents" => 100,
      "expected_revision" => 1
    }

    original = submit(conn, [stale]) |> get_in(["results", Access.at(0)])

    assert original == %{
             "operation_id" => "stale-retry",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "stale-group",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert submit(conn, [Map.put(stale, "expected_revision", 2)])["results"] == [
             %{
               "operation_id" => "stale-retry",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ]

    assert get(conn, "/api/v1/operations/stale-retry") |> json_response(200) == %{
             "data" => original
           }

    assert get(conn, "/api/v1/groups/stale-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2
  end

  test "persists complete operation audit records in commit order", %{conn: conn} do
    opening = open_operation("audited-group")
    invalid = %{"operation_id" => "audited-invalid", "type" => "unknown_type", "extra" => [2, 1]}

    response = submit(conn, [opening, invalid])

    records = Repo.all(from operation in PartnerOperation, order_by: [asc: operation.id])

    assert Enum.map(records, & &1.operation_id) == ["open-audited-group", "audited-invalid"]
    assert Enum.map(records, & &1.operation_type) == ["open_group", "unknown_type"]
    assert Enum.map(records, & &1.submitted_payload) == [opening, invalid]
    assert Enum.map(records, & &1.result) == response["results"]
  end

  test "concurrent retries have at-most-once effects", _context do
    operation = open_operation("concurrent-group")

    results =
      1..4
      |> Task.async_stream(
        fn _ -> GroupStay.Reservations.process_batch([operation]) end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               "group_id" => "concurrent-group",
               "deposit_due_cents" => 19_500,
               "operation_id" => "open-concurrent-group",
               "revision" => 1,
               "status" => "applied"
             }
           ]

    assert Repo.aggregate(PartnerOperation, :count) == 1

    assert GroupStay.Reservations.fetch_group("concurrent-group").revision == 1
  end

  test "returns operation_not_found for an unknown durable operation", %{conn: conn} do
    assert get(conn, "/api/v1/operations/unknown") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations}) |> json_response(200)
  end

  defp open_operation(group_id, overrides \\ []) do
    %{
      "operation_id" => "open-#{group_id}",
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
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp payment_operation(group_id, amount_cents) do
    %{
      "operation_id" => "payment-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp rooms_for_rounding do
    [
      %{"room_id" => "room-a", "nightly_rate_cents" => 3},
      %{"room_id" => "room-b", "nightly_rate_cents" => 3}
    ]
  end
end
