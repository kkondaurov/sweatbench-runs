defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: true

  import Ecto.Query

  alias GroupStay.Groups.PartnerOperation
  alias GroupStay.Repo

  test "opens a group and exposes its booking, rooms, and calculated deposit", %{conn: conn} do
    conn = post_operations(conn, [open_operation("group-81")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-group-81",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/group-81")

    assert %{
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
           } = json_response(conn, 200)
  end

  test "processes batch operations in order and leaves rejected operations isolated", %{
    conn: conn
  } do
    operations = [
      %{"operation_id" => "unknown", "type" => "not_supported", "occurred_on" => "2026-10-03"},
      %{"operation_id" => "missing-type", "occurred_on" => "2026-10-03"},
      open_operation("valid-group"),
      open_operation("bad-stay", %{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"}),
      open_operation("bad-date", %{"arrival_on" => "not-a-date"}),
      open_operation("bad-rooms", %{"rooms" => []}),
      open_operation("duplicate-rooms", %{
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 100},
          %{"room_id" => "same", "nightly_rate_cents" => 100}
        ]
      }),
      open_operation("bad-rate", %{"rate_plan" => "weekend"}),
      open_operation("valid-group", %{"operation_id" => "duplicate"})
    ]

    conn = post_operations(conn, operations)

    assert %{
             "results" => [
               %{
                 "operation_id" => "unknown",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "missing-type",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"status" => "applied", "group_id" => "valid-group", "revision" => 1},
               %{"status" => "rejected", "code" => "invalid_stay", "group_id" => "bad-stay"},
               %{"status" => "rejected", "code" => "invalid_stay", "group_id" => "bad-date"},
               %{"status" => "rejected", "code" => "invalid_rooms", "group_id" => "bad-rooms"},
               %{
                 "status" => "rejected",
                 "code" => "invalid_rooms",
                 "group_id" => "duplicate-rooms"
               },
               %{"status" => "rejected", "code" => "invalid_rate_plan", "group_id" => "bad-rate"},
               %{
                 "operation_id" => "duplicate",
                 "status" => "rejected",
                 "code" => "group_already_exists",
                 "group_id" => "valid-group"
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/bad-rooms")
    assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
  end

  test "rejects an invalid batch body and reports missing groups", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } = json_response(conn, 200)

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => %{}})
    assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

    conn = get(conn, ~p"/api/v1/groups/missing")
    assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
  end

  test "checks stale revisions before other operation validation and increments applied revisions",
       %{conn: conn} do
    conn = post_operations(conn, [open_operation("revision-group")])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("stale-payment", "revision-group", 0, 0),
        payment_operation("missing-group", "does-not-exist", 1, 1),
        payment_operation("paid", "revision-group", 5_000, 1),
        payment_operation("too-much", "revision-group", 14_501),
        payment_operation("invalid-amount", "revision-group", 0),
        %{
          "operation_id" => "invalid-reschedule",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "revision-group",
          "new_arrival_on" => "not-a-date"
        }
      ])

    assert %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "revision-group",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "does-not-exist"
               },
               %{
                 "operation_id" => "paid",
                 "status" => "applied",
                 "group_id" => "revision-group",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "too-much",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding",
                 "group_id" => "revision-group"
               },
               %{
                 "operation_id" => "invalid-amount",
                 "status" => "rejected",
                 "code" => "invalid_amount",
                 "group_id" => "revision-group"
               },
               %{
                 "operation_id" => "invalid-reschedule",
                 "status" => "rejected",
                 "code" => "invalid_stay",
                 "group_id" => "revision-group"
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/revision-group")

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} =
             json_response(conn, 200)
  end

  test "reschedules an active group, refunds timely flexible cash, and closes further changes", %{
    conn: conn
  } do
    conn = post_operations(conn, [open_operation("refundable")])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("payment", "refundable", 5_000, 1),
        %{
          "operation_id" => "move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-10",
          "group_id" => "refundable",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-06",
          "group_id" => "refundable",
          "expected_revision" => 3
        }
      ])

    assert %{
             "results" => [
               %{"operation_id" => "payment", "status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "move",
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "revision" => 3
               },
               %{
                 "operation_id" => "cancel",
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/refundable")

    assert %{
             "data" => %{
               "status" => "cancelled",
               "revision" => 4,
               "arrival_on" => "2026-12-20",
               "departure_on" => "2026-12-23",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "lodging_total_cents" => 97_500
             }
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("payment-after-cancel", "refundable", 1, 4),
        %{
          "operation_id" => "move-after-cancel",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-07",
          "group_id" => "refundable",
          "new_arrival_on" => "2026-12-24",
          "expected_revision" => 4
        },
        %{
          "operation_id" => "cancel-after-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-07",
          "group_id" => "refundable",
          "expected_revision" => 4
        }
      ])

    assert %{
             "results" => [
               %{"code" => "group_not_active", "status" => "rejected"},
               %{"code" => "group_not_active", "status" => "rejected"},
               %{"code" => "group_not_active", "status" => "rejected"}
             ]
           } = json_response(conn, 200)
  end

  test "retains late flexible and all advance-purchase cash", %{conn: conn} do
    late_flexible =
      open_operation("late-flexible", %{
        "rooms" => [
          %{"room_id" => "rounded-a", "nightly_rate_cents" => 1},
          %{"room_id" => "rounded-b", "nightly_rate_cents" => 1}
        ]
      })

    advance_purchase =
      open_operation("advance", %{
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "prepaid", "nightly_rate_cents" => 100}]
      })

    conn = post_operations(conn, [late_flexible, advance_purchase])

    assert %{
             "results" => [
               %{"group_id" => "late-flexible", "deposit_due_cents" => 2},
               %{"group_id" => "advance", "deposit_due_cents" => 300}
             ]
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        payment_operation("late-payment", "late-flexible", 2, 1),
        %{
          "operation_id" => "late-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "late-flexible",
          "expected_revision" => 2
        },
        payment_operation("advance-payment", "advance", 300, 1),
        %{
          "operation_id" => "advance-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "advance",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 2,
                 "revision" => 3
               },
               %{"status" => "applied", "revision" => 2},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 300,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/ledger")

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 302
             }
           } = json_response(conn, 200)
  end

  test "replays an applied operation exactly and exposes its original result", %{conn: conn} do
    operation = open_operation("idempotent-group")

    conn = post_operations(conn, [operation])

    assert %{"results" => [original_result]} = json_response(conn, 200)
    assert %{"revision" => 1, "status" => "applied"} = original_result

    conn =
      post_operations(conn, [payment_operation("later-payment", "idempotent-group", 5_000, 1)])

    assert %{"results" => [%{"revision" => 2}]} = json_response(conn, 200)

    reordered_operation = Map.new(Enum.reverse(Map.to_list(operation)))
    conn = post_operations(conn, [reordered_operation])
    assert %{"results" => [^original_result]} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/operations/open-idempotent-group")
    assert %{"data" => ^original_result} = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/groups/idempotent-group")

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} =
             json_response(conn, 200)
  end

  test "remembers rejections and rejects conflicting operation identifiers", %{conn: conn} do
    rejected_operation = payment_operation("remembered-rejection", "appears-later", 500)

    conn = post_operations(conn, [rejected_operation])

    assert %{
             "results" => [
               %{
                 "operation_id" => "remembered-rejection",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "appears-later"
               } = original_result
             ]
           } = json_response(conn, 200)

    conn = post_operations(conn, [open_operation("appears-later")])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

    conn = post_operations(conn, [rejected_operation])
    assert %{"results" => [^original_result]} = json_response(conn, 200)

    conflicting_operation = Map.put(rejected_operation, "amount_cents", 600)
    conn = post_operations(conn, [conflicting_operation])

    assert %{
             "results" => [
               %{
                 "operation_id" => "remembered-rejection",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/operations/remembered-rejection")
    assert %{"data" => ^original_result} = json_response(conn, 200)
  end

  test "replays stale-revision details from the original attempt", %{conn: conn} do
    conn = post_operations(conn, [open_operation("stale-retry")])
    assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

    stale_operation = payment_operation("remembered-stale", "stale-retry", 500, 0)
    conn = post_operations(conn, [stale_operation])

    assert %{
             "results" => [
               %{
                 "operation_id" => "remembered-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "stale-retry",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               } = original_result
             ]
           } = json_response(conn, 200)

    conn = post_operations(conn, [payment_operation("advance-revision", "stale-retry", 500, 1)])
    assert %{"results" => [%{"revision" => 2}]} = json_response(conn, 200)

    conn = post_operations(conn, [stale_operation])
    assert %{"results" => [^original_result]} = json_response(conn, 200)
  end

  test "stores complete submissions and results in commit order", %{conn: conn} do
    first_operation =
      open_operation("audit-first", %{
        "metadata" => %{"source" => %{"name" => "gateway"}, "attempts" => [1, 2]}
      })

    second_operation = %{
      "operation_id" => "audit-second",
      "type" => "not_supported",
      "occurred_on" => "2026-10-03"
    }

    conn = post_operations(conn, [first_operation, second_operation])
    assert %{"results" => [first_result, second_result]} = json_response(conn, 200)

    operations = Repo.all(from(operation in PartnerOperation, order_by: operation.id))

    assert Enum.map(operations, & &1.operation_id) == ["open-audit-first", "audit-second"]
    assert Enum.map(operations, & &1.operation_type) == ["open_group", "not_supported"]
    assert Enum.map(operations, & &1.payload) == [first_operation, second_operation]
    assert Enum.map(operations, & &1.result) == [first_result, second_result]
  end

  test "reports missing durable operations", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/operations/missing")
    assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
  end

  defp post_operations(conn, operations) do
    post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp open_operation(group_id, overrides \\ %{}) do
    operation = %{
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

    Map.merge(operation, overrides)
  end

  defp payment_operation(operation_id, group_id, amount_cents, expected_revision \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }

    if is_nil(expected_revision) do
      operation
    else
      Map.put(operation, "expected_revision", expected_revision)
    end
  end
end
