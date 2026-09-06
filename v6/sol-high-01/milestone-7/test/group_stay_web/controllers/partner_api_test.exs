defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "opens a group and exposes its rooms and calculated totals", %{conn: conn} do
      operation = open_operation()

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [operation]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")

      assert json_response(conn, 200) == %{
               "data" => %{
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
                     "lodging_total_cents" => 45_000,
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "status" => "active",
                     "lodging_total_cents" => 52_500,
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
             }
    end

    test "rounds each flexible room deposit independently", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "tiny-a", "nightly_rate_cents" => 3},
            %{"room_id" => "tiny-b", "nightly_rate_cents" => 3}
          ]
        })

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [operation]})

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 2, "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "applies operations in order and enforces revision precedence", %{conn: conn} do
      operations = [
        open_operation(),
        operation("pay-1", "record_cash_payment", %{
          "group_id" => "group-81",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        }),
        operation("move-stale", "reschedule_group", %{
          "group_id" => "group-81",
          "new_arrival_on" => "2026-01-01",
          "expected_revision" => 1
        }),
        operation("move-1", "reschedule_group", %{
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        }),
        operation("overpay", "record_cash_payment", %{
          "group_id" => "group-81",
          "amount_cents" => 20_000,
          "expected_revision" => 3
        }),
        operation("pay-2", "record_cash_payment", %{
          "group_id" => "group-81",
          "amount_cents" => 14_500,
          "expected_revision" => 3
        })
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert results == [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "move-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               },
               %{
                 "operation_id" => "move-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2026-12-20",
                 "new_departure_on" => "2026-12-23",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-06",
                 "revision" => 3
               },
               %{
                 "operation_id" => "overpay",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "pay-2",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 14_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               }
             ]

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "revision" => 4,
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-23",
                 "deposit_paid_cents" => 19_500,
                 "outstanding_deposit_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "resolves missing groups before revision and domain validation", %{conn: conn} do
      operations = [
        operation("missing-pay", "record_cash_payment", %{
          "group_id" => "missing",
          "amount_cents" => 0,
          "expected_revision" => 99
        }),
        operation("missing-move", "reschedule_group", %{
          "group_id" => "missing",
          "new_arrival_on" => "not-a-date",
          "expected_revision" => 99
        })
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) == ["group_not_found", "group_not_found"]
    end

    test "cancels refundable and non-refundable groups and updates the ledger", %{conn: conn} do
      refundable =
        open_operation(%{
          "operation_id" => "open-refundable",
          "group_id" => "refundable",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}]
        })

      late =
        open_operation(%{
          "operation_id" => "open-late",
          "group_id" => "late",
          "arrival_on" => "2026-10-10",
          "departure_on" => "2026-10-11",
          "rooms" => [%{"room_id" => "r2", "nightly_rate_cents" => 10_000}]
        })

      advance =
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "r3", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })

      active =
        open_operation(%{
          "operation_id" => "open-active",
          "group_id" => "active",
          "rooms" => [%{"room_id" => "r4", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })

      operations = [
        refundable,
        operation("pay-refundable", "record_cash_payment", %{
          "group_id" => "refundable",
          "amount_cents" => 1_500
        }),
        operation("cancel-refundable", "cancel_group", %{"group_id" => "refundable"}),
        late,
        operation("pay-late", "record_cash_payment", %{
          "group_id" => "late",
          "amount_cents" => 1_000
        }),
        operation("cancel-late", "cancel_group", %{"group_id" => "late"}),
        advance,
        operation("pay-advance", "record_cash_payment", %{
          "group_id" => "advance",
          "amount_cents" => 4_000
        }),
        operation("cancel-advance", "cancel_group", %{"group_id" => "advance"}),
        active,
        operation("pay-active", "record_cash_payment", %{
          "group_id" => "active",
          "amount_cents" => 500
        })
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.at(results, 2) == %{
               "operation_id" => "cancel-refundable",
               "status" => "applied",
               "group_id" => "refundable",
               "refunded_cents" => 1_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert Enum.at(results, 5)["retained_cents"] == 1_000
      assert Enum.at(results, 8)["retained_cents"] == 4_000

      conn = get(build_conn(), ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 500,
                 "cash_refunded_cents" => 1_500,
                 "cash_retained_cents" => 5_000,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }

      conn = get(build_conn(), ~p"/api/v1/groups/refundable")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             } = json_response(conn, 200)
    end

    test "checks stale revisions before inactive status and never increments rejections", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        operation("cancel", "cancel_group", %{
          "group_id" => "group-81",
          "expected_revision" => 1
        }),
        operation("stale-after-cancel", "record_cash_payment", %{
          "group_id" => "group-81",
          "amount_cents" => 1,
          "expected_revision" => 1
        }),
        operation("inactive", "reschedule_group", %{
          "group_id" => "group-81",
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        }),
        operation("inactive-cancel", "cancel_group", %{
          "group_id" => "group-81",
          "expected_revision" => 2
        })
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.at(results, 2)["code"] == "stale_revision"
      assert Enum.at(results, 2)["actual_revision"] == 2
      assert Enum.at(results, 3)["code"] == "group_not_active"
      assert Enum.at(results, 4)["code"] == "group_not_active"

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2}} = json_response(conn, 200)
    end

    test "returns stable validation errors and continues after each rejection", %{conn: conn} do
      invalid_stay =
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"})

      invalid_rooms =
        open_operation(%{
          "operation_id" => "bad-rooms",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        })

      invalid_plan =
        open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "mystery"})

      operations = [
        invalid_stay,
        invalid_rooms,
        invalid_plan,
        %{"operation_id" => "unknown", "type" => "summon_gremlin"},
        %{"operation_id" => "incomplete", "type" => "cancel_group"},
        open_operation(),
        open_operation(%{"operation_id" => "duplicate"}),
        operation("zero", "record_cash_payment", %{
          "group_id" => "group-81",
          "amount_cents" => 0
        }),
        operation("bad-move", "reschedule_group", %{
          "group_id" => "group-81",
          "new_arrival_on" => "2026-10-03"
        })
      ]

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_rate_plan",
               "invalid_operation",
               "invalid_operation",
               nil,
               "group_already_exists",
               "invalid_amount",
               "invalid_stay"
             ]

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               json_response(conn, 200)
    end

    test "rejects invalid batch bodies but accepts an empty batch", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{"operations" => []})
      assert json_response(conn, 200) == %{"results" => []}
    end
  end

  describe "read endpoints" do
    test "returns the empty ledger and a stable missing-group error", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
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

      conn = get(build_conn(), ~p"/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
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

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => "2026-10-03"
      },
      fields
    )
  end
end
