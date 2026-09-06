defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = submit_body(conn, %{"operations" => %{}})

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "opens a group, uses per-room deposit rounding, and exposes the group", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 103},
              %{"room_id" => "room-b", "nightly_rate_cents" => 103}
            ]
          })
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 42,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), ~p"/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-1",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-11",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 103},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 103}
                 ],
                 "lodging_total_cents" => 206,
                 "deposit_due_cents" => 42,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 42
               }
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "processes changes in array order and increments the revision for each applied operation",
         %{
           conn: conn
         } do
      conn =
        submit(conn, [
          open_group(),
          %{
            "operation_id" => "payment-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 60,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "reschedule-1",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-12-15",
            "expected_revision" => 2
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-1", "revision" => 1, "deposit_due_cents" => 200},
                 %{
                   "operation_id" => "payment-1",
                   "status" => "applied",
                   "amount_cents" => 60,
                   "outstanding_deposit_cents" => 140,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "reschedule-1",
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-15",
                   "new_departure_on" => "2026-12-17",
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 3,
                 "arrival_on" => "2026-12-15",
                 "departure_on" => "2026-12-17",
                 "deposit_paid_cents" => 60,
                 "outstanding_deposit_cents" => 140
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 60,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "rejects stale revisions before other validation and leaves state untouched", %{
      conn: conn
    } do
      submit(conn, [open_group()])

      conn =
        submit(build_conn(), [
          %{
            "operation_id" => "payment-1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 10
          },
          %{
            "operation_id" => "stale-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-1",
            "amount_cents" => 999,
            "expected_revision" => 1
          },
          %{
            "operation_id" => "missing-group",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "does-not-exist",
            "expected_revision" => 1
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "payment-1", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "stale-payment",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-1",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "missing-group",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "deposit_paid_cents" => 10,
                 "outstanding_deposit_cents" => 190
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 10,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "settles refundable and non-refundable cancellations and prevents later active-only work",
         %{
           conn: conn
         } do
      submit(conn, [open_group(), payment("payment-1", "group-1", 100)])

      conn =
        submit(build_conn(), [
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-1",
            "expected_revision" => 2
          },
          payment("payment-after-cancel", "group-1", 1),
          %{
            "operation_id" => "reschedule-after-cancel",
            "type" => "reschedule_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-12-20"
          },
          %{
            "operation_id" => "cancel-after-cancel",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-1"
          }
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-1",
                   "status" => "applied",
                   "refunded_cents" => 100,
                   "retained_cents" => 0,
                   "revision" => 3
                 },
                 %{"operation_id" => "payment-after-cancel", "code" => "group_not_active"},
                 %{"operation_id" => "reschedule-after-cancel", "code" => "group_not_active"},
                 %{"operation_id" => "cancel-after-cancel", "code" => "group_not_active"}
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 3,
                 "deposit_paid_cents" => 100,
                 "outstanding_deposit_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 0
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)

      conn =
        submit(build_conn(), [
          open_group(%{
            "operation_id" => "open-advance",
            "group_id" => "group-advance",
            "rate_plan" => "advance_purchase"
          }),
          payment("payment-advance", "group-advance", 500),
          %{
            "operation_id" => "cancel-advance",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-advance"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-advance", "deposit_due_cents" => 1_000},
                 %{"operation_id" => "payment-advance", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-advance",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 500
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 500
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)

      conn =
        submit(build_conn(), [
          open_group(%{
            "operation_id" => "open-late-flexible",
            "group_id" => "group-late-flexible"
          }),
          payment("payment-late-flexible", "group-late-flexible", 200),
          %{
            "operation_id" => "cancel-late-flexible",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-late-flexible"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "open-late-flexible", "status" => "applied"},
                 %{"operation_id" => "payment-late-flexible", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-late-flexible",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 200
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 700
               }
             } =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "rejects invalid operations without rolling back earlier work or blocking later work", %{
      conn: conn
    } do
      conn =
        submit(conn, [
          %{"operation_id" => "unknown", "type" => "mystery"},
          open_group(%{
            "operation_id" => "bad-stay",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-10"
          }),
          open_group(%{"operation_id" => "bad-date", "arrival_on" => "not-a-calendar-date"}),
          open_group(%{"operation_id" => "bad-rate-plan", "rate_plan" => "member-special"}),
          open_group(%{
            "operation_id" => "bad-rooms",
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 500},
              %{"room_id" => "room-a", "nightly_rate_cents" => 500}
            ]
          }),
          open_group(),
          %{
            "operation_id" => "missing-data",
            "type" => "record_cash_payment",
            "group_id" => "group-1"
          },
          open_group(%{"operation_id" => "duplicate", "group_id" => "group-1"}),
          %{
            "operation_id" => "too-much",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 201
          },
          %{
            "operation_id" => "zero-payment",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "amount_cents" => 0
          },
          %{
            "operation_id" => "invalid-reschedule",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1",
            "new_arrival_on" => "2026-10-04"
          },
          %{
            "operation_id" => "missing-reschedule-date",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-1"
          }
        ])

      assert %{
               "results" => [
                 %{"operation_id" => "unknown", "code" => "invalid_operation"},
                 %{"operation_id" => "bad-stay", "code" => "invalid_stay"},
                 %{"operation_id" => "bad-date", "code" => "invalid_stay"},
                 %{"operation_id" => "bad-rate-plan", "code" => "invalid_rate_plan"},
                 %{"operation_id" => "bad-rooms", "code" => "invalid_rooms"},
                 %{"operation_id" => "open-1", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "missing-data", "code" => "invalid_operation"},
                 %{"operation_id" => "duplicate", "code" => "group_already_exists"},
                 %{"operation_id" => "too-much", "code" => "payment_exceeds_outstanding"},
                 %{"operation_id" => "zero-payment", "code" => "invalid_amount"},
                 %{"operation_id" => "invalid-reschedule", "code" => "invalid_stay"},
                 %{"operation_id" => "missing-reschedule-date", "code" => "invalid_operation"}
               ]
             } = json_response(conn, 200)

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/groups/group-1") |> json_response(200)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the documented not-found response", %{conn: conn} do
      assert %{"error" => %{"code" => "group_not_found"}} =
               get(conn, ~p"/api/v1/groups/no-such-group") |> json_response(404)
    end
  end

  defp submit(conn, operations), do: submit_body(conn, %{"operations" => operations})

  defp submit_body(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_group(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
      },
      overrides
    )
  end

  defp payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
