defmodule GroupStayWeb.OperationalCoreTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "opens, funds, reschedules, and cancels a group in operation order", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "op-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        },
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-07",
          "group_id" => "group-81",
          "expected_revision" => 3
        }
      ]

      response =
        conn
        |> post("/api/v1/partner-batches", %{"operations" => operations})
        |> json_response(200)

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-12-06",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => 0,
                   "retained_cents" => 5_000,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             }

      group =
        build_conn()
        |> get("/api/v1/groups/group-81")
        |> json_response(200)

      assert group == %{
               "data" => %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 4,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "rate_plan" => "flexible",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-06",
                 "status" => "cancelled",
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "status" => "cancelled",
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "status" => "cancelled",
                     "deposit_due_cents" => 10_500,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
                 ],
                 "lodging_total_cents" => 0,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             }

      assert build_conn() |> get("/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 5_000,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "rounds each flexible room separately and charges advance purchase in full", %{
      conn: conn
    } do
      flexible =
        open_operation(%{
          "group_id" => "rounding",
          "rooms" => [
            %{"room_id" => "one", "nightly_rate_cents" => 3},
            %{"room_id" => "two", "nightly_rate_cents" => 3}
          ],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })

      advance =
        open_operation(%{
          "operation_id" => "advance",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase"
        })

      result =
        conn
        |> post("/api/v1/partner-batches", %{"operations" => [flexible, advance]})
        |> json_response(200)

      assert [flexible_result, advance_result] = result["results"]
      assert flexible_result["deposit_due_cents"] == 2
      assert advance_result["deposit_due_cents"] == 97_500
    end

    test "refunds flexible cash at the fourteen-day boundary and retains advance purchase cash",
         %{
           conn: conn
         } do
      operations = [
        open_operation(%{"group_id" => "flex"}),
        payment_operation("flex", 2_000),
        cancel_operation("flex", "2026-11-26", 2),
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation("advance", 3_000, %{"operation_id" => "pay-advance"}),
        cancel_operation("advance", "2026-10-10", 2, %{"operation_id" => "cancel-advance"})
      ]

      %{"results" => results} =
        conn
        |> post("/api/v1/partner-batches", %{"operations" => operations})
        |> json_response(200)

      assert Enum.at(results, 2)["refunded_cents"] == 2_000
      assert Enum.at(results, 2)["retained_cents"] == 0
      assert Enum.at(results, 5)["refunded_cents"] == 0
      assert Enum.at(results, 5)["retained_cents"] == 3_000

      assert build_conn() |> get("/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 2_000,
                 "cash_retained_cents" => 3_000,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "checks stale revisions before domain rules and does not mutate either read model", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation("group-81", 1_000),
        %{
          "operation_id" => "stale-too-large",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "amount_cents" => 999_999,
          "expected_revision" => 1
        },
        payment_operation("group-81", 500, %{
          "operation_id" => "pay-after-rejection",
          "expected_revision" => 2
        })
      ]

      %{"results" => results} =
        conn
        |> post("/api/v1/partner-batches", %{"operations" => operations})
        |> json_response(200)

      assert Enum.at(results, 2) == %{
               "operation_id" => "stale-too-large",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert Enum.at(results, 3)["status"] == "applied"
      assert Enum.at(results, 3)["revision"] == 3

      assert build_conn() |> get("/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 1_500,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "rejects invalid operations independently and continues the batch", %{conn: conn} do
      operations = [
        %{"operation_id" => "unknown", "type" => "wat", "occurred_on" => "2026-10-03"},
        open_operation(),
        open_operation(%{"operation_id" => "duplicate"}),
        %{
          "operation_id" => "bad-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 0
        },
        payment_operation("group-81", 1_000)
      ]

      %{"results" => results} =
        conn
        |> post("/api/v1/partner-batches", %{"operations" => operations})
        |> json_response(200)

      assert Enum.map(results, &{&1["status"], &1["code"]}) == [
               {"rejected", "invalid_operation"},
               {"applied", nil},
               {"rejected", "group_already_exists"},
               {"rejected", "invalid_amount"},
               {"applied", nil}
             ]
    end

    test "uses stable domain codes and never increments a revision on rejection", %{conn: conn} do
      duplicate_rooms = [
        %{"room_id" => "same", "nightly_rate_cents" => 100},
        %{"room_id" => "same", "nightly_rate_cents" => 200}
      ]

      operations = [
        open_operation(%{
          "operation_id" => "bad-stay",
          "group_id" => "bad-stay",
          "departure_on" => "2026-12-10"
        }),
        open_operation(%{
          "operation_id" => "bad-rooms",
          "group_id" => "bad-rooms",
          "rooms" => duplicate_rooms
        }),
        open_operation(%{
          "operation_id" => "malformed-rooms",
          "group_id" => "malformed-rooms",
          "rooms" => [nil]
        }),
        open_operation(%{
          "operation_id" => "bad-plan",
          "group_id" => "bad-plan",
          "rate_plan" => "mystery"
        }),
        open_operation(),
        payment_operation("group-81", 99_999),
        cancel_operation("group-81", "2026-10-05", 1),
        payment_operation("group-81", 1, %{
          "operation_id" => "inactive-payment",
          "expected_revision" => 2
        }),
        %{
          "operation_id" => "inactive-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-06",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        },
        cancel_operation("group-81", "2026-10-06", 2, %{
          "operation_id" => "inactive-cancel"
        })
      ]

      %{"results" => results} =
        conn
        |> post("/api/v1/partner-batches", %{"operations" => operations})
        |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rate_plan",
               nil,
               "payment_exceeds_outstanding",
               nil,
               "group_not_active",
               "group_not_active",
               "group_not_active"
             ]

      assert build_conn()
             |> get("/api/v1/groups/group-81")
             |> json_response(200)
             |> get_in(["data", "revision"]) == 2

      for group_id <- ~w(bad-stay bad-rooms malformed-rooms bad-plan) do
        assert build_conn() |> get("/api/v1/groups/#{group_id}") |> response(404)
      end
    end

    test "returns invalid_batch only when operations is not an array", %{conn: conn} do
      assert conn |> post("/api/v1/partner-batches", %{}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }

      assert build_conn()
             |> post("/api/v1/partner-batches", %{"operations" => []})
             |> json_response(200) == %{"results" => []}
    end
  end

  describe "read endpoints" do
    test "start with an empty ledger and return the documented missing-group error", %{conn: conn} do
      assert conn |> get("/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }

      assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
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

  defp payment_operation(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount,
        "expected_revision" => 1
      },
      overrides
    )
  end

  defp cancel_operation(group_id, occurred_on, expected_revision, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "expected_revision" => expected_revision
      },
      overrides
    )
  end
end
