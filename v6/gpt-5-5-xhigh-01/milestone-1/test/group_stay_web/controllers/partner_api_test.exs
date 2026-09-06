defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "opens a flexible group and exposes the group read model", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
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
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
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
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             }
    end

    test "rounds flexible deposits per room", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "op-rounding",
              "group_id" => "rounding-group",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 3},
                %{"room_id" => "room-b", "nightly_rate_cents" => 3}
              ]
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "deposit_due_cents" => 2
                 }
               ]
             } = json_response(conn, 200)
    end

    test "processes operations in order and moves refundable cash to refunded ledger totals", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{"operation_id" => "op-open", "group_id" => "group-flow"}),
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-flow",
              "amount_cents" => 9_500,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-move",
              "type" => "reschedule_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-flow",
              "new_arrival_on" => "2026-12-12",
              "expected_revision" => 2
            },
            %{
              "operation_id" => "op-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-11-20",
              "group_id" => "group-flow",
              "expected_revision" => 3
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-flow",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-flow",
                   "amount_cents" => 9_500,
                   "outstanding_deposit_cents" => 10_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-flow",
                   "new_arrival_on" => "2026-12-12",
                   "new_departure_on" => "2026-12-15",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-flow",
                   "refunded_cents" => 9_500,
                   "retained_cents" => 0,
                   "revision" => 4
                 }
               ]
             }

      assert %{"data" => group} =
               get(build_conn(), ~p"/api/v1/groups/group-flow") |> json_response(200)

      assert group["status"] == "cancelled"
      assert group["revision"] == 4
      assert group["arrival_on"] == "2026-12-12"
      assert group["departure_on"] == "2026-12-15"
      assert group["deposit_paid_cents"] == 9_500
      assert group["outstanding_deposit_cents"] == 0

      conn = get(build_conn(), ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 9_500,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "rejects one operation without undoing earlier applied operations or stopping later ones",
         %{
           conn: conn
         } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{"operation_id" => "op-open", "group_id" => "group-rollback"}),
            %{
              "operation_id" => "op-too-much",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-rollback",
              "amount_cents" => 19_501
            },
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-rollback",
              "amount_cents" => 5_000,
              "expected_revision" => 1
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-rollback",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-too-much",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-rollback",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               ]
             }

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/groups/group-rollback") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "rejects stale revisions before other group domain validation and leaves totals unchanged",
         %{
           conn: conn
         } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{"operation_id" => "op-open", "group_id" => "stale-group"}),
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "stale-group",
              "amount_cents" => 5_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-stale",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "stale-group",
              "amount_cents" => -1,
              "expected_revision" => 1
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "stale-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "stale-group",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "stale-group",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/groups/stale-group") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "rejects inactive group operations without incrementing the revision", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{"operation_id" => "op-open", "group_id" => "inactive-group"}),
            %{
              "operation_id" => "op-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-12-01",
              "group_id" => "inactive-group",
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-12-02",
              "group_id" => "inactive-group",
              "amount_cents" => 100
            },
            %{
              "operation_id" => "op-move",
              "type" => "reschedule_group",
              "occurred_on" => "2026-12-02",
              "group_id" => "inactive-group",
              "new_arrival_on" => "2027-01-01"
            },
            %{
              "operation_id" => "op-cancel-again",
              "type" => "cancel_group",
              "occurred_on" => "2026-12-02",
              "group_id" => "inactive-group"
            }
          ]
        })

      assert Enum.drop(json_response(conn, 200)["results"], 2) == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "group_not_active"
               },
               %{
                 "operation_id" => "op-move",
                 "status" => "rejected",
                 "code" => "group_not_active"
               },
               %{
                 "operation_id" => "op-cancel-again",
                 "status" => "rejected",
                 "code" => "group_not_active"
               }
             ]

      assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} =
               get(build_conn(), ~p"/api/v1/groups/inactive-group") |> json_response(200)
    end

    test "supports advance-purchase deposits and retains their paid cash on cancellation", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "op-open",
              "group_id" => "advance-group",
              "rate_plan" => "advance_purchase"
            }),
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "advance-group",
              "amount_cents" => 97_500
            },
            %{
              "operation_id" => "op-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "advance-group"
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "advance-group",
                   "deposit_due_cents" => 97_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "advance-group",
                   "amount_cents" => 97_500,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "advance-group",
                   "refunded_cents" => 0,
                   "retained_cents" => 97_500,
                   "revision" => 3
                 }
               ]
             }

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 97_500
               }
             } = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "returns stable rejection codes for invalid open operations", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{"operation_id" => "op-open", "group_id" => "dupe-group"}),
            open_group_operation(%{"operation_id" => "op-dupe", "group_id" => "dupe-group"}),
            open_group_operation(%{
              "operation_id" => "op-stay",
              "group_id" => "bad-stay",
              "departure_on" => "2026-12-10"
            }),
            open_group_operation(%{
              "operation_id" => "op-rooms",
              "group_id" => "bad-rooms",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
              ]
            }),
            open_group_operation(%{
              "operation_id" => "op-rate",
              "group_id" => "bad-rate",
              "rate_plan" => "mystery"
            }),
            %{
              "operation_id" => "op-unknown",
              "type" => "unknown",
              "occurred_on" => "2026-10-03"
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "dupe-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-dupe",
                 "status" => "rejected",
                 "code" => "group_already_exists"
               },
               %{"operation_id" => "op-stay", "status" => "rejected", "code" => "invalid_stay"},
               %{"operation_id" => "op-rooms", "status" => "rejected", "code" => "invalid_rooms"},
               %{
                 "operation_id" => "op-rate",
                 "status" => "rejected",
                 "code" => "invalid_rate_plan"
               },
               %{
                 "operation_id" => "op-unknown",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
             ]

      assert get(build_conn(), ~p"/api/v1/groups/bad-stay") |> json_response(404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end
  end

  defp open_group_operation(overrides) do
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
end
