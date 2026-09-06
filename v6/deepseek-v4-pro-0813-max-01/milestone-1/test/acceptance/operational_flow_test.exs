defmodule GroupStay.OperationalFlowAcceptanceTest do
  use GroupStayWeb.ConnCase

  test "the full onboarding flow: open, fund, move, and cancel a group through the API" do
    conn = Phoenix.ConnTest.build_conn()

    # A partner gateway opens a group reservation.
    conn =
      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "batch-1-open",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => "group-flow",
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
        ]
      })

    assert Jason.decode!(conn.resp_body)["results"] == [
             %{
               "operation_id" => "batch-1-open",
               "status" => "applied",
               "group_id" => "group-flow",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    # The gateway funds part of the deposit and a stale follow-up is rejected.
    conn =
      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "batch-2-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-flow",
            "amount_cents" => 10_000
          },
          %{
            "operation_id" => "batch-2-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-flow",
            "amount_cents" => 500,
            "expected_revision" => 1
          }
        ]
      })

    assert Jason.decode!(conn.resp_body)["results"] == [
             %{
               "operation_id" => "batch-2-pay",
               "status" => "applied",
               "group_id" => "group-flow",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             },
             %{
               "operation_id" => "batch-2-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-flow",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
           ]

    # The stay is moved without changing its length or price.
    conn =
      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "batch-3-move",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-flow",
            "new_arrival_on" => "2027-01-05"
          }
        ]
      })

    assert Jason.decode!(conn.resp_body)["results"] == [
             %{
               "operation_id" => "batch-3-move",
               "status" => "applied",
               "group_id" => "group-flow",
               "new_arrival_on" => "2027-01-05",
               "new_departure_on" => "2027-01-08",
               "revision" => 3
             }
           ]

    # The full picture is readable from the read endpoints.
    group = conn |> get("/api/v1/groups/group-flow") |> json_response(200) |> Map.fetch!("data")

    assert %{
             "group_id" => "group-flow",
             "status" => "active",
             "revision" => 3,
             "arrival_on" => "2027-01-05",
             "departure_on" => "2027-01-08",
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 10_000,
             "outstanding_deposit_cents" => 9_500
           } = group

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 10_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    # Cancelling four days before the moved arrival keeps the money.
    conn =
      post(conn, "/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "batch-4-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-01",
            "group_id" => "group-flow"
          }
        ]
      })

    assert Jason.decode!(conn.resp_body)["results"] == [
             %{
               "operation_id" => "batch-4-cancel",
               "status" => "applied",
               "group_id" => "group-flow",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "revision" => 4
             }
           ]

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 10_000
           }

    group = conn |> get("/api/v1/groups/group-flow") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["revision"] == 4

    assert group["rooms"] == [
             %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
             %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
           ]
  end
end
