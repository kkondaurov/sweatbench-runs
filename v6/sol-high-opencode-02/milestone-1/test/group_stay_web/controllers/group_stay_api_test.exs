defmodule GroupStayWeb.GroupStayApiTest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects an invalid batch", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{"not_operations" => []})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})
    end

    test "opens and reads a flexible group with room-level deposit rounding", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_001},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10_001}
          ]
        })

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 12_002,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-1",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 10_001},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 10_001}
                 ],
                 "lodging_total_cents" => 60_006,
                 "deposit_due_cents" => 12_002,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 12_002
               }
             } = json_response(conn, 200)
    end

    test "processes payments, moves, and cancellation in order", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1",
          "amount_cents" => 10_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-10",
          "group_id" => "group-1",
          "expected_revision" => 3
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [opened, paid, moved, cancelled]} = json_response(conn, 200)
      assert opened["revision"] == 1

      assert paid == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 2_000,
               "revision" => 2
             }

      assert moved == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 3
             }

      assert cancelled == %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "revision" => 4
             }

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 10_000
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_paid_cents" => 10_000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             } = get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end

    test "refunds flexible cash at least fourteen days before arrival", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(12_000),
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-1"
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, _, cancellation]} = json_response(conn, 200)
      assert cancellation["refunded_cents"] == 12_000
      assert cancellation["retained_cents"] == 0

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 12_000,
                 "cash_retained_cents" => 0
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "always retains advance-purchase cash", %{conn: conn} do
      operations = [
        open_operation(%{"rate_plan" => "advance_purchase"}),
        payment_operation(60_000),
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1"
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, _, cancellation]} = json_response(conn, 200)
      assert cancellation["refunded_cents"] == 0
      assert cancellation["retained_cents"] == 60_000
    end

    test "checks a stale revision before domain validation and continues the batch", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(2_000),
        %{
          "operation_id" => "stale-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "amount_cents" => -1,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "good-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "amount_cents" => 1_000,
          "expected_revision" => 2
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, _, stale, applied]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "stale-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert applied["status"] == "applied"
      assert applied["revision"] == 3

      assert %{"data" => %{"deposit_paid_cents" => 3_000, "revision" => 3}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end

    test "compares reschedule dates chronologically across month boundaries", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "move-past",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-11-30"
        },
        %{
          "operation_id" => "move-future",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-31",
          "group_id" => "group-1",
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 1
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, rejected, applied]} = json_response(conn, 200)
      assert rejected["code"] == "invalid_stay"
      assert applied["status"] == "applied"
      assert applied["new_arrival_on"] == "2027-01-01"
      assert applied["new_departure_on"] == "2027-01-04"
      assert applied["revision"] == 2
    end

    test "rejects operations after cancellation without changing the revision", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-1"
        },
        Map.put(payment_operation(1), "operation_id", "late-payment"),
        %{
          "operation_id" => "late-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-1",
          "new_arrival_on" => "2027-01-01"
        },
        %{
          "operation_id" => "late-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-02",
          "group_id" => "group-1"
        }
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, cancellation, payment, move, second_cancellation]} =
               json_response(conn, 200)

      assert cancellation["revision"] == 2
      assert payment["code"] == "group_not_active"
      assert move["code"] == "group_not_active"
      assert second_cancellation["code"] == "group_not_active"

      assert %{"data" => %{"revision" => 2}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end

    test "reports held cash and rejects unusable payment amounts", %{conn: conn} do
      operations = [open_operation(), payment_operation(2_500), payment_operation(0)]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, applied, rejected]} = json_response(conn, 200)
      assert applied["status"] == "applied"
      assert rejected["code"] == "invalid_amount"

      assert %{
               "data" => %{
                 "cash_held_cents" => 2_500,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "rejects monetary values that cannot be persisted and continues", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [
            %{
              "room_id" => "too-expensive",
              "nightly_rate_cents" => 9_223_372_036_854_775_808
            }
          ]
        })

      conn =
        post(conn, "/api/v1/partner-batches", %{
          "operations" => [operation, open_operation(%{"group_id" => "group-2"})]
        })

      assert %{"results" => [rejected, applied]} = json_response(conn, 200)
      assert rejected["code"] == "invalid_rooms"
      assert applied["status"] == "applied"
      assert applied["group_id"] == "group-2"
    end

    test "resolves group existence before revisions", %{conn: conn} do
      operation = %{
        "operation_id" => "pay-missing",
        "type" => "record_cash_payment",
        "occurred_on" => "not-a-date",
        "group_id" => "missing",
        "amount_cents" => -1,
        "expected_revision" => "bad"
      }

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "pay-missing",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects invalid operations without changing prior state", %{conn: conn} do
      operations = [
        open_operation(),
        Map.put(open_operation(), "operation_id", "duplicate"),
        payment_operation(12_001),
        Map.put(payment_operation(1), "operation_id", "valid-payment"),
        %{"operation_id" => "unknown", "type" => "mystery", "occurred_on" => "2026-01-01"}
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => [_, duplicate, excessive, valid, unknown]} = json_response(conn, 200)
      assert duplicate["code"] == "group_already_exists"
      assert excessive["code"] == "payment_exceeds_outstanding"
      assert valid["revision"] == 2
      assert unknown["code"] == "invalid_operation"

      assert %{"data" => %{"deposit_paid_cents" => 1, "revision" => 2}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end

    test "uses stable validation codes", %{conn: conn} do
      invalid_openings = [
        open_operation(%{
          "operation_id" => "bad-stay",
          "departure_on" => "2026-12-10",
          "group_id" => "bad-stay"
        }),
        open_operation(%{
          "operation_id" => "bad-rooms",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 1},
            %{"room_id" => "same", "nightly_rate_cents" => 2}
          ],
          "group_id" => "bad-rooms"
        }),
        open_operation(%{
          "operation_id" => "bad-rate",
          "rate_plan" => "unknown",
          "group_id" => "bad-rate"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => invalid_openings})

      assert %{"results" => [stay, rooms, rate]} = json_response(conn, 200)
      assert stay["code"] == "invalid_stay"
      assert rooms["code"] == "invalid_rooms"
      assert rate["code"] == "invalid_rate_plan"

      assert response(get(build_conn(), "/api/v1/groups/bad-stay"), 404) ==
               ~s({"error":{"code":"group_not_found"}})
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the documented not-found error", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/groups/missing"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
        ]
      },
      overrides
    )
  end

  defp payment_operation(amount) do
    %{
      "operation_id" => "pay-1",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
  end
end
