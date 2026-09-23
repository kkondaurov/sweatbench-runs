defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
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
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  test "opens and reads a group with totals and rooms in partner order", %{conn: conn} do
    assert [result] = submit(conn, [open_operation()])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19_500,
             "revision" => 1
           }

    response =
      conn
      |> get("/api/v1/groups/group-81")
      |> json_response(200)

    assert response["data"] == %{
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
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }
  end

  test "calculates flexible deposits per room and requires full advance purchase deposits", %{
    conn: conn
  } do
    flexible =
      open_operation(%{
        "group_id" => "rounding-group",
        "rooms" => [
          %{"room_id" => "one", "nightly_rate_cents" => 3},
          %{"room_id" => "two", "nightly_rate_cents" => 3}
        ],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11"
      })

    advance =
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "advance-group",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 12_345}]
      })

    assert [%{"deposit_due_cents" => 2}, %{"deposit_due_cents" => 37_035}] =
             submit(conn, [flexible, advance])

    payment = %{
      "operation_id" => "advance-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "advance-group",
      "amount_cents" => 100
    }

    cancel = %{
      "operation_id" => "advance-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => "advance-group"
    }

    assert [_, %{"refunded_cents" => 0, "retained_cents" => 100}] =
             submit(conn, [payment, cancel])
  end

  test "domain rejections leave revisions unchanged and later operations still apply", %{
    conn: conn
  } do
    invalid_stay =
      open_operation(%{
        "operation_id" => "bad-stay",
        "group_id" => "bad-stay-group",
        "departure_on" => "2026-12-10"
      })

    invalid_rate_plan =
      open_operation(%{
        "operation_id" => "bad-rate",
        "group_id" => "bad-rate-group",
        "rate_plan" => "unknown"
      })

    duplicate = open_operation(%{"operation_id" => "duplicate", "rate_plan" => "unknown"})

    invalid_payment = %{
      "operation_id" => "invalid-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 0
    }

    excessive_payment =
      Map.merge(invalid_payment, %{"operation_id" => "too-much", "amount_cents" => 19_501})

    rejected_move = %{
      "operation_id" => "bad-move",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "new_arrival_on" => "2026-10-03"
    }

    assert [
             %{"code" => "invalid_stay"},
             %{"code" => "invalid_rate_plan"},
             %{"status" => "applied", "revision" => 1},
             %{"code" => "group_already_exists"},
             %{"code" => "invalid_amount"},
             %{"code" => "payment_exceeds_outstanding"},
             %{"code" => "invalid_stay"},
             %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 0}
           ] =
             submit(conn, [
               invalid_stay,
               invalid_rate_plan,
               open_operation(),
               duplicate,
               invalid_payment,
               excessive_payment,
               rejected_move,
               Map.merge(invalid_payment, %{"operation_id" => "pay-all", "amount_cents" => 19_500})
             ])

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 19_500}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "processes operations in order and checks revisions before other validation", %{conn: conn} do
    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }

    stale_invalid_payment = %{
      "operation_id" => "pay-stale",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "expected_revision" => 1,
      "amount_cents" => -1
    }

    missing_group = %{
      "operation_id" => "missing",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "absent",
      "expected_revision" => 999
    }

    assert [
             %{"status" => "applied", "revision" => 1},
             %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 14_500},
             %{
               "status" => "rejected",
               "code" => "stale_revision",
               "expected_revision" => 1,
               "actual_revision" => 2,
               "group_id" => "group-81"
             },
             %{"status" => "rejected", "code" => "group_not_found"},
             %{"status" => "applied", "revision" => 3}
           ] =
             submit(conn, [
               open_operation(),
               payment,
               stale_invalid_payment,
               missing_group,
               Map.merge(payment, %{
                 "operation_id" => "pay-2",
                 "expected_revision" => 2,
                 "amount_cents" => 1_000
               })
             ])

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 6_000}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "reschedules the stay without changing its length or price", %{conn: conn} do
    reschedule = %{
      "operation_id" => "move-1",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "new_arrival_on" => "2026-12-20"
    }

    assert [
             _,
             %{
               "status" => "applied",
               "revision" => 2,
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23"
             }
           ] =
             submit(conn, [open_operation(), reschedule])

    assert %{"data" => %{"lodging_total_cents" => 97_500, "revision" => 2}} =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)
  end

  test "cancellation settles paid cash and clears the outstanding deposit", %{conn: conn} do
    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }

    cancel = %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-30",
      "group_id" => "group-81"
    }

    assert [
             _,
             _,
             %{
               "status" => "applied",
               "revision" => 3,
               "refunded_cents" => 0,
               "retained_cents" => 5_000
             }
           ] =
             submit(conn, [open_operation(), payment, cancel])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000
             }
           } =
             conn |> get("/api/v1/ledger") |> json_response(200)

    assert %{
             "data" => %{
               "status" => "cancelled",
               "outstanding_deposit_cents" => 0,
               "deposit_paid_cents" => 5_000
             }
           } =
             conn |> get("/api/v1/groups/group-81") |> json_response(200)

    assert [%{"status" => "rejected", "code" => "group_not_active"}] =
             submit(conn, [%{payment | "operation_id" => "pay-late", "amount_cents" => 1}])
  end

  test "refunds flexible cash at the fourteen day threshold and rejects invalid operations", %{
    conn: conn
  } do
    payment = %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }

    cancel = %{
      "operation_id" => "cancel-1",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-26",
      "group_id" => "group-81"
    }

    bad_room_group =
      open_operation(%{
        "operation_id" => "open-bad",
        "group_id" => "bad-room-group",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 2}
        ]
      })

    unknown = %{"operation_id" => "unknown", "type" => "mystery"}

    assert [
             _,
             _,
             %{"status" => "applied", "refunded_cents" => 5_000, "retained_cents" => 0},
             %{"status" => "rejected", "code" => "invalid_rooms"},
             %{"status" => "rejected", "code" => "invalid_operation"}
           ] =
             submit(conn, [open_operation(), payment, cancel, bad_room_group, unknown])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           } =
             conn |> get("/api/v1/ledger") |> json_response(200)

    assert %{"error" => %{"code" => "group_not_found"}} =
             conn |> get("/api/v1/groups/bad-room-group") |> json_response(404)
  end

  test "returns invalid_batch when operations is not an array", %{conn: conn} do
    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => %{}}))
      |> json_response(422)

    assert response == %{"error" => %{"code" => "invalid_batch"}}

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/api/v1/partner-batches", Jason.encode!(%{}))
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
  end
end
