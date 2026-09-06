defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-13",
        rate_plan: "flexible",
        rooms: [
          %{room_id: "room-a", nightly_rate_cents: 15_000},
          %{room_id: "room-b", nightly_rate_cents: 17_500}
        ]
      },
      overrides
    )
  end

  test "opens and reads a group with ordered rooms and calculated totals", %{conn: conn} do
    response =
      conn
      |> json_post("/api/v1/partner-batches", %{operations: [open_operation("group-81")]})
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "open-group-81",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    assert %{
             "group_id" => "group-81",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
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
           } = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
  end

  test "processes a batch in order and keeps rejected operations isolated", %{conn: conn} do
    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          open_operation("group-ordered"),
          %{
            operation_id: "bad-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-04",
            group_id: "group-ordered",
            amount_cents: 20_000
          },
          %{
            operation_id: "good-payment",
            type: "record_cash_payment",
            occurred_on: "2026-10-04",
            group_id: "group-ordered",
            amount_cents: 19_500,
            expected_revision: 1
          },
          %{
            operation_id: "move",
            type: "reschedule_group",
            occurred_on: "2026-10-05",
            group_id: "group-ordered",
            new_arrival_on: "2026-12-20",
            expected_revision: 2
          }
        ]
      })
      |> json_response(200)

    assert Enum.map(response["results"], & &1["status"]) == [
             "applied",
             "rejected",
             "applied",
             "applied"
           ]

    assert Enum.at(response["results"], 1)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(response["results"], 2)["revision"] == 2
    assert Enum.at(response["results"], 3)["new_departure_on"] == "2026-12-23"

    group =
      conn |> get("/api/v1/groups/group-ordered") |> json_response(200) |> Map.fetch!("data")

    assert group["revision"] == 3
    assert group["deposit_paid_cents"] == 19_500
    assert group["outstanding_deposit_cents"] == 0
  end

  test "rejects stale revisions before domain validation", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{operations: [open_operation("group-stale")]})
    |> json_response(200)

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "payment-stale",
            type: "record_cash_payment",
            occurred_on: "not-a-date",
            group_id: "group-stale",
            amount_cents: -1,
            expected_revision: 0
          }
        ]
      })
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "payment-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-stale",
               "expected_revision" => 0,
               "actual_revision" => 1
             }
           ]
  end

  test "cancellation moves paid cash to the appropriate ledger bucket", %{conn: conn} do
    conn
    |> json_post("/api/v1/partner-batches", %{operations: [open_operation("group-refund")]})
    |> json_response(200)

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "pay-refund",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-refund",
          amount_cents: 19_500
        },
        %{
          operation_id: "cancel-refund",
          type: "cancel_group",
          occurred_on: "2026-11-26",
          group_id: "group-refund",
          expected_revision: 2
        }
      ]
    })
    |> json_response(200)

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 19_500,
             "cash_retained_cents" => 0
           } = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert %{"status" => "cancelled", "outstanding_deposit_cents" => 0} =
             conn
             |> get("/api/v1/groups/group-refund")
             |> json_response(200)
             |> Map.fetch!("data")

    inactive_response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{
            operation_id: "pay-after-cancel",
            type: "record_cash_payment",
            occurred_on: "2026-11-27",
            group_id: "group-refund",
            amount_cents: 1
          }
        ]
      })
      |> json_response(200)

    assert hd(inactive_response["results"])["code"] == "group_not_active"
  end

  test "rounds flexible deposits per room and retains late advance-purchase cash", %{conn: conn} do
    rounded =
      open_operation("group-rounding", %{
        occurred_on: "2026-09-01",
        arrival_on: "2026-09-10",
        departure_on: "2026-09-11",
        rooms: [
          %{room_id: "small-a", nightly_rate_cents: 3},
          %{room_id: "small-b", nightly_rate_cents: 3}
        ]
      })

    advance =
      open_operation("group-advance", %{
        rate_plan: "advance_purchase",
        rooms: [%{room_id: "advance-room", nightly_rate_cents: 30_000}]
      })

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{operations: [rounded, advance]})
      |> json_response(200)

    assert Enum.map(response["results"], & &1["deposit_due_cents"]) == [2, 90_000]

    conn
    |> json_post("/api/v1/partner-batches", %{
      operations: [
        %{
          operation_id: "pay-advance",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-advance",
          amount_cents: 90_000
        },
        %{
          operation_id: "cancel-advance",
          type: "cancel_group",
          occurred_on: "2026-12-01",
          group_id: "group-advance"
        }
      ]
    })
    |> json_response(200)

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 90_000
           } = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  test "returns the specified invalid batch and operation errors", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_batch"}} =
             conn |> json_post("/api/v1/partner-batches", %{}) |> json_response(422)

    response =
      conn
      |> json_post("/api/v1/partner-batches", %{
        operations: [
          %{operation_id: "unknown", type: "something_else"},
          %{operation_id: "missing-group", type: "record_cash_payment", occurred_on: "2026-01-01"}
        ]
      })
      |> json_response(200)

    assert response["results"] == [
             %{
               "operation_id" => "unknown",
               "status" => "rejected",
               "code" => "invalid_operation"
             },
             %{
               "operation_id" => "missing-group",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
           ]
  end
end
