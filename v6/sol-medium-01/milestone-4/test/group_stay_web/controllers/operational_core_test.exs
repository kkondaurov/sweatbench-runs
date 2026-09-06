defmodule GroupStayWeb.OperationalCoreTest do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  test "opens a group and returns its rooms and calculated totals", %{conn: conn} do
    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "operation_id" => "open-1",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]
           } = post_operations(conn, [open_operation()])

    data =
      conn
      |> recycle()
      |> get(~p"/api/v1/groups/group-81")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data == %{
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
                 "nightly_rate_cents" => 15_000,
                 "status" => "active",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }
  end

  test "processes operations in order and preserves prior successes around rejections", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 20_000,
        "expected_revision" => 2
      },
      %{
        "operation_id" => "pay-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 2_000,
        "expected_revision" => 2
      }
    ]

    assert %{"results" => [opened, paid, rejected, paid_again]} =
             post_operations(conn, operations)

    assert opened["revision"] == 1

    assert paid == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_500,
             "revision" => 2
           }

    assert rejected == %{
             "operation_id" => "too-much",
             "status" => "rejected",
             "code" => "payment_exceeds_outstanding",
             "group_id" => "group-81"
           }

    assert paid_again["revision"] == 3
    assert paid_again["outstanding_deposit_cents"] == 12_500
  end

  test "stale revisions take precedence and do not change group or ledger", %{conn: conn} do
    post_operations(conn, [open_operation()])

    result =
      post_operations(recycle(conn), [
        %{
          "operation_id" => "stale",
          "type" => "record_cash_payment",
          "occurred_on" => "bad-date",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 99
        }
      ])

    assert result == %{
             "results" => [
               %{
                 "operation_id" => "stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ]
           }

    group = get(recycle(conn), ~p"/api/v1/groups/group-81") |> json_response(200)
    assert group["data"]["revision"] == 1
    assert group["data"]["deposit_paid_cents"] == 0
    assert get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) == ledger(0, 0, 0)
  end

  test "resolves group existence before checking an expected revision", %{conn: conn} do
    assert %{
             "results" => [
               %{
                 "operation_id" => "missing",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "does-not-exist"
               }
             ]
           } =
             post_operations(conn, [
               %{
                 "operation_id" => "missing",
                 "type" => "cancel_group",
                 "group_id" => "does-not-exist",
                 "expected_revision" => 44
               }
             ])
  end

  test "reschedules by preserving stay length and increments revision", %{conn: conn} do
    post_operations(conn, [open_operation()])

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2027-01-05",
                 "new_departure_on" => "2027-01-08",
                 "revision" => 2
               }
             ]
           } =
             post_operations(recycle(conn), [
               %{
                 "operation_id" => "move-1",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-01-05"
               }
             ])
  end

  test "refundable cancellation moves held cash to refunded and deactivates group", %{conn: conn} do
    post_operations(conn, [
      open_operation(),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 10_000
      }
    ])

    assert get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) == ledger(10_000, 0, 0)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "refunded_cents" => 10_000,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ]
           } =
             post_operations(recycle(conn), [
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-26",
                 "group_id" => "group-81"
               }
             ])

    assert get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) == ledger(0, 10_000, 0)

    group = get(recycle(conn), ~p"/api/v1/groups/group-81") |> json_response(200)
    assert group["data"]["status"] == "cancelled"
    assert group["data"]["outstanding_deposit_cents"] == 0

    assert %{"results" => [%{"code" => "group_not_active"}]} =
             post_operations(recycle(conn), [
               %{
                 "operation_id" => "again",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-27",
                 "group_id" => "group-81"
               }
             ])
  end

  test "late flexible and advance-purchase cancellations retain cash", %{conn: conn} do
    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 1_001}]
      })

    post_operations(conn, [
      open_operation(),
      payment("group-81", 1_000),
      advance,
      payment("advance", 1_000, "pay-advance"),
      cancellation("group-81", "2026-11-27", "cancel-late"),
      cancellation("advance", "2026-10-05", "cancel-advance")
    ])

    assert get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) == ledger(0, 0, 2_000)
  end

  test "treats exactly fourteen days as refundable", %{conn: conn} do
    post_operations(conn, [
      open_operation(),
      payment("group-81", 1_000),
      cancellation("group-81", "2026-11-26", "boundary")
    ])

    assert get(recycle(conn), ~p"/api/v1/ledger") |> json_response(200) == ledger(0, 1_000, 0)
  end

  test "calculates flexible deposits per room before summing", %{conn: conn} do
    operation =
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 2},
          %{"room_id" => "room-b", "nightly_rate_cents" => 2}
        ]
      })

    assert %{"results" => [%{"deposit_due_cents" => 0}]} =
             post_operations(conn, [operation])
  end

  test "rejects invalid opens and malformed operations without leaving records", %{conn: conn} do
    duplicate_rooms =
      open_operation(%{
        "operation_id" => "bad-rooms",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 100},
          %{"room_id" => "same", "nightly_rate_cents" => 200}
        ]
      })

    assert %{"results" => results} =
             post_operations(conn, [
               duplicate_rooms,
               open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
               open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "mystery"}),
               %{"operation_id" => "unknown", "type" => "dance_group"},
               "not-an-operation"
             ])

    assert Enum.map(results, & &1["code"]) == [
             "invalid_rooms",
             "invalid_stay",
             "invalid_rate_plan",
             "invalid_operation",
             "invalid_operation"
           ]

    assert get(recycle(conn), ~p"/api/v1/groups/group-81") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "rejects an invalid batch with 422", %{conn: conn} do
    assert conn
           |> post(~p"/api/v1/partner-batches", %{"wrong" => []})
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
  end

  defp payment(group_id, amount, operation_id \\ "pay") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancellation(group_id, occurred_on, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp ledger(held, refunded, retained) do
    %{
      "data" => %{
        "cash_held_cents" => held,
        "cash_refunded_cents" => refunded,
        "cash_retained_cents" => retained,
        "cash_converted_to_credit_cents" => 0,
        "cash_reduced_cents" => 0,
        "cash_charged_back_cents" => 0,
        "credit_liability_cents" => 0,
        "credit_shortfall_cents" => 0
      }
    }
  end
end
