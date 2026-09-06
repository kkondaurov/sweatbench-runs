defmodule GroupStayWeb.PartnerOperationsTest do
  use GroupStayWeb.ConnCase, async: false

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
             "outstanding_deposit_cents" => 2
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
               "cash_retained_cents" => 0
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
               "revision" => 3
             },
             %{
               "operation_id" => "cancel-retain",
               "status" => "applied",
               "group_id" => "non-refundable",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "revision" => 3
             }
           ]

    assert get(conn, "/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 1_000,
               "cash_retained_cents" => 10_000
             }
           }

    group = get(conn, "/api/v1/groups/refundable") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["deposit_paid_cents"] == 1_000
    assert group["outstanding_deposit_cents"] == 0

    rejected = submit(conn, [payment_operation("refundable", 1)])

    assert rejected["results"] == [
             %{
               "operation_id" => "payment-refundable",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "refundable"
             }
           ]
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
               "cash_retained_cents" => 0
             }
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
