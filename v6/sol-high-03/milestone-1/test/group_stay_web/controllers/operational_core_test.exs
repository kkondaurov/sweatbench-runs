defmodule GroupStayWeb.OperationalCoreTest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects an invalid batch envelope and accepts an empty batch", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => []})
      assert json_response(conn, 200) == %{"results" => []}
    end

    test "opens a flexible group and calculates each room before summing", %{conn: conn} do
      operation =
        open_operation(%{
          "group_id" => "rounding-group",
          "arrival_on" => "2026-11-10",
          "departure_on" => "2026-11-11",
          "rooms" => [
            %{"room_id" => "room-three-cents", "nightly_rate_cents" => 3},
            %{"room_id" => "room-four-cents", "nightly_rate_cents" => 4}
          ]
        })

      conn = post_batch(conn, [operation])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "rounding-group",
                   "deposit_due_cents" => 2,
                   "revision" => 1
                 }
               ]
             }

      conn = get(build_conn(), "/api/v1/groups/rounding-group")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "group_id" => "rounding-group",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-11-10",
                 "departure_on" => "2026-11-11",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "revision" => 1,
                 "rooms" => [
                   %{"room_id" => "room-three-cents", "nightly_rate_cents" => 3},
                   %{"room_id" => "room-four-cents", "nightly_rate_cents" => 4}
                 ],
                 "lodging_total_cents" => 7,
                 "deposit_due_cents" => 2,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 2
               }
             }
    end

    test "advance purchase requires the full multi-night lodging amount", %{conn: conn} do
      operation =
        open_operation(%{
          "group_id" => "advance-group",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        })

      conn = post_batch(conn, [operation])

      assert %{
               "results" => [
                 %{"deposit_due_cents" => 97_500, "revision" => 1, "status" => "applied"}
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/groups/advance-group")
      assert %{"data" => %{"lodging_total_cents" => 97_500}} = json_response(conn, 200)
    end

    test "processes operations in order and moves refundable cash through the ledger", %{
      conn: conn
    } do
      operations = [
        open_operation(%{
          "group_id" => "journey-group",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23"
        }),
        payment_operation(%{
          "operation_id" => "pay-1",
          "group_id" => "journey-group",
          "amount_cents" => 10_000,
          "expected_revision" => 1
        }),
        reschedule_operation(%{
          "operation_id" => "move-1",
          "group_id" => "journey-group",
          "occurred_on" => "2026-12-02",
          "new_arrival_on" => "2026-12-30",
          "expected_revision" => 2
        }),
        cancel_operation(%{
          "operation_id" => "cancel-1",
          "group_id" => "journey-group",
          "occurred_on" => "2026-12-16",
          "expected_revision" => 3
        })
      ]

      conn = post_batch(conn, operations)

      assert %{"results" => [opened, paid, moved, cancelled]} = json_response(conn, 200)
      assert opened["revision"] == 1

      assert paid == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "journey-group",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
               "revision" => 2
             }

      assert moved == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "journey-group",
               "new_arrival_on" => "2026-12-30",
               "new_departure_on" => "2027-01-02",
               "revision" => 3
             }

      assert cancelled == %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "journey-group",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 4
             }

      conn = get(build_conn(), "/api/v1/groups/journey-group")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 4,
                 "arrival_on" => "2026-12-30",
                 "departure_on" => "2027-01-02",
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 10_000,
                 "outstanding_deposit_cents" => 0
               }
             } = json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "rejects stale revisions before inactive state and domain validation", %{conn: conn} do
      setup_operations = [
        open_operation(%{"group_id" => "revision-group"}),
        payment_operation(%{
          "operation_id" => "pay-revision",
          "group_id" => "revision-group",
          "amount_cents" => 100,
          "expected_revision" => 1
        }),
        cancel_operation(%{
          "operation_id" => "cancel-revision",
          "group_id" => "revision-group",
          "occurred_on" => "2026-11-01",
          "expected_revision" => 2
        })
      ]

      assert %{"results" => [_, _, %{"revision" => 3}]} =
               conn |> post_batch(setup_operations) |> json_response(200)

      operations = [
        payment_operation(%{
          "operation_id" => "stale-invalid-pay",
          "group_id" => "revision-group",
          "amount_cents" => -1,
          "expected_revision" => 2
        }),
        payment_operation(%{
          "operation_id" => "current-invalid-pay",
          "group_id" => "revision-group",
          "amount_cents" => -1,
          "expected_revision" => 3
        }),
        payment_operation(%{
          "operation_id" => "missing-precedes-stale",
          "group_id" => "not-there",
          "amount_cents" => -1,
          "expected_revision" => 99
        })
      ]

      conn = post_batch(build_conn(), operations)
      assert %{"results" => [stale, inactive, missing]} = json_response(conn, 200)

      assert stale == %{
               "operation_id" => "stale-invalid-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "revision-group",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      assert inactive["code"] == "group_not_active"
      assert missing["code"] == "group_not_found"

      conn = get(build_conn(), "/api/v1/groups/revision-group")
      assert %{"data" => %{"revision" => 3}} = json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 100,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "rejects invalid and excessive payments without changing state, then continues", %{
      conn: conn
    } do
      operations = [
        open_operation(%{"group_id" => "payment-group"}),
        payment_operation(%{
          "operation_id" => "zero-pay",
          "group_id" => "payment-group",
          "amount_cents" => 0,
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "over-pay",
          "group_id" => "payment-group",
          "amount_cents" => 19_501,
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "exact-pay",
          "group_id" => "payment-group",
          "amount_cents" => 19_500,
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "paid-out-pay",
          "group_id" => "payment-group",
          "amount_cents" => 1,
          "expected_revision" => 2
        })
      ]

      conn = post_batch(conn, operations)
      assert %{"results" => [_, zero, over, exact, paid_out]} = json_response(conn, 200)
      assert zero["code"] == "invalid_amount"
      assert over["code"] == "payment_exceeds_outstanding"
      assert exact["revision"] == 2
      assert exact["outstanding_deposit_cents"] == 0
      assert paid_out["code"] == "payment_exceeds_outstanding"

      conn = get(build_conn(), "/api/v1/ledger")
      assert %{"data" => %{"cash_held_cents" => 19_500}} = json_response(conn, 200)
    end

    test "uses the current arrival and exact cutoff for cancellation settlement", %{conn: conn} do
      operations = [
        open_operation(%{"group_id" => "exact-cutoff"}),
        payment_operation(%{
          "operation_id" => "pay-exact",
          "group_id" => "exact-cutoff",
          "amount_cents" => 1_000
        }),
        cancel_operation(%{
          "operation_id" => "cancel-exact",
          "group_id" => "exact-cutoff",
          "occurred_on" => "2026-11-26"
        }),
        open_operation(%{"operation_id" => "open-late", "group_id" => "late-flex"}),
        payment_operation(%{
          "operation_id" => "pay-late",
          "group_id" => "late-flex",
          "amount_cents" => 2_000
        }),
        cancel_operation(%{
          "operation_id" => "cancel-late",
          "group_id" => "late-flex",
          "occurred_on" => "2026-11-27"
        }),
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance-cancel",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation(%{
          "operation_id" => "pay-advance",
          "group_id" => "advance-cancel",
          "amount_cents" => 3_000
        }),
        cancel_operation(%{
          "operation_id" => "cancel-advance",
          "group_id" => "advance-cancel",
          "occurred_on" => "2026-10-04"
        })
      ]

      conn = post_batch(conn, operations)
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 2)["refunded_cents"] == 1_000
      assert Enum.at(results, 5)["retained_cents"] == 2_000
      assert Enum.at(results, 8)["retained_cents"] == 3_000

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 1_000,
                 "cash_retained_cents" => 5_000
               }
             }
    end

    test "returns all opening validation codes without creating rejected groups", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "bad-stay",
          "group_id" => "bad-stay-group",
          "departure_on" => "2026-12-10"
        }),
        open_operation(%{
          "operation_id" => "bad-rooms",
          "group_id" => "bad-rooms-group",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        }),
        open_operation(%{
          "operation_id" => "bad-plan",
          "group_id" => "bad-plan-group",
          "rate_plan" => "breakfast_bonanza"
        }),
        Map.delete(open_operation(%{"operation_id" => "missing-data"}), "rooms"),
        open_operation(%{"operation_id" => "valid-after-errors", "group_id" => "survivor"}),
        open_operation(%{"operation_id" => "duplicate-group", "group_id" => "survivor"})
      ]

      conn = post_batch(conn, operations)

      assert %{"results" => [bad_stay, bad_rooms, bad_plan, invalid, applied, duplicate]} =
               json_response(conn, 200)

      assert bad_stay["code"] == "invalid_stay"
      assert bad_rooms["code"] == "invalid_rooms"
      assert bad_plan["code"] == "invalid_rate_plan"
      assert invalid["code"] == "invalid_operation"
      assert applied["status"] == "applied"
      assert duplicate["code"] == "group_already_exists"

      for group_id <- ~w(bad-stay-group bad-rooms-group bad-plan-group) do
        conn = get(build_conn(), "/api/v1/groups/#{group_id}")
        assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
      end
    end

    test "unknown, malformed, and missing-data operations do not stop later operations", %{
      conn: conn
    } do
      operations = [
        %{"operation_id" => "unknown", "type" => "summon_gremlin"},
        "not-an-object",
        %{
          "operation_id" => "missing-amount",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "anything"
        },
        open_operation(%{"operation_id" => "still-runs", "group_id" => "continuation"})
      ]

      conn = post_batch(conn, operations)
      assert %{"results" => [unknown, malformed, missing, applied]} = json_response(conn, 200)
      assert unknown["code"] == "invalid_operation"
      assert malformed["code"] == "invalid_operation"
      assert missing["code"] == "invalid_operation"
      assert applied["status"] == "applied"
    end

    test "invalid reschedules and later operations against a cancelled group do not mutate it", %{
      conn: conn
    } do
      operations = [
        open_operation(%{"group_id" => "inactive-group"}),
        reschedule_operation(%{
          "operation_id" => "invalid-move",
          "group_id" => "inactive-group",
          "occurred_on" => "2026-11-01",
          "new_arrival_on" => "2026-11-01",
          "expected_revision" => 1
        }),
        cancel_operation(%{
          "operation_id" => "cancel-no-cash",
          "group_id" => "inactive-group",
          "occurred_on" => "2026-11-01",
          "expected_revision" => 1
        }),
        reschedule_operation(%{
          "operation_id" => "move-inactive",
          "group_id" => "inactive-group",
          "expected_revision" => 2
        }),
        cancel_operation(%{
          "operation_id" => "cancel-inactive",
          "group_id" => "inactive-group",
          "expected_revision" => 2
        })
      ]

      conn = post_batch(conn, operations)

      assert %{"results" => [_, invalid_move, cancel, move_inactive, cancel_inactive]} =
               json_response(conn, 200)

      assert invalid_move["code"] == "invalid_stay"
      assert cancel["revision"] == 2
      assert cancel["refunded_cents"] == 0
      assert cancel["retained_cents"] == 0
      assert move_inactive["code"] == "group_not_active"
      assert cancel_inactive["code"] == "group_not_active"

      conn = get(build_conn(), "/api/v1/groups/inactive-group")
      assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} = json_response(conn, 200)
    end

    test "serializes concurrent writes so only one matching revision can apply", %{conn: conn} do
      conn = post_batch(conn, [open_operation(%{"group_id" => "concurrent-group"})])
      assert %{"results" => [%{"revision" => 1}]} = json_response(conn, 200)

      operations =
        for operation_id <- ~w(concurrent-pay-a concurrent-pay-b) do
          payment_operation(%{
            "operation_id" => operation_id,
            "group_id" => "concurrent-group",
            "amount_cents" => 100,
            "expected_revision" => 1
          })
        end

      results =
        operations
        |> Task.async_stream(
          fn operation -> GroupStay.Operations.apply_batch([operation]) |> hd() end,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(Map.get(&1, :status) == "applied")) == 1
      assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 1

      conn = get(build_conn(), "/api/v1/groups/concurrent-group")

      assert %{
               "data" => %{
                 "revision" => 2,
                 "deposit_paid_cents" => 100,
                 "outstanding_deposit_cents" => 19_400
               }
             } = json_response(conn, 200)
    end

    test "ignores expected revision on open, increments a no-op move, and recovers after stale",
         %{
           conn: conn
         } do
      operations = [
        open_operation(%{
          "group_id" => "revision-chain",
          "expected_revision" => 999
        }),
        reschedule_operation(%{
          "operation_id" => "same-date-move",
          "group_id" => "revision-chain",
          "new_arrival_on" => "2026-12-10",
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "stale-middle",
          "group_id" => "revision-chain",
          "amount_cents" => 100,
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "recovered-payment",
          "group_id" => "revision-chain",
          "amount_cents" => 100,
          "expected_revision" => 2
        }),
        payment_operation(%{
          "operation_id" => "malformed-revision",
          "group_id" => "revision-chain",
          "amount_cents" => 100,
          "expected_revision" => "3"
        })
      ]

      conn = post_batch(conn, operations)

      assert %{"results" => [opened, moved, stale, recovered, malformed]} =
               json_response(conn, 200)

      assert opened["revision"] == 1

      assert moved == %{
               "operation_id" => "same-date-move",
               "status" => "applied",
               "group_id" => "revision-chain",
               "new_arrival_on" => "2026-12-10",
               "new_departure_on" => "2026-12-13",
               "revision" => 2
             }

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
      assert recovered["status"] == "applied"
      assert recovered["revision"] == 3
      assert malformed["code"] == "invalid_operation"

      conn = get(build_conn(), "/api/v1/groups/revision-chain")

      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 100}} =
               json_response(conn, 200)
    end
  end

  describe "read endpoints" do
    test "return a missing-group error and an initially empty ledger", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp open_operation(overrides) do
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

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end
end
