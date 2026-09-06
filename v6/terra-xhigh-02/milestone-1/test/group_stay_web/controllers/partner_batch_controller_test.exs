defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  test "opens, funds, moves, and cancels a group while reporting its finance state", %{conn: conn} do
    open =
      open_group_operation("open-1", "group-1", "2026-10-03", %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
        ]
      })

    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open]})

    assert %{"results" => [open_result]} = json_response(conn, 200)

    assert open_result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-1",
             "deposit_due_cents" => 19_502,
             "revision" => 1
           }

    conn =
      build_conn()
      |> post(~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 5_000,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "move-1",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-12-20",
            "expected_revision" => 2
          },
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-06",
            "group_id" => "group-1",
            "expected_revision" => 3
          }
        ]
      })

    assert %{"results" => results} = json_response(conn, 200)

    assert results == [
             %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_502,
               "revision" => 2
             },
             %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 3
             },
             %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 5_000,
               "retained_cents" => 0,
               "revision" => 4
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/groups/group-1")

    assert %{"data" => group} = json_response(conn, 200)

    assert group == %{
             "group_id" => "group-1",
             "guest_id" => "guest-1",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-20",
             "departure_on" => "2026-12-23",
             "rate_plan" => "flexible",
             "status" => "cancelled",
             "revision" => 4,
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
             ],
             "lodging_total_cents" => 97_509,
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           }
  end

  test "keeps successful operations when a later operation is rejected", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-1", "group-1", "2026-10-03"),
          %{
            "operation_id" => "too-much",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 6_001
          },
          %{
            "operation_id" => "pay-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 6_000
          }
        ]
      })

    assert %{"results" => [open, rejected, payment]} = json_response(conn, 200)
    assert open["status"] == "applied"

    assert rejected == %{
             "operation_id" => "too-much",
             "status" => "rejected",
             "code" => "payment_exceeds_outstanding"
           }

    assert payment == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-1",
             "amount_cents" => 6_000,
             "outstanding_deposit_cents" => 0,
             "revision" => 2
           }

    conn = get(build_conn(), ~p"/api/v1/ledger")
    assert json_response(conn, 200)["data"]["cash_held_cents"] == 6_000
  end

  test "checks group existence and revision before domain validation", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open_group_operation()]})
    assert json_response(conn, 200)["results"] |> hd() |> Map.fetch!("revision") == 1

    conn =
      build_conn()
      |> post(~p"/api/v1/partner-batches", %{
        "operations" => [
          %{
            "operation_id" => "stale-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "not-a-date",
            "group_id" => "group-1",
            "amount_cents" => -1,
            "expected_revision" => 0
          },
          %{
            "operation_id" => "missing-group",
            "type" => "cancel_group",
            "occurred_on" => "not-a-date",
            "group_id" => "missing-group",
            "expected_revision" => 1
          }
        ]
      })

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-pay",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "missing-group",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           }
  end

  test "retains late flexible cash and always retains advance-purchase cash", %{conn: conn} do
    advance_purchase =
      open_group_operation("open-advance", "advance-group", "2026-10-03", %{
        "rate_plan" => "advance_purchase"
      })

    conn =
      post(conn, ~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("open-flex", "flex-group", "2026-10-03"),
          %{
            "operation_id" => "pay-flex",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "flex-group",
            "amount_cents" => 6_000
          },
          %{
            "operation_id" => "cancel-flex",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "flex-group"
          },
          advance_purchase,
          %{
            "operation_id" => "pay-advance",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "advance-group",
            "amount_cents" => 30_000
          },
          %{
            "operation_id" => "cancel-advance",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "advance-group"
          }
        ]
      })

    assert %{"results" => results} = json_response(conn, 200)

    assert Enum.map(
             results,
             &Map.take(&1, ["operation_id", "status", "refunded_cents", "retained_cents"])
           ) == [
             %{"operation_id" => "open-flex", "status" => "applied"},
             %{"operation_id" => "pay-flex", "status" => "applied"},
             %{
               "operation_id" => "cancel-flex",
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 6_000
             },
             %{"operation_id" => "open-advance", "status" => "applied"},
             %{"operation_id" => "pay-advance", "status" => "applied"},
             %{
               "operation_id" => "cancel-advance",
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 30_000
             }
           ]

    conn = get(build_conn(), ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 36_000
             }
           }
  end

  test "returns stable validation errors and invalid batch responses", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/partner-batches", %{})
    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

    conn =
      build_conn()
      |> post(~p"/api/v1/partner-batches", %{
        "operations" => [
          open_group_operation("bad-stay", "bad-stay", "2026-10-03", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          }),
          open_group_operation("bad-rooms", "bad-rooms", "2026-10-03", %{"rooms" => []}),
          open_group_operation("bad-plan", "bad-plan", "2026-10-03", %{"rate_plan" => "weekend"}),
          %{"operation_id" => "unknown", "type" => "dance", "occurred_on" => "2026-10-03"}
        ]
      })

    assert json_response(conn, 200)["results"] == [
             %{"operation_id" => "bad-stay", "status" => "rejected", "code" => "invalid_stay"},
             %{"operation_id" => "bad-rooms", "status" => "rejected", "code" => "invalid_rooms"},
             %{
               "operation_id" => "bad-plan",
               "status" => "rejected",
               "code" => "invalid_rate_plan"
             },
             %{"operation_id" => "unknown", "status" => "rejected", "code" => "invalid_operation"}
           ]

    conn = get(build_conn(), ~p"/api/v1/groups/no-such-group")
    assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  defp open_group_operation(
         operation_id \\ "open-1",
         group_id \\ "group-1",
         occurred_on \\ "2026-10-03",
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end
end
