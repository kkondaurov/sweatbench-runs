defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  test "opens and reads a group with ordered rooms and totals", %{conn: conn} do
    response = submit(conn, [open_operation("group-81")])

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
           } = json_response(response, 200)

    conn = get(conn, "/api/v1/groups/group-81")

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

  test "processes funding, moving, and cancellation in order", %{conn: conn} do
    operations = [
      open_operation("group-lifecycle", %{
        "occurred_on" => "2026-01-01",
        "arrival_on" => "2026-02-10",
        "departure_on" => "2026-02-13",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "group-lifecycle",
        "amount_cents" => 2_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "group-lifecycle",
        "new_arrival_on" => "2026-02-20",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-30",
        "group_id" => "group-lifecycle",
        "expected_revision" => 3
      }
    ]

    response = submit(conn, operations)

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "outstanding_deposit_cents" => 4_000, "revision" => 2},
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-02-20",
                 "new_departure_on" => "2026-02-23",
                 "revision" => 3
               },
               %{
                 "status" => "applied",
                 "refunded_cents" => 2_000,
                 "retained_cents" => 0,
                 "revision" => 4
               }
             ]
           } = json_response(response, 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2_000,
               "cash_retained_cents" => 0
             }
           } =
             json_response(get(conn, "/api/v1/ledger"), 200)

    assert %{
             "data" => %{
               "status" => "cancelled",
               "deposit_paid_cents" => 2_000,
               "outstanding_deposit_cents" => 0
             }
           } =
             json_response(get(conn, "/api/v1/groups/group-lifecycle"), 200)
  end

  test "rejects stale revisions before other validation and continues the batch", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-revisions", %{
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        }),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-revisions",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "pay-stale",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-revisions",
          "amount_cents" => 0,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "pay-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-revisions",
          "amount_cents" => 1_000,
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "pay-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-revisions",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               },
               %{"status" => "applied", "revision" => 3}
             ]
           } = json_response(response, 200)
  end

  test "uses the full advance-purchase deposit and retains late cancellation cash", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-advance", %{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-12"
        }),
        %{
          "operation_id" => "pay-advance",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-advance",
          "amount_cents" => 20_000
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-advance"
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied", "deposit_due_cents" => 20_000, "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 20_000}
             ]
           } = json_response(response, 200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 20_000
             }
           } =
             json_response(get(conn, "/api/v1/ledger"), 200)
  end

  test "rejects invalid group data without creating it", %{conn: conn} do
    assert {:error, changeset} = GroupStay.Groups.insert_group(%{}, [])
    refute changeset.valid?

    response =
      submit(conn, [
        open_operation("group-invalid-stay", %{
          "arrival_on" => "2026-12-12",
          "departure_on" => "2026-12-10"
        }),
        open_operation("group-invalid-rooms", %{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 11_000}
          ]
        }),
        open_operation("group-invalid-rate", %{"rate_plan" => "non_refundable"}),
        open_operation("group-invalid-date", %{"occurred_on" => nil}),
        open_operation("group-invalid-rooms-type", %{"rooms" => nil}),
        Map.delete(open_operation("group-invalid-operation"), "operation_id")
      ])

    assert %{
             "results" => [
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_rate_plan"},
               %{"code" => "invalid_stay"},
               %{"code" => "invalid_rooms"},
               %{"code" => "invalid_operation"}
             ]
           } =
             json_response(response, 200)

    response = get(conn, "/api/v1/groups/group-invalid-stay")
    assert json_response(response, 404)["error"]["code"] == "group_not_found"
  end

  test "keeps rejected updates side-effect free and rejects inactive groups", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("group-errors", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        }),
        open_operation("group-errors"),
        %{
          "operation_id" => "pay-zero",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors",
          "amount_cents" => 0
        },
        %{
          "operation_id" => "pay-too-much",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors",
          "amount_cents" => 2_001
        },
        %{
          "operation_id" => "pay-bad-date",
          "type" => "record_cash_payment",
          "occurred_on" => "not-a-date",
          "group_id" => "group-errors",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "move-bad-date",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors",
          "new_arrival_on" => "2026-10-04"
        },
        %{
          "operation_id" => "cancel-bad-date",
          "type" => "cancel_group",
          "occurred_on" => "not-a-date",
          "group_id" => "group-errors"
        },
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-errors"
        },
        %{
          "operation_id" => "pay-inactive",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-errors",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "move-inactive",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-errors",
          "new_arrival_on" => "2026-12-11"
        },
        %{
          "operation_id" => "cancel-inactive",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-errors"
        },
        %{
          "operation_id" => "missing-group",
          "type" => "record_cash_payment",
          "group_id" => "missing-group",
          "amount_cents" => 1
        },
        %{"operation_id" => "unknown", "type" => "something_else"},
        nil
      ])

    assert %{"results" => results} = json_response(response, 200)

    assert Enum.map(results, &Map.get(&1, "code")) == [
             nil,
             "group_already_exists",
             "invalid_amount",
             "payment_exceeds_outstanding",
             "invalid_operation",
             "invalid_stay",
             "invalid_stay",
             nil,
             "group_not_active",
             "group_not_active",
             "group_not_active",
             "group_not_found",
             "invalid_operation",
             "invalid_operation"
           ]

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 0, "status" => "cancelled"}} =
             json_response(get(conn, "/api/v1/groups/group-errors"), 200)
  end

  test "returns invalid batch and missing group errors", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => "not-a-list"}))

    assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)

    assert %{"error" => %{"code" => "group_not_found"}} =
             json_response(get(build_conn(), "/api/v1/groups/missing"), 404)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           } =
             json_response(get(build_conn(), "/api/v1/ledger"), 200)
  end
end
