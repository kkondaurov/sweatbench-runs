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
end
