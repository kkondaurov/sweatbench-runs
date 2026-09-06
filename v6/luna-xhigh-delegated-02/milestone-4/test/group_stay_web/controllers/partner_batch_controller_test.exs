defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

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
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  test "opens a group, preserves room order, and reads the group", %{conn: conn} do
    response = json_post(conn, %{"operations" => [open_operation()]})

    assert %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 9_000,
                 "revision" => 1
               }
             ]
           } = json_response(response, 200)

    group = get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)

    assert group["data"] == %{
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
                 "lodging_total_cents" => 45_000,
                 "deposit_due_cents" => 9_000,
                 "status" => "active",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 45_000,
             "deposit_due_cents" => 9_000,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 9_000
           }
  end

  test "processes operations in order and continues after a rejection", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 3_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "pay-too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 7_000,
        "expected_revision" => 2
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-06",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20",
        "expected_revision" => 2
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "expected_revision" => 3
      },
      %{
        "operation_id" => "pay-after-cancel",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-12-02",
        "group_id" => "group-81",
        "amount_cents" => 1,
        "expected_revision" => 4
      },
      %{
        "operation_id" => "move-after-cancel",
        "type" => "reschedule_group",
        "occurred_on" => "2026-12-02",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-25",
        "expected_revision" => 4
      },
      %{
        "operation_id" => "cancel-after-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-02",
        "group_id" => "group-81",
        "expected_revision" => 4
      }
    ]

    assert %{"results" => results} =
             json_post(conn, %{"operations" => operations}) |> json_response(200)

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "applied",
             "rejected",
             "applied",
             "applied",
             "rejected",
             "rejected",
             "rejected"
           ]

    assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 3)["new_departure_on"] == "2026-12-23"
    assert Enum.at(results, 4)["refunded_cents"] == 3_000
    assert Enum.at(results, 4)["retained_cents"] == 0
    assert Enum.at(results, 4)["revision"] == 4
    assert Enum.at(results, 5)["code"] == "group_not_active"
    assert Enum.at(results, 6)["code"] == "group_not_active"
    assert Enum.at(results, 7)["code"] == "group_not_active"

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 3_000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "calculates flexible deposits per room and keeps invalid operations isolated", %{
    conn: conn
  } do
    open =
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 3},
          %{"room_id" => "room-b", "nightly_rate_cents" => 3}
        ]
      })

    invalid = %{
      "operation_id" => "bad-rooms",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-bad",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "same", "nightly_rate_cents" => 1},
        %{"room_id" => "same", "nightly_rate_cents" => 2}
      ]
    }

    assert %{"results" => [applied, rejected]} =
             json_post(conn, %{"operations" => [open, invalid]}) |> json_response(200)

    assert applied["deposit_due_cents"] == 2
    assert rejected["code"] == "invalid_rooms"

    assert get(build_conn(), "/api/v1/groups/group-bad") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "stale revisions are checked before other domain validation", %{conn: conn} do
    assert json_post(conn, %{"operations" => [open_operation()]}) |> json_response(200)

    stale = %{
      "operation_id" => "stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => -1,
      "expected_revision" => 0
    }

    missing = %{
      "operation_id" => "missing",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "missing-group",
      "amount_cents" => 1,
      "expected_revision" => 0
    }

    assert %{"results" => [stale_result, missing_result]} =
             json_post(conn, %{"operations" => [stale, missing]}) |> json_response(200)

    assert stale_result == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert missing_result["code"] == "group_not_found"

    null_revision = %{
      "operation_id" => "null-revision",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 1,
      "expected_revision" => nil
    }

    assert %{"results" => [result]} =
             json_post(conn, %{"operations" => [null_revision]}) |> json_response(200)

    assert result == %{
             "operation_id" => "null-revision",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => nil,
             "actual_revision" => 1
           }
  end

  test "invalid batches return 422 and cancelled deposits settle the ledger", %{conn: conn} do
    assert json_post(conn, %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert json_post(conn, %{
             "operations" => [open_operation(%{"rate_plan" => "advance_purchase"})]
           })
           |> json_response(200)

    assert json_post(conn, %{
             "operations" => [
               %{
                 "operation_id" => "pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81",
                 "amount_cents" => 2_000
               },
               %{
                 "operation_id" => "cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "group-81"
               }
             ]
           })
           |> json_response(200)

    assert %{"data" => ledger} = get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 2_000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "flexible cancellation exactly fourteen days before arrival is refundable", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }
    ]

    assert %{"results" => [_, payment, cancellation]} =
             json_post(conn, %{"operations" => operations}) |> json_response(200)

    assert payment["revision"] == 2
    assert cancellation["refunded_cents"] == 1_000
    assert cancellation["retained_cents"] == 0
  end
end
