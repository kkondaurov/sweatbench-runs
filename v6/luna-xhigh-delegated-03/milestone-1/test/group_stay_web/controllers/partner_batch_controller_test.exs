defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

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

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "opens a group and returns it with calculated totals and room order", %{conn: conn} do
    conn = post_batch(conn, [open_operation()])

    assert %{
             "results" => [
               %{"status" => "applied", "deposit_due_cents" => 19_500, "revision" => 1}
             ]
           } =
             json_response(conn, 200)

    conn = get(conn, "/api/v1/groups/group-81")
    response = json_response(conn, 200)

    assert response["data"] == %{
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
  end

  test "processes payment, reschedule, and cancellation with revisions and ledger settlement", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied", "revision" => 1}]} =
             post_batch(conn, [open_operation()]) |> json_response(200)

    assert %{
             "results" => [
               %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 9_500}
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "expected_revision" => 1
               }
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "revision" => 3,
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23"
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "move-1",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied", "revision" => 4, "refunded_cents" => 10_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-12-01",
                 "group_id" => "group-81",
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)

    conn = get(conn, "/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0
             }
           }

    conn = get(conn, "/api/v1/groups/group-81")
    assert json_response(conn, 200)["data"]["outstanding_deposit_cents"] == 0
  end

  test "advance-purchase deposits are full lodging and retained on cancellation", %{conn: conn} do
    operations = [
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance-group",
        "rate_plan" => "advance_purchase"
      }),
      %{
        "operation_id" => "pay-advance",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "advance-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "cancel-advance",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-10",
        "group_id" => "advance-group",
        "expected_revision" => 2
      }
    ]

    assert %{
             "results" => [
               %{"deposit_due_cents" => 97_500, "revision" => 1},
               %{"outstanding_deposit_cents" => 96_500, "revision" => 2},
               %{"refunded_cents" => 0, "retained_cents" => 1_000, "revision" => 3}
             ]
           } = post_batch(conn, operations) |> json_response(200)

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 1_000
             }
           }
  end

  test "rejects stale revisions before domain validation and continues the batch", %{conn: conn} do
    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [open_operation()]) |> json_response(200)

    response =
      post_batch(conn, [
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 99
        },
        %{
          "operation_id" => "pay-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 1,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "bad-type",
          "type" => "unknown",
          "occurred_on" => "2026-10-04"
        }
      ])
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "pay-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 99,
               "actual_revision" => 1
             },
             %{
               "operation_id" => "pay-2",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 1,
               "outstanding_deposit_cents" => 19_499,
               "revision" => 2
             },
             %{
               "operation_id" => "bad-type",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
           ]
  end

  test "invalid batches and missing groups use the documented errors", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => %{}}))

    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

    conn =
      post_batch(build_conn(), [
        %{
          "operation_id" => "pay-missing",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "missing",
          "amount_cents" => 1,
          "expected_revision" => 99
        }
      ])

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "pay-missing",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing"
               }
             ]
           }

    conn = get(build_conn(), "/api/v1/groups/missing")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "does not apply malformed payment dates and preserves inactive-group precedence", %{
    conn: conn
  } do
    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [open_operation()]) |> json_response(200)

    assert %{"results" => [%{"code" => "invalid_operation"}, %{"revision" => 2}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "bad-date",
                 "type" => "record_cash_payment",
                 "occurred_on" => "not-a-date",
                 "group_id" => "group-81",
                 "amount_cents" => 1,
                 "expected_revision" => 1
               },
               %{
                 "operation_id" => "pay-1",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 1,
                 "expected_revision" => 1
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "cancel-1",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert json_response(
             post_batch(build_conn(), [
               %{
                 "operation_id" => "late-payment",
                 "type" => "record_cash_payment",
                 "group_id" => "group-81",
                 "amount_cents" => 1,
                 "expected_revision" => 3
               }
             ]),
             200
           ) == %{
             "results" => [
               %{
                 "operation_id" => "late-payment",
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "group-81"
               }
             ]
           }
  end
end
