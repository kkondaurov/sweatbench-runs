defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Ledger.LedgerTotals
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
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

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "opens a group and reads it back with totals and room order", %{conn: conn} do
    response = submit(conn, [open_operation()])

    assert response.status == 200

    assert %{
             "results" => [
               %{"status" => "applied", "deposit_due_cents" => 19_500, "revision" => 1}
             ]
           } =
             json_response(response, 200)

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert group == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "revision" => 1,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15_000,
                   "lodging_total_cents" => 45_000,
                   "status" => "active",
                   "deposit_due_cents" => 9_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17_500,
                   "lodging_total_cents" => 52_500,
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           }
  end

  test "processes operations in order and continues after a rejection", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-bad",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 20_000
      },
      %{
        "operation_id" => "pay-good",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "pay-bad",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "pay-good",
                 "status" => "applied",
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]
           } = submit(conn, operations) |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 5_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "reschedules while preserving stay length and cancels refundable cash", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    operations = [
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 19_500
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      }
    ]

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 2
               },
               %{"status" => "applied", "revision" => 3},
               %{
                 "status" => "applied",
                 "refunded_cents" => 19_500,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } = submit(conn, operations) |> json_response(200)

    assert %{
             "data" => %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           } =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 19_500,
               "cash_retained_cents" => 0
             }
           } =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "cancellation retains late flexible cash and advance purchase cash", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation(%{"group_id" => "late"})]) |> json_response(200)

    late_ops = [
      %{
        "operation_id" => "pay-late",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "late",
        "amount_cents" => 19_500
      },
      %{
        "operation_id" => "cancel-late",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "late"
      }
    ]

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 19_500}
             ]
           } =
             submit(conn, late_ops) |> json_response(200)

    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    assert %{"results" => [%{"deposit_due_cents" => 97_500}]} =
             submit(conn, [advance]) |> json_response(200)

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"refunded_cents" => 0, "retained_cents" => 97_500}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "pay-advance",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "advance",
                 "amount_cents" => 97_500
               },
               %{
                 "operation_id" => "cancel-advance",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "advance"
               }
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 117_000
             }
           } =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "flexible cancellation exactly fourteen days before arrival is refundable", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"refunded_cents" => 19_500, "retained_cents" => 0}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 19_500
               },
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group-81"
               }
             ])
             |> json_response(200)
  end

  test "enforces revisions before other domain validation", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "stale",
                 "type" => "record_cash_payment",
                 "occurred_on" => "not-a-date",
                 "group_id" => "group-81",
                 "amount_cents" => -1,
                 "expected_revision" => 1
               }
             ])
             |> json_response(200)
  end

  test "validates opens without leaving partially created groups", %{conn: conn} do
    invalid_operations = [
      open_operation(%{"operation_id" => "bad-stay", "arrival_on" => "2026-12-13"}),
      open_operation(%{
        "operation_id" => "bad-rooms",
        "group_id" => "bad-rooms",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 1}
        ]
      }),
      open_operation(%{
        "operation_id" => "bad-rate",
        "group_id" => "bad-rate",
        "rate_plan" => "nonrefundable"
      }),
      open_operation(%{
        "operation_id" => "bad-shape",
        "group_id" => "bad-shape",
        "rooms" => ["not-a-room"]
      }),
      open_operation(%{
        "operation_id" => "too-large",
        "group_id" => "too-large",
        "rooms" => [%{"room_id" => "huge", "nightly_rate_cents" => 9_223_372_036_854_775_808}]
      })
    ]

    assert %{"results" => results} = submit(conn, invalid_operations) |> json_response(200)

    assert Enum.map(results, & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan",
             "invalid_rooms",
             "invalid_rooms"
           ]

    assert get(conn, "/api/v1/groups/bad-rooms").status == 404

    assert %{"results" => [%{"status" => "applied"}, %{"code" => "group_already_exists"}]} =
             submit(conn, [open_operation(), open_operation(%{"operation_id" => "duplicate"})])
             |> json_response(200)
  end

  test "enforces payment and inactive-group rules without changing revisions", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    assert %{"results" => [%{"code" => "invalid_amount"}]} =
             submit(conn, [
               %{
                 "operation_id" => "zero",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 0
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2, "outstanding_deposit_cents" => 0}]} =
             submit(conn, [
               %{
                 "operation_id" => "pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 19_500
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 3, "retained_cents" => 19_500}]} =
             submit(conn, [
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "group-81"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"code" => "group_not_active"}, %{"code" => "group_not_active"}]} =
             submit(conn, [
               %{
                 "operation_id" => "pay-after",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-12-02",
                 "group_id" => "group-81",
                 "amount_cents" => 1
               },
               %{
                 "operation_id" => "move-after",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-12-02",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20"
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 0, "cash_retained_cents" => 19_500}} =
             conn |> get("/api/v1/ledger") |> json_response(200)
  end

  test "expected revisions observe earlier operations in the same batch", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    assert %{
             "results" => [
               %{"operation_id" => "pay", "status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "move-stale",
                 "code" => "stale_revision",
                 "actual_revision" => 2
               },
               %{"operation_id" => "cancel", "status" => "applied", "revision" => 3}
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000,
                 "expected_revision" => 1
               },
               %{
                 "operation_id" => "move-stale",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "expected_revision" => 1
               },
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "group-81",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)
  end

  test "rejects a payment that would overflow the aggregate ledger atomically", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    Repo.update_all(LedgerTotals, set: [cash_held_cents: 9_223_372_036_854_775_807])

    assert %{"results" => [%{"code" => "invalid_amount"}]} =
             submit(conn, [
               %{
                 "operation_id" => "overflow",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "rejects invalid batches and reports missing groups", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_json"}} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", "not-json")
             |> json_response(400)

    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", Jason.encode!(%{}))
             |> json_response(422)

    assert %{
             "results" => [
               %{
                 "operation_id" => "missing",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "nope"
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "missing",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "nope"
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{"operation_id" => nil, "code" => "invalid_operation"},
               %{"operation_id" => "unknown", "code" => "invalid_operation"},
               %{"operation_id" => "missing-group", "code" => "invalid_operation"}
             ]
           } =
             submit(conn, [
               1,
               %{"operation_id" => "unknown", "type" => "something_else"},
               %{"operation_id" => "missing-group", "type" => "cancel_group"}
             ])
             |> json_response(200)

    missing_group_response = get(conn, "/api/v1/groups/nope")

    assert missing_group_response.status == 404

    assert %{"error" => %{"code" => "group_not_found"}} =
             json_response(missing_group_response, 404)
  end

  test "pins policy versions at booking and recomputes the refundable date", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "group_id" => "old-policy",
                 "occurred_on" => "2026-12-31",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-13"
               })
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-24"
             }
           } = conn |> get("/api/v1/groups/old-policy") |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "move-old-policy",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "old-policy",
                 "new_arrival_on" => "2027-04-01"
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-19"
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "move-old-policy-again",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "old-policy",
                 "new_arrival_on" => "2027-04-02"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-new-policy",
                 "group_id" => "new-policy",
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-04-01",
                 "departure_on" => "2027-04-04"
               }),
               open_operation(%{
                 "operation_id" => "open-advance-policy",
                 "group_id" => "advance-policy",
                 "occurred_on" => "2027-01-01",
                 "rate_plan" => "advance_purchase"
               })
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-02"
             }
           } = conn |> get("/api/v1/groups/new-policy") |> json_response(200)

    assert %{"data" => %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil}} =
             conn |> get("/api/v1/groups/advance-policy") |> json_response(200)
  end

  test "converts refundable cash to expiring credit with half-up bonus rounding", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation()]) |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "pay-five",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 5
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 6,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "cancel-for-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-81",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "status" => "cancelled"
             }
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-for-credit",
                   "remaining_cents" => 6,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }
           } = conn |> get("/api/v1/guests/guest-22/credit?on=2027-11-01") |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             conn |> get("/api/v1/guests/guest-22/credit?on=2027-11-02") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }
           } = conn |> get("/api/v1/ledger?on=2027-11-01") |> json_response(200)
  end

  test "applies credit in FIFO order and restores it without a second bonus", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation(%{"group_id" => "credit-source"})])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "source-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "credit-source",
                 "amount_cents" => 100
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"credit_issued_cents" => 110}]} =
             submit(conn, [
               %{
                 "operation_id" => "source-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-credit-target",
                 "group_id" => "credit-target"
               })
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "amount_cents" => 60,
                 "outstanding_deposit_cents" => 19_440,
                 "revision" => 2
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "credit-target",
                 "amount_cents" => 60
               }
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 60,
               "deposit_paid_cents" => 60
             }
           } = conn |> get("/api/v1/groups/credit-target") |> json_response(200)

    assert %{"data" => %{"available_cents" => 50}} =
             conn |> get("/api/v1/guests/guest-22/credit?on=2026-11-02") |> json_response(200)

    assert %{
             "results" => [
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             submit(conn, [
               %{
                 "operation_id" => "target-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-03",
                 "group_id" => "credit-target"
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"available_cents" => 110}} =
             conn |> get("/api/v1/guests/guest-22/credit?on=2026-11-03") |> json_response(200)
  end

  test "rejects hotel credit for non-refundable cancellation and consumes applied credit", %{
    conn: conn
  } do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation(%{"group_id" => "credit-source"})])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "source-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "credit-source",
                 "amount_cents" => 100
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"credit_issued_cents" => 110}]} =
             submit(conn, [
               %{
                 "operation_id" => "source-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-advance-target",
                 "group_id" => "advance-target",
                 "rate_plan" => "advance_purchase"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "advance-target",
                 "amount_cents" => 60
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"code" => "refund_method_not_available"}]} =
             submit(conn, [
               %{
                 "operation_id" => "bad-credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-03",
                 "group_id" => "advance-target",
                 "refund_method" => "hotel_credit",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"status" => "active", "revision" => 2}} =
             conn |> get("/api/v1/groups/advance-target") |> json_response(200)

    assert %{"results" => [%{"retained_cents" => 0, "credit_issued_cents" => 0, "revision" => 3}]} =
             submit(conn, [
               %{
                 "operation_id" => "advance-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-03",
                 "group_id" => "advance-target"
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"available_cents" => 50}} =
             conn |> get("/api/v1/guests/guest-22/credit?on=2026-11-03") |> json_response(200)
  end

  test "allocates equal-expiry lots by source operation id", %{conn: conn} do
    for {group_id, payment_id, cancellation_id} <- [
          {"source-z", "pay-z", "z-source"},
          {"source-a", "pay-a", "a-source"}
        ] do
      assert %{"results" => [%{"status" => "applied"}]} =
               submit(conn, [
                 open_operation(%{
                   "operation_id" => "open-#{group_id}",
                   "group_id" => group_id
                 })
               ])
               |> json_response(200)

      assert %{"results" => [%{"status" => "applied"}]} =
               submit(conn, [
                 %{
                   "operation_id" => payment_id,
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => group_id,
                   "amount_cents" => 100
                 }
               ])
               |> json_response(200)

      assert %{"results" => [%{"credit_issued_cents" => 110}]} =
               submit(conn, [
                 %{
                   "operation_id" => cancellation_id,
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-01",
                   "group_id" => group_id,
                   "refund_method" => "hotel_credit"
                 }
               ])
               |> json_response(200)
    end

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-fifo-target",
                 "group_id" => "fifo-target"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "amount_cents" => 110}]} =
             submit(conn, [
               %{
                 "operation_id" => "fifo-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "fifo-target",
                 "amount_cents" => 110
               }
             ])
             |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "z-source",
                   "remaining_cents" => 110
                 }
               ]
             }
           } = conn |> get("/api/v1/guests/guest-22/credit?on=2026-11-02") |> json_response(200)
  end

  test "rejects insufficient credit atomically", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [open_operation(%{"group_id" => "credit-source"})])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "source-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "credit-source",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "source-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-credit-target",
                 "group_id" => "credit-target"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"code" => "insufficient_credit"}]} =
             submit(conn, [
               %{
                 "operation_id" => "too-much-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "credit-target",
                 "amount_cents" => 111
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
             conn |> get("/api/v1/groups/credit-target") |> json_response(200)

    assert %{"data" => %{"available_cents" => 110}} =
             conn |> get("/api/v1/guests/guest-22/credit?on=2026-11-02") |> json_response(200)
  end

  test "drops applied credit that has expired when a refundable group is cancelled", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "group_id" => "old-credit-source",
                 "occurred_on" => "2025-12-01"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "old-credit-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2025-12-02",
                 "group_id" => "old-credit-source",
                 "amount_cents" => 100
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"credit_issued_cents" => 110}]} =
             submit(conn, [
               %{
                 "operation_id" => "old-credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-01-01",
                 "group_id" => "old-credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               open_operation(%{
                 "operation_id" => "open-expired-credit-target",
                 "group_id" => "expired-credit-target",
                 "occurred_on" => "2026-01-02",
                 "arrival_on" => "2028-01-01",
                 "departure_on" => "2028-01-04"
               })
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             submit(conn, [
               %{
                 "operation_id" => "apply-old-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-01-02",
                 "group_id" => "expired-credit-target",
                 "amount_cents" => 110
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"credit_issued_cents" => 0, "refunded_cents" => 0}]} =
             submit(conn, [
               %{
                 "operation_id" => "expire-on-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-03",
                 "group_id" => "expired-credit-target"
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"available_cents" => 0}} =
             conn |> get("/api/v1/guests/guest-22/credit?on=2027-01-03") |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             conn |> get("/api/v1/ledger?on=2027-01-03") |> json_response(200)
  end

  test "replays an applied operation without changing current state", %{conn: conn} do
    operation = open_operation(%{"operation_id" => "durable-open"})

    first = submit(conn, [operation]) |> json_response(200)
    second = submit(conn, [operation]) |> json_response(200)

    assert second == first

    assert %{"data" => %{"revision" => 1, "status" => "active"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 0}} =
             conn |> get("/api/v1/ledger") |> json_response(200)

    first_result = List.first(first["results"])

    assert %{"data" => ^first_result} =
             conn |> get("/api/v1/operations/durable-open") |> json_response(200)
  end

  test "handles a duplicate operation ID in one batch exactly once", %{conn: conn} do
    operation = open_operation(%{"operation_id" => "duplicate-in-batch"})

    assert %{"results" => [first, second]} =
             submit(conn, [operation, operation]) |> json_response(200)

    assert second == first

    assert %{"data" => %{"revision" => 1, "status" => "active"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "remembers rejections and conflicts corrected payloads", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}]} =
             submit(conn, [open_operation(%{"operation_id" => "durable-target"})])
             |> json_response(200)

    stale_operation = %{
      "operation_id" => "durable-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "not-a-date",
      "group_id" => "group-81",
      "amount_cents" => -1,
      "expected_revision" => 0
    }

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "actual_revision" => 1,
                 "expected_revision" => 0
               }
             ]
           } = submit(conn, [stale_operation]) |> json_response(200)

    assert %{"results" => [%{"revision" => 2}]} =
             submit(conn, [
               %{
                 "operation_id" => "durable-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1
               }
             ])
             |> json_response(200)

    replayed = submit(conn, [stale_operation]) |> json_response(200)

    assert %{
             "results" => [
               %{
                 "code" => "stale_revision",
                 "actual_revision" => 1,
                 "expected_revision" => 0
               }
             ]
           } = replayed

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             submit(conn, [Map.put(stale_operation, "expected_revision", 2)])
             |> json_response(200)

    replayed_result = List.first(replayed["results"])

    assert %{"data" => ^replayed_result} =
             conn |> get("/api/v1/operations/durable-stale") |> json_response(200)
  end

  test "treats reordered JSON objects as equivalent but preserves array order", %{conn: conn} do
    first_payload =
      ~s({"operations":[{"operation_id":"json-order","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-a","nightly_rate_cents":15000},{"room_id":"room-b","nightly_rate_cents":17500}]}]})

    reordered_payload =
      ~s({"operations":[{"rooms":[{"nightly_rate_cents":15000,"room_id":"room-a"},{"nightly_rate_cents":17500,"room_id":"room-b"}],"rate_plan":"flexible","departure_on":"2026-12-13","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"group-81","occurred_on":"2026-10-03","type":"open_group","operation_id":"json-order"}]})

    first =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", first_payload)
      |> json_response(200)

    second =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", reordered_payload)
      |> json_response(200)

    assert second == first

    array_reordered_payload =
      ~s({"operations":[{"operation_id":"json-order","type":"open_group","occurred_on":"2026-10-03","group_id":"group-81","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-13","rate_plan":"flexible","rooms":[{"room_id":"room-b","nightly_rate_cents":17500},{"room_id":"room-a","nightly_rate_cents":15000}]}]})

    assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", array_reordered_payload)
             |> json_response(200)
  end

  test "retains rejected operation content and commit order", %{conn: conn} do
    invalid = %{
      "operation_id" => "audit-rejection",
      "type" => "unknown_type",
      "nested" => %{"b" => 2, "a" => ["first", "second"]}
    }

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [invalid]) |> json_response(200)

    second_invalid = Map.put(invalid, "operation_id", "audit-second-rejection")

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [second_invalid]) |> json_response(200)

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [invalid]) |> json_response(200)

    assert %{"error" => %{"code" => "operation_not_found"}} =
             conn |> get("/api/v1/operations/does-not-exist") |> json_response(404)

    records = Repo.all(Operation) |> Enum.sort_by(& &1.id)

    assert [
             %Operation{operation_id: "audit-rejection", type: "unknown_type"},
             %Operation{operation_id: "audit-second-rejection", type: "unknown_type"}
           ] = records

    record = Enum.at(records, 0)
    assert Jason.decode!(record.payload_json) == invalid
    assert Jason.decode!(record.result_json)["code"] == "invalid_operation"
  end

  test "records cancellation preflight failures without partial settlement", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}, %{"revision" => 2}]} =
             submit(conn, [
               open_operation(%{"operation_id" => "open-preflight"}),
               %{
                 "operation_id" => "pay-preflight",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1
               }
             ])
             |> json_response(200)

    Repo.update_all(LedgerTotals, set: [cash_held_cents: 0])

    cancellation = %{
      "operation_id" => "cancel-preflight",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-01",
      "group_id" => "group-81"
    }

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [cancellation]) |> json_response(200)

    Repo.update_all(LedgerTotals, set: [cash_held_cents: 1])

    assert %{"results" => [%{"code" => "invalid_operation"}]} =
             submit(conn, [cancellation]) |> json_response(200)

    assert %{"data" => %{"revision" => 2, "status" => "active"}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end
end
