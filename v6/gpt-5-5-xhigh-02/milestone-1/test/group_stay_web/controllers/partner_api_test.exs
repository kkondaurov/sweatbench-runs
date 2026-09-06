defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

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
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
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
                 "revision" => 3
               },
               %{
                 "operation_id" => "op-cancel",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 0,
                 "retained_cents" => 10_000,
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
               "deposit_paid_cents" => 10_000,
               "outstanding_deposit_cents" => 0
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 10_000
             }
           }
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
               "cash_retained_cents" => 97_500
             }
           }
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

  defp payment_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
