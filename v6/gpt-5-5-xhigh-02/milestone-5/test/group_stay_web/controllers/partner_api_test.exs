defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.PartnerOperation

  test "rejects an invalid batch body", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/partner-batches", %{"not_operations" => []})

    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
  end

  test "opens a group and exposes it through the group and ledger read endpoints", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [open_group_operation()]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/groups/group-81")

    assert json_response(conn, 200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "active",
                   "nightly_rate_cents" => 15_000,
                   "lodging_amount_cents" => 45_000,
                   "deposit_due_cents" => 9_000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "nightly_rate_cents" => 17_500,
                   "lodging_amount_cents" => 52_500,
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

    conn = get(build_conn(), ~p"/api/v1/ledger")

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

  test "processes batch operations in order and keeps rejected operations isolated", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(),
          %{
            "operation_id" => "op-overpay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 20_000
          },
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "amount_cents" => 10_000
          },
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-07",
            "group_id" => "group-81",
            "expected_revision" => 2,
            "new_arrival_on" => "2026-12-12"
          },
          %{
            "operation_id" => "op-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-01",
            "group_id" => "group-81",
            "expected_revision" => 3
          },
          %{
            "operation_id" => "op-late-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-12-02",
            "group_id" => "group-81",
            "amount_cents" => 1
          }
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-overpay",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-12",
                 "new_departure_on" => "2026-12-15",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-28",
                 "revision" => 3
               },
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 0,
                 "retained_cents" => 10_000,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               },
               %{
                 "operation_id" => "op-late-pay",
                 "status" => "rejected",
                 "code" => "group_not_active"
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/groups/group-81")

    assert %{
             "data" => %{
               "arrival_on" => "2026-12-12",
               "departure_on" => "2026-12-15",
               "status" => "cancelled",
               "revision" => 4,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 10_000,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "replays applied operations exactly without changing current domain state", %{conn: conn} do
    payment =
      payment_operation("replay-pay", "group-81", 1_000)
      |> Map.put("expected_revision", 1)

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [open_group_operation(), payment]
      })

    assert %{
             "results" => [
               %{"operation_id" => "op-open", "revision" => 1},
               %{
                 "operation_id" => "replay-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               }
             ]
           } = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          cancel_operation("replay-cancel", "group-81", "2026-12-01", %{
            "expected_revision" => 2
          })
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "replay-cancel", "revision" => 3}
             ]
           } = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [payment]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "replay-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/groups/group-81")

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 3,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_retained_cents" => 1_000
             }
           } = json_response(conn, 200)
  end

  test "remembers rejected results and exposes them through the operation endpoint", %{conn: conn} do
    stale_payment = %{
      "operation_id" => "remember-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "expected_revision" => 9,
      "amount_cents" => 1_000
    }

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(),
          stale_payment,
          payment_operation("advance-revision", "group-81", 1_000, "2026-10-06")
        ]
      })

    stale_result = %{
      "operation_id" => "remember-stale",
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => "group-81",
      "expected_revision" => 9,
      "actual_revision" => 1
    }

    assert %{
             "results" => [
               %{"operation_id" => "op-open", "revision" => 1},
               ^stale_result,
               %{"operation_id" => "advance-revision", "revision" => 2}
             ]
           } = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [stale_payment]
      })

    assert json_response(conn, 200) == %{"results" => [stale_result]}

    conn = get(build_conn(), ~p"/api/v1/operations/remember-stale")

    assert json_response(conn, 200) == %{"data" => stale_result}
  end

  test "rejects operation id conflicts without replacing the original record", %{conn: conn} do
    original =
      open_group_operation(%{
        "operation_id" => "conflict-open",
        "group_id" => "conflict-group",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [original]
      })

    original_result = %{
      "operation_id" => "conflict-open",
      "status" => "applied",
      "group_id" => "conflict-group",
      "deposit_due_cents" => 19_500,
      "revision" => 1
    }

    assert json_response(conn, 200) == %{"results" => [original_result]}

    conflicting =
      original
      |> Map.put("rooms", Enum.reverse(original["rooms"]))

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [conflicting]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "conflict-open",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/operations/conflict-open")

    assert json_response(conn, 200) == %{"data" => original_result}
  end

  test "treats JSON object key order as equivalent for retries", %{conn: conn} do
    first_payload = """
    {
      "operations": [
        {
          "operation_id": "json-order-open",
          "type": "open_group",
          "occurred_on": "2026-10-03",
          "group_id": "json-order",
          "guest_id": "guest-json",
          "property_id": "ams-canal",
          "arrival_on": "2026-12-10",
          "departure_on": "2026-12-11",
          "rate_plan": "flexible",
          "rooms": [
            {"room_id": "room-a", "nightly_rate_cents": 15000}
          ]
        }
      ]
    }
    """

    retry_payload = """
    {
      "operations": [
        {
          "rooms": [
            {"nightly_rate_cents": 15000, "room_id": "room-a"}
          ],
          "rate_plan": "flexible",
          "departure_on": "2026-12-11",
          "arrival_on": "2026-12-10",
          "property_id": "ams-canal",
          "guest_id": "guest-json",
          "group_id": "json-order",
          "occurred_on": "2026-10-03",
          "type": "open_group",
          "operation_id": "json-order-open"
        }
      ]
    }
    """

    expected_result = %{
      "operation_id" => "json-order-open",
      "status" => "applied",
      "group_id" => "json-order",
      "deposit_due_cents" => 3_000,
      "revision" => 1
    }

    conn = post_partner_json(conn, first_payload)

    assert json_response(conn, 200) == %{"results" => [expected_result]}

    conn = post_partner_json(build_conn(), retry_payload)

    assert json_response(conn, 200) == %{"results" => [expected_result]}
  end

  test "retains submitted content, operation type, and first commit order", %{conn: conn} do
    rejected_operation = %{
      "operation_id" => "audit-reject",
      "type" => "hold_room",
      "occurred_on" => "2026-10-01",
      "details" => %{"nested" => ["value", %{"count" => 2}]}
    }

    applied_operation =
      open_group_operation(%{
        "operation_id" => "audit-open",
        "group_id" => "audit-group"
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [rejected_operation, applied_operation]
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "audit-reject",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "audit-open", "status" => "applied"}
             ]
           } = json_response(conn, 200)

    records =
      PartnerOperation
      |> order_by([operation], asc: operation.id)
      |> Repo.all()

    assert Enum.map(records, & &1.operation_id) == ["audit-reject", "audit-open"]

    assert [
             %PartnerOperation{
               operation_type: "hold_room",
               payload: ^rejected_operation,
               result: %{
                 "operation_id" => "audit-reject",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
             },
             %PartnerOperation{
               operation_type: "open_group",
               payload: ^applied_operation,
               result: %{
                 "operation_id" => "audit-open",
                 "status" => "applied",
                 "group_id" => "audit-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             }
           ] = records
  end

  test "rounds flexible deposits per room before summing", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 3},
              %{"room_id" => "room-b", "nightly_rate_cents" => 3}
            ]
          })
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 2,
                 "revision" => 1
               }
             ]
           }
  end

  test "rejects stale revisions before domain validation and leaves state unchanged", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(),
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "expected_revision" => 9,
            "amount_cents" => 10_000
          },
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "expected_revision" => 1,
            "amount_cents" => 1_000
          }
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               }
             ]
           }
  end

  test "applies flexible cancellation refund and advance-purchase retention rules", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{"group_id" => "flex", "operation_id" => "open-flex"}),
          payment_operation("pay-flex", "flex", 5_000),
          %{
            "operation_id" => "cancel-flex",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "flex"
          },
          open_group_operation(%{
            "operation_id" => "open-advance",
            "group_id" => "advance",
            "rate_plan" => "advance_purchase"
          }),
          payment_operation("pay-advance", "advance", 97_500),
          %{
            "operation_id" => "cancel-advance",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "advance"
          }
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-flex", "deposit_due_cents" => 19_500, "revision" => 1},
               %{"operation_id" => "pay-flex", "revision" => 2},
               %{
                 "operation_id" => "cancel-flex",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 3
               },
               %{
                 "operation_id" => "open-advance",
                 "deposit_due_cents" => 97_500,
                 "revision" => 1
               },
               %{"operation_id" => "pay-advance", "revision" => 2},
               %{
                 "operation_id" => "cancel-advance",
                 "refunded_cents" => 0,
                 "retained_cents" => 97_500,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 97_500,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "assigns policy versions and preserves them when rescheduling", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{
            "operation_id" => "open-old",
            "group_id" => "old-flex",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-03"
          }),
          open_group_operation(%{
            "operation_id" => "open-new",
            "group_id" => "new-flex",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-03"
          }),
          open_group_operation(%{
            "operation_id" => "open-advance",
            "group_id" => "advance-policy",
            "occurred_on" => "2027-01-10",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-03",
            "rate_plan" => "advance_purchase"
          }),
          %{
            "operation_id" => "move-new",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-02",
            "group_id" => "new-flex",
            "expected_revision" => 1,
            "new_arrival_on" => "2027-03-01"
          }
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-old", "revision" => 1},
               %{"operation_id" => "open-new", "revision" => 1},
               %{"operation_id" => "open-advance", "revision" => 1},
               %{
                 "operation_id" => "move-new",
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-01-30",
                 "revision" => 2
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/old-flex")

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-18"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/new-flex")

    assert %{
             "data" => %{
               "arrival_on" => "2027-03-01",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-01-30"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/advance-policy")

    assert %{
             "data" => %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
           } = json_response(conn, 200)
  end

  test "issues hotel credit for refundable cancellations and reports date-scoped expiry", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{
            "operation_id" => "open-credit-source",
            "group_id" => "credit-source",
            "occurred_on" => "2027-01-02",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-13"
          }),
          payment_operation("pay-credit-source", "credit-source", 5_000, "2027-01-03"),
          cancel_operation("cancel-credit-source", "credit-source", "2027-02-08", %{
            "expected_revision" => 2,
            "refund_method" => "hotel_credit"
          })
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-credit-source", "revision" => 1},
               %{"operation_id" => "pay-credit-source", "revision" => 2},
               %{
                 "operation_id" => "cancel-credit-source",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 5_500,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-02-07"})

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-02-08"})

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-credit-source",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2028-02-08"
                 }
               ]
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2027-02-08"})

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 5_500,
               "credit_shortfall_cents" => 0
             }
           }

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2028-02-09"})

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2028-02-09"})

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "applies credit by expiry order and restores unexpired lots on refundable cancellation", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_credit_source_operation("later-source", "open-later", "2027-04-10"),
          payment_operation("pay-later", "later-source", 2_000, "2027-01-03"),
          cancel_operation("cancel-later", "later-source", "2027-02-10", %{
            "expected_revision" => 2,
            "refund_method" => "hotel_credit"
          }),
          open_credit_source_operation("earlier-source", "open-earlier", "2027-04-10"),
          payment_operation("pay-earlier", "earlier-source", 3_000, "2027-01-03"),
          cancel_operation("cancel-earlier", "earlier-source", "2027-02-01", %{
            "expected_revision" => 2,
            "refund_method" => "hotel_credit"
          }),
          open_group_operation(%{
            "operation_id" => "open-target",
            "group_id" => "credit-target",
            "occurred_on" => "2027-03-01",
            "arrival_on" => "2027-05-01",
            "departure_on" => "2027-05-04"
          }),
          %{
            "operation_id" => "apply-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-03-01",
            "group_id" => "credit-target",
            "expected_revision" => 1,
            "amount_cents" => 4_000
          }
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-later", "revision" => 1},
               %{"operation_id" => "pay-later", "revision" => 2},
               %{"operation_id" => "cancel-later", "credit_issued_cents" => 2_200},
               %{"operation_id" => "open-earlier", "revision" => 1},
               %{"operation_id" => "pay-earlier", "revision" => 2},
               %{"operation_id" => "cancel-earlier", "credit_issued_cents" => 3_300},
               %{"operation_id" => "open-target", "revision" => 1},
               %{
                 "operation_id" => "apply-credit",
                 "amount_cents" => 4_000,
                 "outstanding_deposit_cents" => 15_500,
                 "revision" => 2
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/credit-target")

    assert %{
             "data" => %{
               "deposit_paid_cents" => 4_000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 4_000,
               "outstanding_deposit_cents" => 15_500
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-03-01"})

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 1_500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-later",
                   "remaining_cents" => 1_500,
                   "expires_on" => "2028-02-10"
                 }
               ]
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2027-03-01"})

    assert %{"data" => %{"credit_liability_cents" => 5_500}} = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          cancel_operation("cancel-target", "credit-target", "2027-03-15", %{
            "expected_revision" => 2
          })
        ]
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "cancel-target",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-03-15"})

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-earlier",
                   "remaining_cents" => 3_300,
                   "expires_on" => "2028-02-01"
                 },
                 %{
                   "source_operation_id" => "cancel-later",
                   "remaining_cents" => 2_200,
                   "expires_on" => "2028-02-10"
                 }
               ]
             }
           }
  end

  test "expires applied credit instead of restoring it after the original lot expiry", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_credit_source_operation("expiring-source", "open-expiring", "2027-04-10"),
          payment_operation("pay-expiring", "expiring-source", 1_000, "2027-01-03"),
          cancel_operation("cancel-expiring", "expiring-source", "2027-02-01", %{
            "expected_revision" => 2,
            "refund_method" => "hotel_credit"
          }),
          open_group_operation(%{
            "operation_id" => "open-future",
            "group_id" => "future-target",
            "occurred_on" => "2027-03-01",
            "arrival_on" => "2028-04-01",
            "departure_on" => "2028-04-04"
          }),
          %{
            "operation_id" => "apply-expiring",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-03-01",
            "group_id" => "future-target",
            "expected_revision" => 1,
            "amount_cents" => 1_100
          }
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-expiring", "revision" => 1},
               %{"operation_id" => "pay-expiring", "revision" => 2},
               %{"operation_id" => "cancel-expiring", "credit_issued_cents" => 1_100},
               %{"operation_id" => "open-future", "revision" => 1},
               %{"operation_id" => "apply-expiring", "revision" => 2}
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2028-02-02"})

    assert %{"data" => %{"credit_liability_cents" => 1_100}} = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          cancel_operation("cancel-future", "future-target", "2028-02-02", %{
            "expected_revision" => 2
          })
        ]
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "cancel-future",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2028-02-02"})

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2028-02-02"})

    assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
  end

  test "rejects unavailable credit and refund methods without advancing revision", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{"group_id" => "reject-group"}),
          payment_operation("pay-reject", "reject-group", 1_000),
          %{
            "operation_id" => "stale-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "reject-group",
            "expected_revision" => 9,
            "amount_cents" => 1
          },
          %{
            "operation_id" => "missing-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "reject-group",
            "expected_revision" => 2,
            "amount_cents" => 1
          },
          cancel_operation("bad-method", "reject-group", "2026-12-01", %{
            "expected_revision" => 2,
            "refund_method" => "hotel_credit"
          }),
          cancel_operation("cash-cancel", "reject-group", "2026-12-01", %{
            "expected_revision" => 2
          })
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "reject-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-reject",
                 "status" => "applied",
                 "group_id" => "reject-group",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "stale-credit",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "reject-group",
                 "expected_revision" => 9,
                 "actual_revision" => 2
               },
               %{
                 "operation_id" => "missing-credit",
                 "status" => "rejected",
                 "code" => "insufficient_credit"
               },
               %{
                 "operation_id" => "bad-method",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               },
               %{
                 "operation_id" => "cash-cancel",
                 "status" => "applied",
                 "group_id" => "reject-group",
                 "refunded_cents" => 0,
                 "retained_cents" => 1_000,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           }
  end

  test "allocates funding to rooms and cancels selected rooms in original order", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_three_room_operation(),
          payment_operation("room-pay-one", "room-accounting", 5_000),
          payment_operation("room-pay-two", "room-accounting", 5_000, "2026-10-06"),
          cancel_rooms_operation("cancel-some-rooms", "room-accounting", ["room-c", "room-a"], %{
            "occurred_on" => "2026-11-26",
            "expected_revision" => 3
          })
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "open-three",
                 "status" => "applied",
                 "group_id" => "room-accounting",
                 "deposit_due_cents" => 12_000,
                 "revision" => 1
               },
               %{
                 "operation_id" => "room-pay-one",
                 "status" => "applied",
                 "group_id" => "room-accounting",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 7_000,
                 "revision" => 2
               },
               %{
                 "operation_id" => "room-pay-two",
                 "status" => "applied",
                 "group_id" => "room-accounting",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 2_000,
                 "revision" => 3
               },
               %{
                 "operation_id" => "cancel-some-rooms",
                 "status" => "applied",
                 "group_id" => "room-accounting",
                 "cancelled_room_ids" => ["room-a", "room-c"],
                 "refunded_cents" => 6_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/groups/room-accounting")

    assert %{
             "data" => %{
               "status" => "active",
               "revision" => 4,
               "lodging_total_cents" => 20_000,
               "deposit_due_cents" => 4_000,
               "deposit_paid_cents" => 4_000,
               "cash_paid_cents" => 4_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "cancelled",
                   "deposit_due_cents" => 2_000,
                   "cash_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "deposit_due_cents" => 4_000,
                   "cash_paid_cents" => 4_000
                 },
                 %{
                   "room_id" => "room-c",
                   "status" => "cancelled",
                   "deposit_due_cents" => 6_000,
                   "cash_paid_cents" => 0
                 }
               ]
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/room-pay-one")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "room-pay-one",
               "original_group_id" => "room-accounting",
               "recorded_cents" => 5_000,
               "held_cents" => 3_000,
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }

    conn = get(build_conn(), ~p"/api/v1/payments/room-pay-two")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "room-pay-two",
               "original_group_id" => "room-accounting",
               "recorded_cents" => 5_000,
               "held_cents" => 1_000,
               "refunded_cents" => 4_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 4_000,
               "cash_refunded_cents" => 6_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0
             }
           } = json_response(conn, 200)
  end

  test "reduces a recorded cash payment in reverse fill order and replays exactly", %{conn: conn} do
    reduction =
      reduce_cash_payment_operation("reduce-room-pay", "room-pay-one", 3_500, %{
        "expected_revision" => 3
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_three_room_operation(),
          payment_operation("room-pay-one", "room-accounting", 9_000),
          payment_operation("room-pay-two", "room-accounting", 3_000, "2026-10-06"),
          reduction
        ]
      })

    reduction_result = %{
      "operation_id" => "reduce-room-pay",
      "status" => "applied",
      "payment_operation_id" => "room-pay-one",
      "group_id" => "room-accounting",
      "amount_cents" => 3_500,
      "outstanding_deposit_cents" => 3_500,
      "revision" => 4
    }

    assert %{
             "results" => [
               %{"operation_id" => "open-three", "revision" => 1},
               %{"operation_id" => "room-pay-one", "revision" => 2},
               %{"operation_id" => "room-pay-two", "revision" => 3},
               ^reduction_result
             ]
           } = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [reduction]
      })

    assert json_response(conn, 200) == %{"results" => [reduction_result]}

    conn = get(build_conn(), ~p"/api/v1/groups/room-accounting")

    assert %{
             "data" => %{
               "revision" => 4,
               "deposit_paid_cents" => 8_500,
               "cash_paid_cents" => 8_500,
               "outstanding_deposit_cents" => 3_500,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                 %{"room_id" => "room-b", "cash_paid_cents" => 3_500},
                 %{"room_id" => "room-c", "cash_paid_cents" => 3_000}
               ]
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/room-pay-one")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "room-pay-one",
               "original_group_id" => "room-accounting",
               "recorded_cents" => 9_000,
               "held_cents" => 5_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3_500,
               "charged_back_cents" => 0
             }
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          reduce_cash_payment_operation("reduce-too-much", "room-pay-one", 6_000, %{
            "expected_revision" => 4
          })
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "reduce-too-much",
                 "status" => "rejected",
                 "code" => "reduction_exceeds_held_cash"
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 8_500,
               "cash_reduced_cents" => 3_500,
               "cash_charged_back_cents" => 0
             }
           } = json_response(conn, 200)
  end

  test "charges back held and retained cash from a payment", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(),
          payment_operation("charge-pay-one", "group-81", 10_000),
          payment_operation("charge-pay-two", "group-81", 9_500, "2026-10-06"),
          cancel_rooms_operation("retain-room-a", "group-81", ["room-a"], %{
            "occurred_on" => "2026-12-01",
            "expected_revision" => 3
          }),
          charge_back_payment_operation("charge-pay-one-back", "charge-pay-one", %{
            "expected_revision" => 4
          })
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "op-open", "revision" => 1},
               %{"operation_id" => "charge-pay-one", "revision" => 2},
               %{"operation_id" => "charge-pay-two", "revision" => 3},
               %{
                 "operation_id" => "retain-room-a",
                 "retained_cents" => 9_000,
                 "revision" => 4
               },
               %{
                 "operation_id" => "charge-pay-one-back",
                 "status" => "applied",
                 "payment_operation_id" => "charge-pay-one",
                 "group_id" => "group-81",
                 "charged_back_cents" => 10_000,
                 "outstanding_deposit_cents" => 1_000,
                 "revision" => 5
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/charge-pay-one")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "charge-pay-one",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 10_000
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 9_500,
               "cash_retained_cents" => 0,
               "cash_charged_back_cents" => 10_000
             }
           } = json_response(conn, 200)
  end

  test "chargeback of converted cash creates credit shortfall and restored credit absorbs it", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{
            "operation_id" => "open-source",
            "group_id" => "source",
            "occurred_on" => "2027-01-02",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-13"
          }),
          payment_operation("source-pay", "source", 5_000, "2027-01-03"),
          cancel_operation("source-cancel", "source", "2027-02-08", %{
            "expected_revision" => 2,
            "refund_method" => "hotel_credit"
          }),
          open_group_operation(%{
            "operation_id" => "open-target-for-shortfall",
            "group_id" => "shortfall-target",
            "occurred_on" => "2027-03-01",
            "arrival_on" => "2027-05-01",
            "departure_on" => "2027-05-04"
          }),
          %{
            "operation_id" => "apply-shortfall-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-03-01",
            "group_id" => "shortfall-target",
            "expected_revision" => 1,
            "amount_cents" => 5_500
          },
          charge_back_payment_operation("charge-converted", "source-pay", %{
            "expected_revision" => 3
          })
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-source", "revision" => 1},
               %{"operation_id" => "source-pay", "revision" => 2},
               %{
                 "operation_id" => "source-cancel",
                 "credit_issued_cents" => 5_500,
                 "revision" => 3
               },
               %{"operation_id" => "open-target-for-shortfall", "revision" => 1},
               %{"operation_id" => "apply-shortfall-credit", "revision" => 2},
               %{
                 "operation_id" => "charge-converted",
                 "status" => "applied",
                 "payment_operation_id" => "source-pay",
                 "group_id" => "source",
                 "charged_back_cents" => 5_000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2027-03-01"})

    assert %{
             "data" => %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 5_000,
               "credit_liability_cents" => 5_500,
               "credit_shortfall_cents" => 5_500
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-03-01"})

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          cancel_operation("cancel-shortfall-target", "shortfall-target", "2027-03-15", %{
            "expected_revision" => 2
          })
        ]
      })

    assert %{
             "results" => [
               %{
                 "operation_id" => "cancel-shortfall-target",
                 "status" => "applied",
                 "group_id" => "shortfall-target",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2027-03-15"})

    assert %{
             "data" => %{
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-03-15"})

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }
  end

  test "transfers held cash and hotel credit between active groups and settles them later", %{
    conn: conn
  } do
    transfer =
      transfer_deposit_operation(
        "move-mixed-deposit",
        "transfer-source",
        "transfer-dest",
        5_300,
        %{
          "expected_revision" => 3,
          "destination_expected_revision" => 1
        }
      )

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_credit_source_operation(
            "transfer-credit-origin",
            "open-transfer-credit",
            "2027-04-10"
          ),
          payment_operation(
            "pay-transfer-credit-origin",
            "transfer-credit-origin",
            3_000,
            "2027-01-03"
          ),
          cancel_operation(
            "cancel-transfer-credit-origin",
            "transfer-credit-origin",
            "2027-02-10",
            %{
              "expected_revision" => 2,
              "refund_method" => "hotel_credit"
            }
          ),
          open_three_room_operation(%{
            "operation_id" => "open-transfer-source",
            "group_id" => "transfer-source",
            "occurred_on" => "2027-03-01",
            "arrival_on" => "2027-05-01",
            "departure_on" => "2027-05-02"
          }),
          payment_operation("pay-transfer-cash", "transfer-source", 5_000, "2027-03-02"),
          %{
            "operation_id" => "apply-transfer-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2027-03-03",
            "group_id" => "transfer-source",
            "expected_revision" => 2,
            "amount_cents" => 3_300
          },
          open_three_room_operation(%{
            "operation_id" => "open-transfer-dest",
            "group_id" => "transfer-dest",
            "occurred_on" => "2027-03-01",
            "arrival_on" => "2027-05-01",
            "departure_on" => "2027-05-02"
          }),
          transfer
        ]
      })

    transfer_result = %{
      "operation_id" => "move-mixed-deposit",
      "status" => "applied",
      "source_group_id" => "transfer-source",
      "destination_group_id" => "transfer-dest",
      "amount_cents" => 5_300,
      "source_outstanding_deposit_cents" => 9_000,
      "destination_outstanding_deposit_cents" => 6_700,
      "source_revision" => 4,
      "destination_revision" => 2
    }

    assert %{
             "results" => [
               %{"operation_id" => "open-transfer-credit", "revision" => 1},
               %{"operation_id" => "pay-transfer-credit-origin", "revision" => 2},
               %{
                 "operation_id" => "cancel-transfer-credit-origin",
                 "credit_issued_cents" => 3_300
               },
               %{"operation_id" => "open-transfer-source", "revision" => 1},
               %{"operation_id" => "pay-transfer-cash", "revision" => 2},
               %{
                 "operation_id" => "apply-transfer-credit",
                 "outstanding_deposit_cents" => 3_700,
                 "revision" => 3
               },
               %{"operation_id" => "open-transfer-dest", "revision" => 1},
               ^transfer_result
             ]
           } = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [transfer]
      })

    assert json_response(conn, 200) == %{"results" => [transfer_result]}

    conn = get(build_conn(), ~p"/api/v1/groups/transfer-source")

    assert %{
             "data" => %{
               "revision" => 4,
               "deposit_paid_cents" => 3_000,
               "cash_paid_cents" => 3_000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 9_000
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/transfer-dest")

    assert %{
             "data" => %{
               "revision" => 2,
               "deposit_paid_cents" => 5_300,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 3_300,
               "outstanding_deposit_cents" => 6_700
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/pay-transfer-cash")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-transfer-cash",
               "original_group_id" => "transfer-source",
               "recorded_cents" => 5_000,
               "held_cents" => 5_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "transfer-dest", "amount_cents" => 2_000},
                 %{"group_id" => "transfer-source", "amount_cents" => 3_000}
               ]
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger", %{"on" => "2027-03-03"})

    assert %{
             "data" => %{
               "cash_held_cents" => 5_000,
               "cash_converted_to_credit_cents" => 3_000,
               "credit_liability_cents" => 3_300
             }
           } = json_response(conn, 200)

    conn =
      post(build_conn(), ~p"/api/v1/partner-batches", %{
        "operations" => [
          cancel_operation("cancel-transfer-dest", "transfer-dest", "2027-03-15", %{
            "expected_revision" => 2
          })
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "cancel-transfer-dest",
                 "status" => "applied",
                 "group_id" => "transfer-dest",
                 "refunded_cents" => 2_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/payments/pay-transfer-cash")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-transfer-cash",
               "original_group_id" => "transfer-source",
               "recorded_cents" => 5_000,
               "held_cents" => 3_000,
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "transfer-source", "amount_cents" => 3_000}
               ]
             }
           }

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit", %{"on" => "2027-03-15"})

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 3_300,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-transfer-credit-origin",
                   "remaining_cents" => 3_300,
                   "expires_on" => "2028-02-10"
                 }
               ]
             }
           }
  end

  test "rejects invalid transfers in the required validation order", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{
            "operation_id" => "open-transfer-source",
            "group_id" => "transfer-source"
          }),
          open_group_operation(%{
            "operation_id" => "open-transfer-dest",
            "group_id" => "transfer-dest",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "small-room", "nightly_rate_cents" => 2_500}]
          }),
          open_group_operation(%{
            "operation_id" => "open-transfer-other",
            "group_id" => "transfer-other",
            "guest_id" => "guest-other"
          }),
          payment_operation("pay-transfer-source", "transfer-source", 1_000),
          transfer_deposit_operation(
            "missing-transfer-source",
            "missing-source",
            "transfer-dest",
            1
          ),
          transfer_deposit_operation(
            "missing-transfer-dest",
            "transfer-source",
            "missing-dest",
            1
          ),
          transfer_deposit_operation(
            "stale-transfer-source",
            "transfer-source",
            "transfer-dest",
            1,
            %{
              "expected_revision" => 9
            }
          ),
          transfer_deposit_operation(
            "stale-transfer-dest",
            "transfer-source",
            "transfer-dest",
            1,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 9
            }
          ),
          transfer_deposit_operation(
            "same-transfer-group",
            "transfer-source",
            "transfer-source",
            1,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 2
            }
          ),
          transfer_deposit_operation(
            "different-transfer-guest",
            "transfer-source",
            "transfer-other",
            1,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }
          ),
          transfer_deposit_operation(
            "bad-transfer-amount",
            "transfer-source",
            "transfer-dest",
            0,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }
          ),
          transfer_deposit_operation(
            "too-much-transfer-funding",
            "transfer-source",
            "transfer-dest",
            2_000,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }
          ),
          transfer_deposit_operation(
            "too-much-transfer-outstanding",
            "transfer-source",
            "transfer-dest",
            1_000,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }
          ),
          transfer_deposit_operation(
            "valid-small-transfer",
            "transfer-source",
            "transfer-dest",
            500,
            %{
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }
          ),
          cancel_operation("cancel-transfer-dest", "transfer-dest", "2026-11-26", %{
            "expected_revision" => 2
          }),
          transfer_deposit_operation(
            "inactive-transfer-dest",
            "transfer-source",
            "transfer-dest",
            1,
            %{
              "expected_revision" => 3,
              "destination_expected_revision" => 3
            }
          )
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "open-transfer-source",
                 "status" => "applied",
                 "group_id" => "transfer-source",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "open-transfer-dest",
                 "status" => "applied",
                 "group_id" => "transfer-dest",
                 "deposit_due_cents" => 500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "open-transfer-other",
                 "status" => "applied",
                 "group_id" => "transfer-other",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-transfer-source",
                 "status" => "applied",
                 "group_id" => "transfer-source",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "missing-transfer-source",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-source"
               },
               %{
                 "operation_id" => "missing-transfer-dest",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-dest"
               },
               %{
                 "operation_id" => "stale-transfer-source",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "transfer-source",
                 "expected_revision" => 9,
                 "actual_revision" => 2
               },
               %{
                 "operation_id" => "stale-transfer-dest",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "transfer-dest",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "same-transfer-group",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               },
               %{
                 "operation_id" => "different-transfer-guest",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               },
               %{
                 "operation_id" => "bad-transfer-amount",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               },
               %{
                 "operation_id" => "too-much-transfer-funding",
                 "status" => "rejected",
                 "code" => "transfer_exceeds_held_funding"
               },
               %{
                 "operation_id" => "too-much-transfer-outstanding",
                 "status" => "rejected",
                 "code" => "transfer_exceeds_outstanding"
               },
               %{
                 "operation_id" => "valid-small-transfer",
                 "status" => "applied",
                 "source_group_id" => "transfer-source",
                 "destination_group_id" => "transfer-dest",
                 "amount_cents" => 500,
                 "source_outstanding_deposit_cents" => 19_000,
                 "destination_outstanding_deposit_cents" => 0,
                 "source_revision" => 3,
                 "destination_revision" => 2
               },
               %{
                 "operation_id" => "cancel-transfer-dest",
                 "status" => "applied",
                 "group_id" => "transfer-dest",
                 "refunded_cents" => 500,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               },
               %{
                 "operation_id" => "inactive-transfer-dest",
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "transfer-dest"
               }
             ]
           }
  end

  test "reduces transferred held cash in reverse allocation order across groups", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_three_room_operation(%{
            "operation_id" => "open-reduce-transfer-source",
            "group_id" => "reduce-transfer-source"
          }),
          open_three_room_operation(%{
            "operation_id" => "open-reduce-transfer-dest",
            "group_id" => "reduce-transfer-dest"
          }),
          payment_operation("pay-reduce-transfer", "reduce-transfer-source", 6_000),
          transfer_deposit_operation(
            "move-reduce-transfer",
            "reduce-transfer-source",
            "reduce-transfer-dest",
            2_000,
            %{"expected_revision" => 2, "destination_expected_revision" => 1}
          ),
          reduce_cash_payment_operation("reduce-after-transfer", "pay-reduce-transfer", 3_000, %{
            "expected_revision" => 3
          })
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-reduce-transfer-source", "revision" => 1},
               %{"operation_id" => "open-reduce-transfer-dest", "revision" => 1},
               %{"operation_id" => "pay-reduce-transfer", "revision" => 2},
               %{
                 "operation_id" => "move-reduce-transfer",
                 "source_revision" => 3,
                 "destination_revision" => 2
               },
               %{
                 "operation_id" => "reduce-after-transfer",
                 "status" => "applied",
                 "payment_operation_id" => "pay-reduce-transfer",
                 "group_id" => "reduce-transfer-source",
                 "amount_cents" => 3_000,
                 "outstanding_deposit_cents" => 9_000,
                 "revision" => 4
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/reduce-transfer-source")

    assert %{
             "data" => %{
               "revision" => 4,
               "cash_paid_cents" => 3_000,
               "outstanding_deposit_cents" => 9_000
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/reduce-transfer-dest")

    assert %{
             "data" => %{
               "revision" => 3,
               "cash_paid_cents" => 0,
               "outstanding_deposit_cents" => 12_000
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/pay-reduce-transfer")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-reduce-transfer",
               "original_group_id" => "reduce-transfer-source",
               "recorded_cents" => 6_000,
               "held_cents" => 3_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3_000,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "reduce-transfer-source", "amount_cents" => 3_000}
               ]
             }
           }
  end

  test "charges back transferred cash that settled under the destination group", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(%{
            "operation_id" => "open-charge-transfer-source",
            "group_id" => "charge-transfer-source"
          }),
          open_group_operation(%{
            "operation_id" => "open-charge-transfer-dest",
            "group_id" => "charge-transfer-dest",
            "rate_plan" => "advance_purchase"
          }),
          payment_operation("pay-charge-transfer", "charge-transfer-source", 5_000),
          transfer_deposit_operation(
            "move-charge-transfer",
            "charge-transfer-source",
            "charge-transfer-dest",
            5_000,
            %{"expected_revision" => 2, "destination_expected_revision" => 1}
          ),
          cancel_operation("cancel-charge-transfer-dest", "charge-transfer-dest", "2026-11-01", %{
            "expected_revision" => 2
          }),
          charge_back_payment_operation("charge-back-transferred-cash", "pay-charge-transfer", %{
            "expected_revision" => 3
          })
        ]
      })

    assert %{
             "results" => [
               %{"operation_id" => "open-charge-transfer-source", "revision" => 1},
               %{"operation_id" => "open-charge-transfer-dest", "revision" => 1},
               %{"operation_id" => "pay-charge-transfer", "revision" => 2},
               %{"operation_id" => "move-charge-transfer", "source_revision" => 3},
               %{
                 "operation_id" => "cancel-charge-transfer-dest",
                 "retained_cents" => 5_000,
                 "revision" => 3
               },
               %{
                 "operation_id" => "charge-back-transferred-cash",
                 "status" => "applied",
                 "payment_operation_id" => "pay-charge-transfer",
                 "group_id" => "charge-transfer-source",
                 "charged_back_cents" => 5_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 4
               }
             ]
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/groups/charge-transfer-dest")

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 4
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/payments/pay-charge-transfer")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-charge-transfer",
               "original_group_id" => "charge-transfer-source",
               "recorded_cents" => 5_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 5_000,
               "held_by_group" => []
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_charged_back_cents" => 5_000
             }
           } = json_response(conn, 200)
  end

  test "returns stable rejection codes for payment reductions and chargebacks", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation(),
          payment_operation("too-large-payment", "group-81", 20_000),
          payment_operation("good-payment", "group-81", 1_000),
          reduce_cash_payment_operation("missing-reduction-target", "missing-payment", 1),
          reduce_cash_payment_operation("rejected-payment-reduction", "too-large-payment", 1),
          reduce_cash_payment_operation("stale-reduction", "good-payment", 0, %{
            "expected_revision" => 9
          }),
          reduce_cash_payment_operation("bad-reduction-amount", "good-payment", 0, %{
            "expected_revision" => 2
          }),
          charge_back_payment_operation("non-payment-chargeback", "op-open", %{
            "expected_revision" => 2
          }),
          charge_back_payment_operation("good-chargeback", "good-payment", %{
            "expected_revision" => 2
          }),
          charge_back_payment_operation("repeat-chargeback", "good-payment", %{
            "expected_revision" => 3
          }),
          reduce_cash_payment_operation("settled-payment-reduction", "good-payment", 1, %{
            "expected_revision" => 3
          })
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "too-large-payment",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "good-payment",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "missing-reduction-target",
                 "status" => "rejected",
                 "code" => "operation_not_found"
               },
               %{
                 "operation_id" => "rejected-payment-reduction",
                 "status" => "rejected",
                 "code" => "payment_not_reducible"
               },
               %{
                 "operation_id" => "stale-reduction",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 9,
                 "actual_revision" => 2
               },
               %{
                 "operation_id" => "bad-reduction-amount",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               },
               %{
                 "operation_id" => "non-payment-chargeback",
                 "status" => "rejected",
                 "code" => "payment_not_chargeable"
               },
               %{
                 "operation_id" => "good-chargeback",
                 "status" => "applied",
                 "payment_operation_id" => "good-payment",
                 "group_id" => "group-81",
                 "charged_back_cents" => 1_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               },
               %{
                 "operation_id" => "repeat-chargeback",
                 "status" => "rejected",
                 "code" => "payment_not_chargeable"
               },
               %{
                 "operation_id" => "settled-payment-reduction",
                 "status" => "rejected",
                 "code" => "payment_not_reducible"
               }
             ]
           }

    conn = get(build_conn(), ~p"/api/v1/payments/missing-payment")

    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}

    conn = get(build_conn(), ~p"/api/v1/payments/op-open")

    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "returns stable rejection codes for invalid operations", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          %{"operation_id" => "unknown", "type" => "hold_room", "occurred_on" => "2026-10-01"},
          open_group_operation(%{
            "operation_id" => "bad-stay",
            "group_id" => "bad-stay",
            "departure_on" => "2026-12-10"
          }),
          open_group_operation(%{
            "operation_id" => "bad-rooms",
            "group_id" => "bad-rooms",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
            ]
          }),
          open_group_operation(%{
            "operation_id" => "bad-rate",
            "group_id" => "bad-rate",
            "rate_plan" => "prepaid"
          }),
          open_group_operation(%{"operation_id" => "first-open", "group_id" => "duplicate"}),
          open_group_operation(%{"operation_id" => "second-open", "group_id" => "duplicate"}),
          %{
            "operation_id" => "missing-group",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "missing",
            "amount_cents" => 1
          },
          payment_operation("bad-amount", "duplicate", 0)
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "unknown",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "bad-stay", "status" => "rejected", "code" => "invalid_stay"},
               %{
                 "operation_id" => "bad-rooms",
                 "status" => "rejected",
                 "code" => "invalid_rooms"
               },
               %{
                 "operation_id" => "bad-rate",
                 "status" => "rejected",
                 "code" => "invalid_rate_plan"
               },
               %{
                 "operation_id" => "first-open",
                 "status" => "applied",
                 "group_id" => "duplicate",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "second-open",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               },
               %{
                 "operation_id" => "missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found"
               },
               %{
                 "operation_id" => "bad-amount",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               }
             ]
           }
  end

  test "returns group_not_found when reading a missing group", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/groups/missing")

    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "returns operation_not_found when reading a missing operation", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/operations/missing-operation")

    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  defp open_group_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
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

  defp open_credit_source_operation(group_id, operation_id, arrival_on) do
    open_group_operation(%{
      "operation_id" => operation_id,
      "group_id" => group_id,
      "occurred_on" => "2027-01-02",
      "arrival_on" => arrival_on,
      "departure_on" => "2027-04-13"
    })
  end

  defp open_three_room_operation(overrides \\ %{}) do
    open_group_operation(
      Map.merge(
        %{
          "operation_id" => "open-three",
          "group_id" => "room-accounting",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 20_000},
            %{"room_id" => "room-c", "nightly_rate_cents" => 30_000}
          ]
        },
        overrides
      )
    )
  end

  defp payment_operation(operation_id, group_id, amount_cents, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, overrides) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp cancel_rooms_operation(operation_id, group_id, room_ids, overrides) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  defp reduce_cash_payment_operation(
         operation_id,
         payment_operation_id,
         amount_cents,
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "reduce_cash_payment",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp charge_back_payment_operation(operation_id, payment_operation_id, overrides) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "charge_back_payment",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp transfer_deposit_operation(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp post_partner_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(~p"/api/v1/partner-batches", body)
  end
end
