defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 15000},
          %{room_id: "room-b", nightly_rate_cents: 17500}
        ]
      },
      overrides
    )
  end

  test "opens a group, calculates each room's deposit, and preserves room order", %{conn: conn} do
    response = post_batch(conn, [open_operation("op-1001")])

    assert json_response(response, 200) == %{
             "results" => [
               %{
                 "operation_id" => "op-1001",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19500,
                 "revision" => 1
               }
             ]
           }

    group_response = get(build_conn(), "/api/v1/groups/group-81")

    assert json_response(group_response, 200) == %{
             "data" => %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15000,
                   "status" => "active",
                   "deposit_due_cents" => 9000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17500,
                   "status" => "active",
                   "deposit_due_cents" => 10500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19500
             }
           }
  end

  test "processes batches in order and isolates rejected operations", %{conn: conn} do
    response =
      post_batch(conn, [
        open_operation("op-open"),
        %{
          operation_id: "op-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 5000
        },
        %{
          operation_id: "op-too-large",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 15000
        },
        %{
          operation_id: "op-move",
          type: "reschedule_group",
          occurred_on: "2026-10-05",
          group_id: "group-81",
          new_arrival_on: "2026-12-12"
        }
      ])

    assert json_response(response, 200)["results"] == [
             %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             },
             %{
               "operation_id" => "op-payment",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             },
             %{
               "operation_id" => "op-too-large",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding",
               "group_id" => "group-81"
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
             }
           ]

    ledger_response = get(build_conn(), "/api/v1/ledger")

    assert json_response(ledger_response, 200)["data"] == %{
             "cash_held_cents" => 5000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "rejects a stale revision before invalid payment validation", %{conn: conn} do
    assert post_batch(conn, [open_operation("op-open")]) |> json_response(200)

    response =
      post_batch(conn, [
        %{
          operation_id: "op-first-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 1000
        },
        %{
          operation_id: "op-stale",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          expected_revision: 1,
          amount_cents: -1
        },
        %{
          operation_id: "op-valid",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          expected_revision: 2,
          amount_cents: 1000
        }
      ])

    assert json_response(response, 200)["results"] == [
             %{
               "operation_id" => "op-first-payment",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 1000,
               "outstanding_deposit_cents" => 18500,
               "revision" => 2
             },
             %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             },
             %{
               "operation_id" => "op-valid",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 1000,
               "outstanding_deposit_cents" => 17500,
               "revision" => 3
             }
           ]
  end

  test "cancels refundable cash and makes later operations inactive", %{conn: conn} do
    assert post_batch(conn, [
             open_operation("op-open", %{arrival_on: "2026-12-20", departure_on: "2026-12-22"})
           ])
           |> json_response(200)

    response =
      post_batch(conn, [
        %{
          operation_id: "op-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 10000
        },
        %{
          operation_id: "op-cancel",
          type: "cancel_group",
          occurred_on: "2026-11-01",
          group_id: "group-81"
        },
        %{
          operation_id: "op-late-payment",
          type: "record_cash_payment",
          occurred_on: "2026-11-02",
          group_id: "group-81",
          amount_cents: 1
        }
      ])

    assert json_response(response, 200)["results"] == [
             %{
               "operation_id" => "op-payment",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 10000,
               "outstanding_deposit_cents" => 3000,
               "revision" => 2
             },
             %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             },
             %{
               "operation_id" => "op-late-payment",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }
           ]

    group_response = get(build_conn(), "/api/v1/groups/group-81")
    assert json_response(group_response, 200)["data"]["status"] == "cancelled"
    assert json_response(group_response, 200)["data"]["outstanding_deposit_cents"] == 0

    ledger_response = get(build_conn(), "/api/v1/ledger")

    assert json_response(ledger_response, 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 10000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "retains advance-purchase cash when cancelled", %{conn: conn} do
    operation =
      open_operation("op-open", %{
        rate_plan: "advance_purchase",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 10000}]
      })

    assert post_batch(conn, [operation]) |> json_response(200)

    response =
      post_batch(conn, [
        %{
          operation_id: "op-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 30000
        },
        %{
          operation_id: "op-cancel",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "group-81"
        }
      ])

    assert json_response(response, 200)["results"] |> List.last() == %{
             "operation_id" => "op-cancel",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 0,
             "retained_cents" => 30000,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    ledger_response = get(build_conn(), "/api/v1/ledger")

    assert json_response(ledger_response, 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 30000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "returns invalid batch and not found errors", %{conn: conn} do
    invalid_batch =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: %{}}))

    assert json_response(invalid_batch, 422) == %{"error" => %{"code" => "invalid_batch"}}

    missing_group = get(build_conn(), "/api/v1/groups/missing")
    assert json_response(missing_group, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "returns stable domain rejection codes and continues after invalid operations", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        %{
          operation_id: "op-unknown",
          type: "unknown_operation"
        },
        open_operation("op-invalid", %{
          rooms: [
            %{room_id: "duplicate", nightly_rate_cents: 100},
            %{room_id: "duplicate", nightly_rate_cents: 200}
          ]
        }),
        open_operation("op-valid"),
        open_operation("op-duplicate"),
        %{
          operation_id: "op-invalid-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 0
        }
      ])

    assert json_response(response, 200)["results"] == [
             %{
               "operation_id" => "op-unknown",
               "status" => "rejected",
               "code" => "invalid_operation"
             },
             %{
               "operation_id" => "op-invalid",
               "status" => "rejected",
               "code" => "invalid_rooms",
               "group_id" => "group-81"
             },
             %{
               "operation_id" => "op-valid",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             },
             %{
               "operation_id" => "op-duplicate",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "group-81"
             },
             %{
               "operation_id" => "op-invalid-payment",
               "status" => "rejected",
               "code" => "invalid_amount",
               "group_id" => "group-81"
             }
           ]
  end
end
