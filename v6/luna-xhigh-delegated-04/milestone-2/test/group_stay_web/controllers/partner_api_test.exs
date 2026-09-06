defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

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
          %{"room_id" => "room-a", "nightly_rate_cents" => 101},
          %{"room_id" => "room-b", "nightly_rate_cents" => 99}
        ]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "opens a group with per-room deposits and preserves room order", %{conn: conn} do
    response = post_batch(conn, [open_operation()])

    assert %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 120,
             "revision" => 1
           } = json_response(response, 200)["results"] |> hd()

    assert %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 101},
               %{"room_id" => "room-b", "nightly_rate_cents" => 99}
             ],
             "lodging_total_cents" => 600,
             "deposit_due_cents" => 120,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 120,
             "revision" => 1
           } = json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "applies ordered updates, shifts dates, and refunds eligible cash", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation(),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 120
        },
        %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20"
        },
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-81"
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    assert Enum.at(results, 1)["outstanding_deposit_cents"] == 0
    assert Enum.at(results, 2)["new_departure_on"] == "2026-12-23"
    assert Enum.at(results, 3)["refunded_cents"] == 120
    assert Enum.at(results, 3)["retained_cents"] == 0

    assert json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]
           |> Map.take(["status", "outstanding_deposit_cents", "revision"]) == %{
             "status" => "cancelled",
             "outstanding_deposit_cents" => 0,
             "revision" => 4
           }

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 120,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "rejects stale updates before domain validation and continues the batch", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation(),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 20
        },
        %{
          "operation_id" => "stale-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "pay-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 10,
          "expected_revision" => 2
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 2) == %{
             "operation_id" => "stale-pay",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert Enum.at(results, 3)["status"] == "applied"
    assert Enum.at(results, 3)["revision"] == 3

    assert json_response(get(conn, "/api/v1/groups/group-81"), 200)["data"]["deposit_paid_cents"] ==
             30
  end

  test "keeps rejected operations isolated and reports specified domain errors", %{conn: conn} do
    results =
      post_batch(conn, [
        %{
          "operation_id" => "bad-open",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => "bad-group",
          "guest_id" => "guest-1",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 100}
          ]
        },
        open_operation(%{"operation_id" => "good-open"}),
        %{
          "operation_id" => "too-much",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 121
        },
        %{
          "operation_id" => "unknown",
          "type" => "mystery",
          "occurred_on" => "2026-10-04"
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 0)["code"] == "invalid_rooms"
    assert Enum.at(results, 1)["status"] == "applied"
    assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 3)["code"] == "invalid_operation"

    assert json_response(get(conn, "/api/v1/groups/bad-group"), 404)["error"] == %{
             "code" => "group_not_found"
           }
  end

  test "handles advance purchase retention, inactive groups, and invalid batches", %{conn: conn} do
    assert json_response(post(conn, "/api/v1/partner-batches", %{}), 422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    results =
      post_batch(conn, [
        open_operation(%{"rate_plan" => "advance_purchase"}),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 600
        },
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-01",
          "group_id" => "group-81"
        },
        %{
          "operation_id" => "pay-2",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 1
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 0)["deposit_due_cents"] == 600
    assert Enum.at(results, 2)["retained_cents"] == 600
    assert Enum.at(results, 3)["code"] == "group_not_active"

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 600,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "rejects malformed operation entries without aborting the batch", %{conn: conn} do
    results =
      post_batch(conn, [
        nil,
        %{"operation_id" => "missing-type"},
        %{
          "operation_id" => "missing-group",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 1
        },
        open_operation()
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.map(results, & &1["code"]) == [
             "invalid_operation",
             "invalid_operation",
             "invalid_operation",
             nil
           ]

    assert Enum.at(results, 3)["status"] == "applied"
  end
end
