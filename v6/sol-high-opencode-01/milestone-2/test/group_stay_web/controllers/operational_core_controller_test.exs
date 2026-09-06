defmodule GroupStayWeb.OperationalCoreControllerTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})
      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})
    end

    test "opens and reads a flexible group with room deposits rounded separately", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_003},
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
          ]
        })

      conn = post_batch(conn, [operation])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 19_503,
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
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_003},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
                 ],
                 "lodging_total_cents" => 97_515,
                 "deposit_due_cents" => 19_503,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_503
               }
             } = json_response(conn, 200)
    end

    test "requires the full lodging total for advance purchase groups", %{conn: conn} do
      operation = open_operation(%{"rate_plan" => "advance_purchase"})

      assert %{"results" => [%{"deposit_due_cents" => 97_500}]} =
               conn |> post_batch([operation]) |> json_response(200)
    end

    test "rejects invalid opening data without creating a group", %{conn: conn} do
      operations = [
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
        open_operation(%{"operation_id" => "bad-rooms", "rooms" => []}),
        open_operation(%{"operation_id" => "malformed-rooms", "rooms" => [nil]}),
        open_operation(%{"operation_id" => "duplicate-rooms", "rooms" => duplicate_rooms()}),
        open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "breakfast"}),
        Map.delete(open_operation(%{"operation_id" => "missing"}), "guest_id")
      ]

      assert %{"results" => results} =
               conn |> post_batch(operations) |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rate_plan",
               "invalid_operation"
             ]

      assert response(get(build_conn(), "/api/v1/groups/group-1"), 404) ==
               ~s({"error":{"code":"group_not_found"}})
    end

    test "enforces unique group identifiers", %{conn: conn} do
      assert %{"results" => [first, second]} =
               conn
               |> post_batch([open_operation(), open_operation(%{"operation_id" => "open-2"})])
               |> json_response(200)

      assert first["status"] == "applied"
      assert second["code"] == "group_already_exists"
      assert second["group_id"] == "group-1"
    end

    test "processes payments in order and continues after a rejection", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"operation_id" => "pay-1", "amount_cents" => 5_000}),
        payment_operation(%{"operation_id" => "too-much", "amount_cents" => 20_000}),
        payment_operation(%{
          "operation_id" => "pay-2",
          "amount_cents" => 14_500,
          "expected_revision" => 2
        })
      ]

      assert %{"results" => [opened, paid, rejected, paid_rest]} =
               conn |> post_batch(operations) |> json_response(200)

      assert opened["revision"] == 1

      assert paid == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      assert rejected["code"] == "payment_exceeds_outstanding"
      assert paid_rest["revision"] == 3
      assert paid_rest["outstanding_deposit_cents"] == 0
    end

    test "rejects unusable payments and missing or inactive groups", %{conn: conn} do
      open_and_cancel = [
        open_operation(),
        cancel_operation(%{"operation_id" => "cancel-1"}),
        payment_operation(%{"operation_id" => "inactive", "amount_cents" => 1}),
        payment_operation(%{
          "operation_id" => "missing",
          "group_id" => "absent",
          "amount_cents" => 1
        })
      ]

      assert %{"results" => [_, _, inactive, missing]} =
               conn |> post_batch(open_and_cancel) |> json_response(200)

      assert inactive["code"] == "group_not_active"
      assert missing["code"] == "group_not_found"

      open_operation(%{"group_id" => "group-2", "operation_id" => "open-2"})
      |> then(&post_batch(build_conn(), [&1]))

      assert %{"results" => [%{"code" => "invalid_amount"}]} =
               build_conn()
               |> post_batch([
                 payment_operation(%{
                   "operation_id" => "zero",
                   "group_id" => "group-2",
                   "amount_cents" => 0
                 })
               ])
               |> json_response(200)
    end

    test "rejects a payment with an invalid operation date without changing cash", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"occurred_on" => "not-a-date", "amount_cents" => 1_000})
      ]

      assert %{"results" => [_, %{"code" => "invalid_operation"}]} =
               conn |> post_batch(operations) |> json_response(200)

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
    end

    test "reschedules by the original stay length and validates dates", %{conn: conn} do
      operations = [
        open_operation(),
        reschedule_operation(),
        reschedule_operation(%{
          "operation_id" => "invalid-move",
          "occurred_on" => "2026-12-01",
          "new_arrival_on" => "2026-12-01"
        })
      ]

      assert %{"results" => [_, moved, invalid]} =
               conn |> post_batch(operations) |> json_response(200)

      assert moved == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2027-01-05",
               "new_departure_on" => "2027-01-08",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-22",
               "revision" => 2
             }

      assert invalid["code"] == "invalid_stay"

      assert %{"data" => %{"arrival_on" => "2027-01-05", "revision" => 2}} =
               build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
    end

    test "rejects a reschedule whose derived departure is outside the date range", %{conn: conn} do
      operations = [
        open_operation(),
        reschedule_operation(%{
          "occurred_on" => "9999-01-01",
          "new_arrival_on" => "9999-12-31"
        })
      ]

      assert %{"results" => [_, %{"code" => "invalid_stay"}]} =
               conn |> post_batch(operations) |> json_response(200)

      assert %{"data" => %{"arrival_on" => "2026-12-10", "revision" => 1}} =
               build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
    end

    test "rejects room totals that cannot be represented by SQLite", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [
            %{"room_id" => "huge", "nightly_rate_cents" => 5_000_000_000_000_000_000}
          ]
        })

      assert %{"results" => [%{"code" => "invalid_rooms"}]} =
               conn |> post_batch([operation]) |> json_response(200)
    end

    test "checks stale revisions before other domain rules and leaves state unchanged", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation(%{
          "operation_id" => "stale-invalid",
          "expected_revision" => 9,
          "amount_cents" => -1
        }),
        payment_operation(%{
          "operation_id" => "current",
          "expected_revision" => 1,
          "amount_cents" => 1_000
        })
      ]

      assert %{"results" => [_, stale, current]} =
               conn |> post_batch(operations) |> json_response(200)

      assert stale == %{
               "operation_id" => "stale-invalid",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      assert current["revision"] == 2

      assert %{"data" => %{"cash_held_cents" => 1_000}} =
               build_conn() |> get("/api/v1/ledger") |> json_response(200)
    end

    test "resolves a missing group before revision validation", %{conn: conn} do
      operation =
        payment_operation(%{
          "group_id" => "absent",
          "expected_revision" => "not-an-integer",
          "amount_cents" => -1
        })

      assert %{"results" => [%{"code" => "group_not_found"}]} =
               conn |> post_batch([operation]) |> json_response(200)
    end

    test "refunds timely flexible cancellations and moves cash out of held totals", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"amount_cents" => 10_000}),
        cancel_operation(%{"expected_revision" => 2})
      ]

      assert %{"results" => [_, _, cancelled]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled["refunded_cents"] == 10_000
      assert cancelled["retained_cents"] == 0
      assert cancelled["revision"] == 3

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0
               }
             } = build_conn() |> get("/api/v1/ledger") |> json_response(200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 3,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 10_000,
                 "outstanding_deposit_cents" => 0
               }
             } = build_conn() |> get("/api/v1/groups/group-1") |> json_response(200)
    end

    test "retains late flexible and all advance-purchase cash", %{conn: conn} do
      operations = [
        open_operation(%{"group_id" => "late", "operation_id" => "open-late"}),
        payment_operation(%{
          "group_id" => "late",
          "operation_id" => "pay-late",
          "amount_cents" => 500
        }),
        cancel_operation(%{
          "group_id" => "late",
          "operation_id" => "cancel-late",
          "occurred_on" => "2026-11-27"
        }),
        open_operation(%{
          "group_id" => "advance",
          "operation_id" => "open-advance",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation(%{
          "group_id" => "advance",
          "operation_id" => "pay-advance",
          "amount_cents" => 700
        }),
        cancel_operation(%{
          "group_id" => "advance",
          "operation_id" => "cancel-advance",
          "occurred_on" => "2026-10-04"
        })
      ]

      assert %{"results" => [_, _, late, _, _, advance]} =
               conn |> post_batch(operations) |> json_response(200)

      assert late["retained_cents"] == 500
      assert advance["retained_cents"] == 700

      assert %{"data" => %{"cash_retained_cents" => 1_200}} =
               build_conn() |> get("/api/v1/ledger") |> json_response(200)
    end

    test "ledger totals remain available when the aggregate exceeds SQLite's integer range", %{
      conn: conn
    } do
      rate = 2_500_000_000_000_000_000
      paid = 7_500_000_000_000_000_000

      operations = [
        open_operation(%{
          "group_id" => "large-1",
          "operation_id" => "open-large-1",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-1", "nightly_rate_cents" => rate}]
        }),
        payment_operation(%{
          "group_id" => "large-1",
          "operation_id" => "pay-large-1",
          "amount_cents" => paid
        }),
        open_operation(%{
          "group_id" => "large-2",
          "operation_id" => "open-large-2",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-2", "nightly_rate_cents" => rate}]
        }),
        payment_operation(%{
          "group_id" => "large-2",
          "operation_id" => "pay-large-2",
          "amount_cents" => paid
        })
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"cash_held_cents" => 15_000_000_000_000_000_000}} =
               build_conn() |> get("/api/v1/ledger") |> json_response(200)
    end

    test "rejects every later operation against a cancelled group", %{conn: conn} do
      operations = [
        open_operation(),
        cancel_operation(),
        cancel_operation(%{"operation_id" => "cancel-again"}),
        reschedule_operation(%{"operation_id" => "move-cancelled"}),
        payment_operation(%{"operation_id" => "pay-cancelled", "amount_cents" => 1})
      ]

      assert %{"results" => [_, _, cancel, move, payment]} =
               conn |> post_batch(operations) |> json_response(200)

      assert Enum.map([cancel, move, payment], & &1["code"]) ==
               ~w(group_not_active group_not_active group_not_active)
    end

    test "rejects unknown and incomplete operations but continues the batch", %{conn: conn} do
      operations = [
        %{"operation_id" => "unknown", "type" => "other", "occurred_on" => "2026-10-03"},
        %{"type" => "record_cash_payment", "operation_id" => "incomplete"},
        "not-an-operation",
        open_operation()
      ]

      assert %{"results" => [unknown, incomplete, malformed, opened]} =
               conn |> post_batch(operations) |> json_response(200)

      assert unknown["code"] == "invalid_operation"
      assert incomplete["code"] == "invalid_operation"

      assert malformed == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert opened["status"] == "applied"
    end
  end

  describe "GET read endpoints" do
    test "returns an empty ledger and a stable missing-group error", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }

      assert json_response(get(build_conn(), "/api/v1/groups/absent"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
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
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp reschedule_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1",
        "new_arrival_on" => "2027-01-05"
      },
      overrides
    )
  end

  defp cancel_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1"
      },
      overrides
    )
  end

  defp duplicate_rooms do
    [
      %{"room_id" => "same", "nightly_rate_cents" => 100},
      %{"room_id" => "same", "nightly_rate_cents" => 200}
    ]
  end
end
