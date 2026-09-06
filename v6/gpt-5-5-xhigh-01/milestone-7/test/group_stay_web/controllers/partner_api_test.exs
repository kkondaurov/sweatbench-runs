defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.LedgerEntry
  alias GroupStay.Reservations.OperationRecord
  alias GroupStay.Reservations.Room

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
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "status" => "active",
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "nightly_rate_cents" => 15_000,
                     "lodging_total_cents" => 45_000,
                     "status" => "active",
                     "deposit_due_cents" => 9_000,
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "nightly_rate_cents" => 17_500,
                     "lodging_total_cents" => 52_500,
                     "status" => "active",
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

    test "fixes policy versions at booking and recomputes refundable dates on reschedule", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "op-open-new",
              "group_id" => "policy-new",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-02",
              "departure_on" => "2027-03-05"
            }),
            %{
              "operation_id" => "op-move-new",
              "type" => "reschedule_group",
              "occurred_on" => "2027-01-02",
              "group_id" => "policy-new",
              "new_arrival_on" => "2027-04-01",
              "expected_revision" => 1
            },
            open_group_operation(%{
              "operation_id" => "op-open-old",
              "group_id" => "policy-old",
              "occurred_on" => "2026-12-31",
              "arrival_on" => "2027-03-02",
              "departure_on" => "2027-03-05"
            }),
            %{
              "operation_id" => "op-move-old",
              "type" => "reschedule_group",
              "occurred_on" => "2027-01-02",
              "group_id" => "policy-old",
              "new_arrival_on" => "2027-04-01",
              "expected_revision" => 1
            },
            open_group_operation(%{
              "operation_id" => "op-open-advance",
              "group_id" => "policy-advance",
              "occurred_on" => "2027-01-01",
              "rate_plan" => "advance_purchase"
            })
          ]
        })

      assert [
               %{"operation_id" => "op-open-new", "status" => "applied"},
               %{
                 "operation_id" => "op-move-new",
                 "status" => "applied",
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-03-02"
               },
               %{"operation_id" => "op-open-old", "status" => "applied"},
               %{
                 "operation_id" => "op-move-old",
                 "status" => "applied",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-18"
               },
               %{"operation_id" => "op-open-advance", "status" => "applied"}
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-03-02"
               }
             } = get(build_conn(), ~p"/api/v1/groups/policy-new") |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-18"
               }
             } = get(build_conn(), ~p"/api/v1/groups/policy-old") |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get(build_conn(), ~p"/api/v1/groups/policy-advance") |> json_response(200)
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
                   "policy_version" => "flex-14",
                   "refundable_until" => "2026-11-28",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-flow",
                   "refunded_cents" => 9_500,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
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
      assert group["lodging_total_cents"] == 0
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0
      assert Enum.all?(group["rooms"], &(&1["status"] == "cancelled"))

      conn = get(build_conn(), ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 9_500,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
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
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 97_500,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "issues hotel credit on refundable cancellation and applies earliest expiring lots first",
         %{
           conn: conn
         } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-b",
              "group_id" => "source-b",
              "guest_id" => "guest-credit",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-b",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "source-b",
              "amount_cents" => 2_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-b",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-20",
              "group_id" => "source-b",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            },
            open_group_operation(%{
              "operation_id" => "open-a",
              "group_id" => "source-a",
              "guest_id" => "guest-credit",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-a",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "source-a",
              "amount_cents" => 1_005,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-a",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-20",
              "group_id" => "source-a",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            },
            open_group_operation(%{
              "operation_id" => "open-target",
              "group_id" => "credit-target",
              "guest_id" => "guest-credit",
              "occurred_on" => "2027-01-21",
              "arrival_on" => "2027-04-01",
              "departure_on" => "2027-04-04"
            }),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-22",
              "group_id" => "credit-target",
              "amount_cents" => 1_500,
              "expected_revision" => 1
            }
          ]
        })

      results = json_response(conn, 200)["results"]

      assert Enum.at(results, 2) == %{
               "operation_id" => "cancel-b",
               "status" => "applied",
               "group_id" => "source-b",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 2_200,
               "revision" => 3
             }

      assert Enum.at(results, 5) == %{
               "operation_id" => "cancel-a",
               "status" => "applied",
               "group_id" => "source-a",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_106,
               "revision" => 3
             }

      assert Enum.at(results, 7) == %{
               "operation_id" => "apply-credit",
               "status" => "applied",
               "group_id" => "credit-target",
               "amount_cents" => 1_500,
               "outstanding_deposit_cents" => 18_000,
               "revision" => 2
             }

      assert %{
               "data" => %{
                 "guest_id" => "guest-credit",
                 "available_cents" => 1_806,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 1_806,
                     "expires_on" => "2028-01-20"
                   }
                 ]
               }
             } =
               get(build_conn(), ~p"/api/v1/guests/guest-credit/credit?on=2027-01-22")
               |> json_response(200)

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 1_500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1_500,
                 "outstanding_deposit_cents" => 18_000
               }
             } = get(build_conn(), ~p"/api/v1/groups/credit-target") |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 3_005,
                 "credit_liability_cents" => 3_306
               }
             } = get(build_conn(), ~p"/api/v1/ledger?on=2027-01-22") |> json_response(200)
    end

    test "restores applied credit to original lots on refundable cancellation", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-source",
              "group_id" => "restore-source",
              "guest_id" => "guest-restore",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "restore-source",
              "amount_cents" => 1_000
            },
            %{
              "operation_id" => "cancel-source",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "restore-source",
              "refund_method" => "hotel_credit"
            },
            open_group_operation(%{
              "operation_id" => "open-target",
              "group_id" => "restore-target",
              "guest_id" => "guest-restore",
              "occurred_on" => "2027-01-11",
              "arrival_on" => "2027-04-01",
              "departure_on" => "2027-04-04"
            }),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-12",
              "group_id" => "restore-target",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-target",
              "type" => "cancel_group",
              "occurred_on" => "2027-02-01",
              "group_id" => "restore-target",
              "expected_revision" => 2
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "cancel-target",
               "status" => "applied",
               "group_id" => "restore-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "available_cents" => 1_100,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-source",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2028-01-10"
                   }
                 ]
               }
             } =
               get(build_conn(), ~p"/api/v1/guests/guest-restore/credit?on=2027-02-01")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 1_100}} =
               get(build_conn(), ~p"/api/v1/ledger?on=2027-02-01") |> json_response(200)
    end

    test "counts active credit after its original expiry and drops it if restored expired", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-source",
              "group_id" => "expiry-source",
              "guest_id" => "guest-expiry",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "expiry-source",
              "amount_cents" => 1_000
            },
            %{
              "operation_id" => "cancel-source",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "expiry-source",
              "refund_method" => "hotel_credit"
            },
            open_group_operation(%{
              "operation_id" => "open-target",
              "group_id" => "expiry-target",
              "guest_id" => "guest-expiry",
              "occurred_on" => "2027-01-11",
              "arrival_on" => "2028-03-01",
              "departure_on" => "2028-03-04"
            }),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-12",
              "group_id" => "expiry-target",
              "amount_cents" => 1_100,
              "expected_revision" => 1
            }
          ]
        })

      assert %{"results" => [%{"status" => "applied"} | _rest]} = json_response(conn, 200)

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get(build_conn(), ~p"/api/v1/guests/guest-expiry/credit?on=2028-01-11")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 1_100}} =
               get(build_conn(), ~p"/api/v1/ledger?on=2028-01-11") |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "cancel-target",
              "type" => "cancel_group",
              "occurred_on" => "2028-01-20",
              "group_id" => "expiry-target",
              "expected_revision" => 2
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "cancel-target",
                   "status" => "applied",
                   "group_id" => "expiry-target",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get(build_conn(), ~p"/api/v1/guests/guest-expiry/credit?on=2028-01-20")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/ledger?on=2028-01-20") |> json_response(200)
    end

    test "rejects hotel-credit refund method for non-refundable cancellation and consumes credit",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-source",
              "group_id" => "nonref-source",
              "guest_id" => "guest-nonref",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "nonref-source",
              "amount_cents" => 1_000
            },
            %{
              "operation_id" => "cancel-source",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "nonref-source",
              "refund_method" => "hotel_credit"
            },
            open_group_operation(%{
              "operation_id" => "open-advance",
              "group_id" => "nonref-target",
              "guest_id" => "guest-nonref",
              "occurred_on" => "2027-01-11",
              "rate_plan" => "advance_purchase"
            }),
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-12",
              "group_id" => "nonref-target",
              "amount_cents" => 1_100,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-unavailable",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-13",
              "group_id" => "nonref-target",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            },
            %{
              "operation_id" => "cancel-cash",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-14",
              "group_id" => "nonref-target",
              "expected_revision" => 2
            }
          ]
        })

      assert Enum.slice(json_response(conn, 200)["results"], 4, 3) == [
               %{
                 "operation_id" => "apply-credit",
                 "status" => "applied",
                 "group_id" => "nonref-target",
                 "amount_cents" => 1_100,
                 "outstanding_deposit_cents" => 96_400,
                 "revision" => 2
               },
               %{
                 "operation_id" => "cancel-unavailable",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               },
               %{
                 "operation_id" => "cancel-cash",
                 "status" => "applied",
                 "group_id" => "nonref-target",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]

      assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} =
               get(build_conn(), ~p"/api/v1/groups/nonref-target") |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/ledger?on=2027-01-14") |> json_response(200)
    end

    test "checks revision before credit balance and leaves rejected credit attempts unchanged", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{"operation_id" => "op-open", "group_id" => "credit-stale"}),
            %{
              "operation_id" => "op-stale-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2026-10-04",
              "group_id" => "credit-stale",
              "amount_cents" => 100,
              "expected_revision" => 0
            },
            %{
              "operation_id" => "op-no-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2026-10-05",
              "group_id" => "credit-stale",
              "amount_cents" => 100,
              "expected_revision" => 1
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "credit-stale",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-stale-credit",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "credit-stale",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "op-no-credit",
                 "status" => "rejected",
                 "code" => "insufficient_credit"
               }
             ]

      assert %{
               "data" => %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/credit-stale") |> json_response(200)
    end

    test "replays an applied operation result without reading current group state", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "op-open-replay",
              "group_id" => "replay-group"
            }),
            %{
              "operation_id" => "op-pay-replay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "replay-group",
              "amount_cents" => 5_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-move-replay",
              "type" => "reschedule_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "replay-group",
              "new_arrival_on" => "2026-12-12",
              "expected_revision" => 2
            }
          ]
        })

      assert Enum.at(json_response(conn, 200)["results"], 1) == %{
               "operation_id" => "op-pay-replay",
               "status" => "applied",
               "group_id" => "replay-group",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-pay-replay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "replay-group",
              "amount_cents" => 5_000,
              "expected_revision" => 1
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay-replay",
                   "status" => "applied",
                   "group_id" => "replay-group",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               ]
             }

      assert %{
               "data" => %{
                 "revision" => 3,
                 "deposit_paid_cents" => 5_000,
                 "cash_paid_cents" => 5_000
               }
             } = get(build_conn(), ~p"/api/v1/groups/replay-group") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/operations/op-pay-replay") |> json_response(200) ==
               %{
                 "data" => %{
                   "operation_id" => "op-pay-replay",
                   "status" => "applied",
                   "group_id" => "replay-group",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               }
    end

    test "remembers rejected operation results even if later state would make them valid",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-rejected-replay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "late-group",
              "amount_cents" => 5_000
            },
            open_group_operation(%{
              "operation_id" => "op-open-late",
              "group_id" => "late-group"
            })
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-rejected-replay",
                 "status" => "rejected",
                 "code" => "group_not_found"
               },
               %{
                 "operation_id" => "op-open-late",
                 "status" => "applied",
                 "group_id" => "late-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-rejected-replay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "late-group",
              "amount_cents" => 5_000
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-rejected-replay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }

      assert %{
               "data" => %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/late-group") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/operations/op-rejected-replay") |> json_response(200) ==
               %{
                 "data" => %{
                   "operation_id" => "op-rejected-replay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               }
    end

    test "rejects a reused operation id with a different payload without replacing the record",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "op-open-conflict",
              "group_id" => "conflict-group"
            }),
            %{
              "operation_id" => "op-pay-conflict",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "conflict-group",
              "amount_cents" => 5_000,
              "expected_revision" => 1
            }
          ]
        })

      assert Enum.at(json_response(conn, 200)["results"], 1) == %{
               "operation_id" => "op-pay-conflict",
               "status" => "applied",
               "group_id" => "conflict-group",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-pay-conflict",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "conflict-group",
              "amount_cents" => 6_000,
              "expected_revision" => 2
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay-conflict",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/groups/conflict-group") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/operations/op-pay-conflict") |> json_response(200) ==
               %{
                 "data" => %{
                   "operation_id" => "op-pay-conflict",
                   "status" => "applied",
                   "group_id" => "conflict-group",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               }
    end

    test "treats a corrected retry of a stale operation as an operation id conflict",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "op-open-stale-retry",
              "group_id" => "stale-retry-group"
            }),
            %{
              "operation_id" => "op-pay-stale-retry",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "stale-retry-group",
              "amount_cents" => 5_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-stale-retry",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "stale-retry-group",
              "amount_cents" => -1,
              "expected_revision" => 1
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "op-stale-retry",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "stale-retry-group",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-stale-retry",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "stale-retry-group",
              "amount_cents" => -1,
              "expected_revision" => 2
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-stale-retry",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }

      assert get(build_conn(), ~p"/api/v1/operations/op-stale-retry") |> json_response(200) ==
               %{
                 "data" => %{
                   "operation_id" => "op-stale-retry",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "stale-retry-group",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               }
    end

    test "ignores object key order but treats array order as significant", %{conn: conn} do
      first_body = """
      {
        "operations": [
          {
            "operation_id": "op-key-order",
            "type": "open_group",
            "occurred_on": "2026-10-03",
            "group_id": "key-order-group",
            "guest_id": "guest-22",
            "property_id": "ams-canal",
            "arrival_on": "2026-12-10",
            "departure_on": "2026-12-13",
            "rate_plan": "flexible",
            "rooms": [
              {"room_id": "room-a", "nightly_rate_cents": 15000},
              {"room_id": "room-b", "nightly_rate_cents": 17500}
            ]
          }
        ]
      }
      """

      reordered_keys_body = """
      {
        "operations": [
          {
            "rooms": [
              {"nightly_rate_cents": 15000, "room_id": "room-a"},
              {"nightly_rate_cents": 17500, "room_id": "room-b"}
            ],
            "rate_plan": "flexible",
            "departure_on": "2026-12-13",
            "arrival_on": "2026-12-10",
            "property_id": "ams-canal",
            "guest_id": "guest-22",
            "group_id": "key-order-group",
            "occurred_on": "2026-10-03",
            "type": "open_group",
            "operation_id": "op-key-order"
          }
        ]
      }
      """

      reversed_rooms_body = """
      {
        "operations": [
          {
            "operation_id": "op-key-order",
            "type": "open_group",
            "occurred_on": "2026-10-03",
            "group_id": "key-order-group",
            "guest_id": "guest-22",
            "property_id": "ams-canal",
            "arrival_on": "2026-12-10",
            "departure_on": "2026-12-13",
            "rate_plan": "flexible",
            "rooms": [
              {"room_id": "room-b", "nightly_rate_cents": 17500},
              {"room_id": "room-a", "nightly_rate_cents": 15000}
            ]
          }
        ]
      }
      """

      assert post_json(conn, first_body) |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-key-order",
                   "status" => "applied",
                   "group_id" => "key-order-group",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      assert post_json(build_conn(), reordered_keys_body) |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-key-order",
                   "status" => "applied",
                   "group_id" => "key-order-group",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      assert post_json(build_conn(), reversed_rooms_body) |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-key-order",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             }
    end

    test "returns operation_not_found for missing operation records", %{conn: conn} do
      assert get(conn, ~p"/api/v1/operations/missing-op") |> json_response(404) ==
               %{"error" => %{"code" => "operation_not_found"}}
    end

    test "retains operation audit fields and first committed order", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "audit-open",
              "group_id" => "audit-group"
            }),
            %{
              "operation_id" => "audit-reject",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "audit-group",
              "amount_cents" => 19_501
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "audit-open",
                 "status" => "applied",
                 "group_id" => "audit-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "audit-reject",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               }
             ]

      assert post(build_conn(), ~p"/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "audit-reject",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "audit-group",
                   "amount_cents" => 19_501
                 }
               ]
             })
             |> json_response(200)

      records =
        OperationRecord
        |> order_by([record], asc: record.id)
        |> select([record], {
          record.operation_id,
          record.operation_type,
          record.payload_json
        })
        |> Repo.all()

      assert [
               {"audit-open", "open_group", open_payload_json},
               {"audit-reject", "record_cash_payment", reject_payload_json}
             ] = records

      assert Jason.decode!(open_payload_json) == %{
               "operation_id" => "audit-open",
               "type" => "open_group",
               "occurred_on" => "2026-10-03",
               "group_id" => "audit-group",
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

      assert Jason.decode!(reject_payload_json) == %{
               "operation_id" => "audit-reject",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "audit-group",
               "amount_cents" => 19_501
             }
    end

    test "cancels selected rooms in original order and settles only their allocations", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-room-cancel",
              "group_id" => "room-cancel"
            }),
            %{
              "operation_id" => "pay-room-cancel",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "room-cancel",
              "amount_cents" => 12_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-one-room",
              "type" => "cancel_rooms",
              "occurred_on" => "2026-11-20",
              "group_id" => "room-cancel",
              "room_ids" => ["room-a"],
              "expected_revision" => 2
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "open-room-cancel",
                 "status" => "applied",
                 "group_id" => "room-cancel",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-room-cancel",
                 "status" => "applied",
                 "group_id" => "room-cancel",
                 "amount_cents" => 12_000,
                 "outstanding_deposit_cents" => 7_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "cancel-one-room",
                 "status" => "applied",
                 "group_id" => "room-cancel",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 9_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]

      assert %{"data" => group} =
               get(build_conn(), ~p"/api/v1/groups/room-cancel") |> json_response(200)

      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 52_500
      assert group["deposit_due_cents"] == 10_500
      assert group["deposit_paid_cents"] == 3_000
      assert group["cash_paid_cents"] == 3_000
      assert group["outstanding_deposit_cents"] == 7_500

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 15_000,
                 "lodging_total_cents" => 45_000,
                 "status" => "cancelled",
                 "deposit_due_cents" => 9_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 17_500,
                 "lodging_total_cents" => 52_500,
                 "status" => "active",
                 "deposit_due_cents" => 10_500,
                 "cash_paid_cents" => 3_000,
                 "credit_paid_cents" => 0
               }
             ]

      assert %{
               "data" => %{
                 "cash_held_cents" => 3_000,
                 "cash_refunded_cents" => 9_000,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "backfills pre-durable active cash as unattributed room funding", %{conn: conn} do
      group =
        %Group{}
        |> Group.changeset(%{
          group_id: "legacy-funded",
          guest_id: "legacy-guest",
          property_id: "ams-canal",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-13],
          rate_plan: "flexible",
          policy_version: "flex-14",
          status: "active",
          lodging_total_cents: 97_500,
          deposit_due_cents: 19_500,
          deposit_paid_cents: 5_000,
          cash_paid_cents: 5_000,
          credit_paid_cents: 0,
          revision: 2
        })
        |> Repo.insert!()

      [
        %{
          room_id: "room-a",
          nightly_rate_cents: 15_000,
          position: 0,
          lodging_total_cents: 45_000,
          deposit_due_cents: 9_000
        },
        %{
          room_id: "room-b",
          nightly_rate_cents: 17_500,
          position: 1,
          lodging_total_cents: 52_500,
          deposit_due_cents: 10_500
        }
      ]
      |> Enum.each(fn room ->
        %Room{}
        |> Room.changeset(
          Map.merge(room, %{
            group_id: group.id,
            status: "active"
          })
        )
        |> Repo.insert!()
      end)

      %LedgerEntry{}
      |> LedgerEntry.changeset(%{
        group_id: group.id,
        operation_id: "legacy-pay",
        entry_type: "cash_payment",
        amount_cents: 5_000,
        occurred_on: ~D[2026-10-04]
      })
      |> Repo.insert!()

      assert %{
               "data" => %{
                 "cash_paid_cents" => 5_000,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 5_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ]
               }
             } = get(conn, ~p"/api/v1/groups/legacy-funded") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/legacy-pay") |> json_response(404) ==
               %{"error" => %{"code" => "operation_not_found"}}
    end

    test "reduces held cash in reverse fill order and reconciles the payment", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-reduce",
              "group_id" => "reduce-group"
            }),
            %{
              "operation_id" => "pay-reduce",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "reduce-group",
              "amount_cents" => 12_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "reduce-payment",
              "type" => "reduce_cash_payment",
              "occurred_on" => "2026-10-05",
              "payment_operation_id" => "pay-reduce",
              "amount_cents" => 2_500,
              "expected_revision" => 2
            },
            %{
              "operation_id" => "reduce-too-much",
              "type" => "reduce_cash_payment",
              "occurred_on" => "2026-10-06",
              "payment_operation_id" => "pay-reduce",
              "amount_cents" => 10_000,
              "expected_revision" => 3
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "open-reduce",
                 "status" => "applied",
                 "group_id" => "reduce-group",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-reduce",
                 "status" => "applied",
                 "group_id" => "reduce-group",
                 "amount_cents" => 12_000,
                 "outstanding_deposit_cents" => 7_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "reduce-payment",
                 "status" => "applied",
                 "payment_operation_id" => "pay-reduce",
                 "group_id" => "reduce-group",
                 "amount_cents" => 2_500,
                 "outstanding_deposit_cents" => 10_000,
                 "revision" => 3
               },
               %{
                 "operation_id" => "reduce-too-much",
                 "status" => "rejected",
                 "code" => "reduction_exceeds_held_cash"
               }
             ]

      assert %{"data" => %{"rooms" => rooms, "cash_paid_cents" => 9_500}} =
               get(build_conn(), ~p"/api/v1/groups/reduce-group") |> json_response(200)

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 500}
             ] = rooms

      assert get(build_conn(), ~p"/api/v1/payments/pay-reduce") |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-reduce",
                 "original_group_id" => "reduce-group",
                 "recorded_cents" => 12_000,
                 "held_cents" => 9_500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 2_500,
                 "charged_back_cents" => 0
               }
             }

      assert %{
               "data" => %{
                 "cash_held_cents" => 9_500,
                 "cash_reduced_cents" => 2_500,
                 "cash_charged_back_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "charges back converted cash and absorbs returned shortfalled credit", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-chargeback-source",
              "group_id" => "chargeback-source",
              "guest_id" => "guest-chargeback",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-chargeback-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "chargeback-source",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-source-to-credit",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "chargeback-source",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            },
            open_group_operation(%{
              "operation_id" => "open-chargeback-target",
              "group_id" => "chargeback-target",
              "guest_id" => "guest-chargeback",
              "occurred_on" => "2027-01-11",
              "arrival_on" => "2027-04-01",
              "departure_on" => "2027-04-04"
            }),
            %{
              "operation_id" => "apply-shortfall-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-12",
              "group_id" => "chargeback-target",
              "amount_cents" => 800,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "chargeback-source-payment",
              "type" => "charge_back_payment",
              "occurred_on" => "2027-01-13",
              "payment_operation_id" => "pay-chargeback-source",
              "expected_revision" => 3
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "chargeback-source-payment",
               "status" => "applied",
               "payment_operation_id" => "pay-chargeback-source",
               "group_id" => "chargeback-source",
               "charged_back_cents" => 1_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      assert %{"data" => %{"revision" => 2}} =
               get(build_conn(), ~p"/api/v1/groups/chargeback-target") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/pay-chargeback-source")
             |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-chargeback-source",
                 "original_group_id" => "chargeback-source",
                 "recorded_cents" => 1_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 1_000
               }
             }

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               get(build_conn(), ~p"/api/v1/guests/guest-chargeback/credit?on=2027-01-13")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 1_000,
                 "credit_liability_cents" => 800,
                 "credit_shortfall_cents" => 800
               }
             } = get(build_conn(), ~p"/api/v1/ledger?on=2027-01-13") |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "cancel-shortfalled-target",
              "type" => "cancel_group",
              "occurred_on" => "2027-02-01",
              "group_id" => "chargeback-target",
              "expected_revision" => 2
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "cancel-shortfalled-target",
                   "status" => "applied",
                   "group_id" => "chargeback-target",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               get(build_conn(), ~p"/api/v1/guests/guest-chargeback/credit?on=2027-02-01")
               |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/ledger?on=2027-02-01") |> json_response(200)
    end

    test "transfers held cash in reverse allocation order and replays idempotently", %{
      conn: conn
    } do
      transfer_operation = %{
        "operation_id" => "transfer-cash",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => "transfer-source",
        "destination_group_id" => "transfer-destination",
        "amount_cents" => 5_000,
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      }

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-transfer-source",
              "group_id" => "transfer-source",
              "guest_id" => "guest-transfer"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-destination",
              "group_id" => "transfer-destination",
              "guest_id" => "guest-transfer"
            }),
            %{
              "operation_id" => "pay-transfer-old",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "transfer-source",
              "amount_cents" => 9_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "pay-transfer-new",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "transfer-source",
              "amount_cents" => 4_000,
              "expected_revision" => 2
            },
            transfer_operation
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "transfer-cash",
               "status" => "applied",
               "source_group_id" => "transfer-source",
               "destination_group_id" => "transfer-destination",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 11_500,
               "destination_outstanding_deposit_cents" => 14_500,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert %{"data" => source} =
               get(build_conn(), ~p"/api/v1/groups/transfer-source") |> json_response(200)

      assert source["revision"] == 4
      assert source["cash_paid_cents"] == 8_000
      assert source["outstanding_deposit_cents"] == 11_500

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 8_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = source["rooms"]

      assert %{"data" => destination} =
               get(build_conn(), ~p"/api/v1/groups/transfer-destination")
               |> json_response(200)

      assert destination["revision"] == 2
      assert destination["cash_paid_cents"] == 5_000
      assert destination["outstanding_deposit_cents"] == 14_500

      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 5_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = destination["rooms"]

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-old") |> json_response(200) ==
               %{
                 "data" => %{
                   "payment_operation_id" => "pay-transfer-old",
                   "original_group_id" => "transfer-source",
                   "recorded_cents" => 9_000,
                   "held_cents" => 9_000,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0,
                   "held_by_group" => [
                     %{"group_id" => "transfer-destination", "amount_cents" => 1_000},
                     %{"group_id" => "transfer-source", "amount_cents" => 8_000}
                   ]
                 }
               }

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-new") |> json_response(200) ==
               %{
                 "data" => %{
                   "payment_operation_id" => "pay-transfer-new",
                   "original_group_id" => "transfer-source",
                   "recorded_cents" => 4_000,
                   "held_cents" => 4_000,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0,
                   "held_by_group" => [
                     %{"group_id" => "transfer-destination", "amount_cents" => 4_000}
                   ]
                 }
               }

      assert %{
               "data" => %{
                 "cash_held_cents" => 13_000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [transfer_operation]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "transfer-cash",
                   "status" => "applied",
                   "source_group_id" => "transfer-source",
                   "destination_group_id" => "transfer-destination",
                   "amount_cents" => 5_000,
                   "source_outstanding_deposit_cents" => 11_500,
                   "destination_outstanding_deposit_cents" => 14_500,
                   "source_revision" => 4,
                   "destination_revision" => 2
                 }
               ]
             }

      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 8_000}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-source") |> json_response(200)

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5_000}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-destination")
               |> json_response(200)
    end

    test "returns stable transfer rejection codes without changing funding", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-transfer-errors-source",
              "group_id" => "transfer-errors-source",
              "guest_id" => "guest-transfer-errors"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-errors-dest",
              "group_id" => "transfer-errors-dest",
              "guest_id" => "guest-transfer-errors"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-errors-other",
              "group_id" => "transfer-errors-other",
              "guest_id" => "guest-transfer-other"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-errors-inactive",
              "group_id" => "transfer-errors-inactive",
              "guest_id" => "guest-transfer-errors"
            }),
            %{
              "operation_id" => "pay-transfer-errors",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "transfer-errors-source",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-transfer-errors-inactive",
              "type" => "cancel_group",
              "occurred_on" => "2026-11-20",
              "group_id" => "transfer-errors-inactive",
              "expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-missing-source",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "missing-source",
              "destination_group_id" => "transfer-errors-dest",
              "amount_cents" => 100
            },
            %{
              "operation_id" => "transfer-missing-dest",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "missing-dest",
              "amount_cents" => 100
            },
            %{
              "operation_id" => "transfer-stale-source",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-dest",
              "amount_cents" => 0,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-stale-dest",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-dest",
              "amount_cents" => 0,
              "expected_revision" => 2,
              "destination_expected_revision" => 0
            },
            %{
              "operation_id" => "transfer-same-group",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-source",
              "amount_cents" => 100,
              "expected_revision" => 2,
              "destination_expected_revision" => 2
            },
            %{
              "operation_id" => "transfer-different-guests",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-other",
              "amount_cents" => 100,
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-inactive-dest",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-inactive",
              "amount_cents" => 100,
              "expected_revision" => 2,
              "destination_expected_revision" => 2
            },
            %{
              "operation_id" => "transfer-invalid-amount",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-dest",
              "amount_cents" => 0,
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-too-much-funding",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-errors-source",
              "destination_group_id" => "transfer-errors-dest",
              "amount_cents" => 1_001,
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            }
          ]
        })

      assert Enum.drop(json_response(conn, 200)["results"], 6) == [
               %{
                 "operation_id" => "transfer-missing-source",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-source"
               },
               %{
                 "operation_id" => "transfer-missing-dest",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-dest"
               },
               %{
                 "operation_id" => "transfer-stale-source",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "transfer-errors-source",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               },
               %{
                 "operation_id" => "transfer-stale-dest",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "transfer-errors-dest",
                 "expected_revision" => 0,
                 "actual_revision" => 1
               },
               %{
                 "operation_id" => "transfer-same-group",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               },
               %{
                 "operation_id" => "transfer-different-guests",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               },
               %{
                 "operation_id" => "transfer-inactive-dest",
                 "status" => "rejected",
                 "code" => "group_not_active",
                 "group_id" => "transfer-errors-inactive"
               },
               %{
                 "operation_id" => "transfer-invalid-amount",
                 "status" => "rejected",
                 "code" => "invalid_amount"
               },
               %{
                 "operation_id" => "transfer-too-much-funding",
                 "status" => "rejected",
                 "code" => "transfer_exceeds_held_funding"
               }
             ]

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 1_000}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-errors-source")
               |> json_response(200)

      assert %{"data" => %{"revision" => 1, "cash_paid_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-errors-dest")
               |> json_response(200)
    end

    test "rejects transfers that exceed destination outstanding deposit", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-transfer-full-source",
              "group_id" => "transfer-full-source",
              "guest_id" => "guest-transfer-full"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-full-dest",
              "group_id" => "transfer-full-dest",
              "guest_id" => "guest-transfer-full"
            }),
            %{
              "operation_id" => "pay-transfer-full-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "transfer-full-source",
              "amount_cents" => 2_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "pay-transfer-full-dest",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "transfer-full-dest",
              "amount_cents" => 19_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-too-much-outstanding",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-full-source",
              "destination_group_id" => "transfer-full-dest",
              "amount_cents" => 1_000,
              "expected_revision" => 2,
              "destination_expected_revision" => 2
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "transfer-too-much-outstanding",
               "status" => "rejected",
               "code" => "transfer_exceeds_outstanding"
             }

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 2_000}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-full-source")
               |> json_response(200)

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 19_000}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-full-dest")
               |> json_response(200)
    end

    test "transfers applied hotel credit and restores it from the destination", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-transfer-credit-origin",
              "group_id" => "transfer-credit-origin",
              "guest_id" => "guest-transfer-credit",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-transfer-credit-origin",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "transfer-credit-origin",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-transfer-credit-origin",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "transfer-credit-origin",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            },
            open_group_operation(%{
              "operation_id" => "open-transfer-credit-source",
              "group_id" => "transfer-credit-source",
              "guest_id" => "guest-transfer-credit",
              "occurred_on" => "2027-01-11",
              "arrival_on" => "2027-04-01",
              "departure_on" => "2027-04-04"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-credit-dest",
              "group_id" => "transfer-credit-dest",
              "guest_id" => "guest-transfer-credit",
              "occurred_on" => "2027-01-11",
              "arrival_on" => "2027-04-01",
              "departure_on" => "2027-04-04"
            }),
            %{
              "operation_id" => "apply-transfer-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-12",
              "group_id" => "transfer-credit-source",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-credit",
              "type" => "transfer_deposit",
              "occurred_on" => "2027-01-13",
              "source_group_id" => "transfer-credit-source",
              "destination_group_id" => "transfer-credit-dest",
              "amount_cents" => 1_000,
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-transfer-credit-dest",
              "type" => "cancel_group",
              "occurred_on" => "2027-02-01",
              "group_id" => "transfer-credit-dest",
              "expected_revision" => 2
            }
          ]
        })

      assert Enum.slice(json_response(conn, 200)["results"], 5, 3) == [
               %{
                 "operation_id" => "apply-transfer-credit",
                 "status" => "applied",
                 "group_id" => "transfer-credit-source",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "transfer-credit",
                 "status" => "applied",
                 "source_group_id" => "transfer-credit-source",
                 "destination_group_id" => "transfer-credit-dest",
                 "amount_cents" => 1_000,
                 "source_outstanding_deposit_cents" => 19_500,
                 "destination_outstanding_deposit_cents" => 18_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               },
               %{
                 "operation_id" => "cancel-transfer-credit-dest",
                 "status" => "applied",
                 "group_id" => "transfer-credit-dest",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]

      assert %{"data" => %{"revision" => 3, "credit_paid_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-credit-source")
               |> json_response(200)

      assert %{"data" => %{"revision" => 3, "status" => "cancelled"}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-credit-dest")
               |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 1_100,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-transfer-credit-origin",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2028-01-10"
                   }
                 ]
               }
             } =
               get(build_conn(), ~p"/api/v1/guests/guest-transfer-credit/credit?on=2027-02-01")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 1_100}} =
               get(build_conn(), ~p"/api/v1/ledger?on=2027-02-01") |> json_response(200)
    end

    test "reductions and chargebacks follow transferred payment cash across groups", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-transfer-correction-source",
              "group_id" => "transfer-correction-source",
              "guest_id" => "guest-transfer-correction"
            }),
            open_group_operation(%{
              "operation_id" => "open-transfer-correction-dest",
              "group_id" => "transfer-correction-dest",
              "guest_id" => "guest-transfer-correction"
            }),
            %{
              "operation_id" => "pay-transfer-correction-old",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "transfer-correction-source",
              "amount_cents" => 9_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "pay-transfer-correction-new",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "transfer-correction-source",
              "amount_cents" => 4_000,
              "expected_revision" => 2
            },
            %{
              "operation_id" => "transfer-correction",
              "type" => "transfer_deposit",
              "occurred_on" => "2026-10-06",
              "source_group_id" => "transfer-correction-source",
              "destination_group_id" => "transfer-correction-dest",
              "amount_cents" => 5_000,
              "expected_revision" => 3,
              "destination_expected_revision" => 1
            },
            %{
              "operation_id" => "reduce-transferred-payment",
              "type" => "reduce_cash_payment",
              "occurred_on" => "2026-10-07",
              "payment_operation_id" => "pay-transfer-correction-old",
              "amount_cents" => 1_000,
              "expected_revision" => 4
            },
            %{
              "operation_id" => "chargeback-transferred-payment",
              "type" => "charge_back_payment",
              "occurred_on" => "2026-10-08",
              "payment_operation_id" => "pay-transfer-correction-new",
              "expected_revision" => 5
            }
          ]
        })

      assert Enum.slice(json_response(conn, 200)["results"], 5, 2) == [
               %{
                 "operation_id" => "reduce-transferred-payment",
                 "status" => "applied",
                 "payment_operation_id" => "pay-transfer-correction-old",
                 "group_id" => "transfer-correction-source",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 5
               },
               %{
                 "operation_id" => "chargeback-transferred-payment",
                 "status" => "applied",
                 "payment_operation_id" => "pay-transfer-correction-new",
                 "group_id" => "transfer-correction-source",
                 "charged_back_cents" => 4_000,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 6
               }
             ]

      assert %{"data" => %{"revision" => 6, "cash_paid_cents" => 8_000}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-correction-source")
               |> json_response(200)

      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} =
               get(build_conn(), ~p"/api/v1/groups/transfer-correction-dest")
               |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-correction-old")
             |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-transfer-correction-old",
                 "original_group_id" => "transfer-correction-source",
                 "recorded_cents" => 9_000,
                 "held_cents" => 8_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1_000,
                 "charged_back_cents" => 0,
                 "held_by_group" => [
                   %{"group_id" => "transfer-correction-source", "amount_cents" => 8_000}
                 ]
               }
             }

      assert get(build_conn(), ~p"/api/v1/payments/pay-transfer-correction-new")
             |> json_response(200) == %{
               "data" => %{
                 "payment_operation_id" => "pay-transfer-correction-new",
                 "original_group_id" => "transfer-correction-source",
                 "recorded_cents" => 4_000,
                 "held_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 4_000,
                 "held_by_group" => []
               }
             }

      assert %{
               "data" => %{
                 "cash_held_cents" => 8_000,
                 "cash_reduced_cents" => 1_000,
                 "cash_charged_back_cents" => 4_000
               }
             } = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200)
    end

    test "returns stable payment reconciliation errors", %{conn: conn} do
      assert get(conn, ~p"/api/v1/payments/missing-payment") |> json_response(404) ==
               %{"error" => %{"code" => "operation_not_found"}}

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-not-payment",
              "group_id" => "not-payment"
            })
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/payments/open-not-payment") |> json_response(422) ==
               %{"error" => %{"code" => "payment_not_reconcilable"}}
    end

    test "starts finance reporting with an opening position and same-batch movements", %{
      conn: conn
    } do
      assert get(conn, ~p"/api/v1/finance/daily-report") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=not-a-date")
             |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-05")
             |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}

      assert post(build_conn(), ~p"/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "invalid-reporting-start",
                   "type" => "start_finance_reporting"
                 }
               ]
             })
             |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "invalid-reporting-start",
                   "status" => "rejected",
                   "code" => "invalid_reporting_date"
                 }
               ]
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            open_group_operation(%{
              "operation_id" => "open-reporting-opening",
              "group_id" => "reporting-opening",
              "occurred_on" => "2027-01-03",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "ams-canal"
            }),
            %{
              "operation_id" => "pay-reporting-opening",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-03",
              "group_id" => "reporting-opening",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "start-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-05"
            },
            open_group_operation(%{
              "operation_id" => "open-reporting-after-start",
              "group_id" => "reporting-after-start",
              "occurred_on" => "2027-01-04",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "rot-harbor"
            }),
            %{
              "operation_id" => "pay-reporting-after-start",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-04",
              "group_id" => "reporting-after-start",
              "amount_cents" => 500,
              "expected_revision" => 1
            }
          ]
        })

      assert Enum.at(json_response(conn, 200)["results"], 2) == %{
               "operation_id" => "start-reporting",
               "status" => "applied",
               "starts_on" => "2027-01-05"
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(404) ==
               %{"error" => %{"code" => "report_not_available"}}

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-05")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-05",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry("ams-canal", 1_000, cash_movements(), 1_000),
                   cash_report_entry(
                     "rot-harbor",
                     0,
                     cash_movements(%{"received_cents" => 500}),
                     500
                   )
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" => late_adjustments()
               }
             }

      assert post(build_conn(), ~p"/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "start-reporting",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2027-01-05"
                 }
               ]
             })
             |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "start-reporting",
                   "status" => "applied",
                   "starts_on" => "2027-01-05"
                 }
               ]
             }

      assert post(build_conn(), ~p"/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "start-reporting-again",
                   "type" => "start_finance_reporting",
                   "starts_on" => "2027-01-06"
                 }
               ]
             })
             |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "start-reporting-again",
                   "status" => "rejected",
                   "code" => "reporting_already_started"
                 }
               ]
             }
    end

    test "daily cash report follows transfers and reductions to affected properties", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-transfer-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            open_group_operation(%{
              "operation_id" => "open-report-transfer-source",
              "group_id" => "report-transfer-source",
              "guest_id" => "guest-report-transfer",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "ams-canal"
            }),
            open_group_operation(%{
              "operation_id" => "open-report-transfer-dest",
              "group_id" => "report-transfer-dest",
              "guest_id" => "guest-report-transfer",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "rot-harbor"
            }),
            %{
              "operation_id" => "pay-report-transfer",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "report-transfer-source",
              "amount_cents" => 9_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "transfer-report-cash",
              "type" => "transfer_deposit",
              "occurred_on" => "2027-01-03",
              "source_group_id" => "report-transfer-source",
              "destination_group_id" => "report-transfer-dest",
              "amount_cents" => 4_000,
              "expected_revision" => 2,
              "destination_expected_revision" => 1
            },
            %{
              "operation_id" => "reduce-report-transferred-cash",
              "type" => "reduce_cash_payment",
              "occurred_on" => "2027-01-04",
              "payment_operation_id" => "pay-report-transfer",
              "amount_cents" => 1_000,
              "expected_revision" => 3
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "reduce-report-transferred-cash",
               "status" => "applied",
               "payment_operation_id" => "pay-report-transfer",
               "group_id" => "report-transfer-source",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 4
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-03")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-03",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry(
                     "ams-canal",
                     9_000,
                     cash_movements(%{"transferred_out_cents" => 4_000}),
                     5_000
                   ),
                   cash_report_entry(
                     "rot-harbor",
                     0,
                     cash_movements(%{"transferred_in_cents" => 4_000}),
                     4_000
                   )
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" => late_adjustments()
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-04",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry("ams-canal", 5_000, cash_movements(), 5_000),
                   cash_report_entry(
                     "rot-harbor",
                     4_000,
                     cash_movements(%{"reduced_cents" => 1_000}),
                     3_000
                   )
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" => late_adjustments()
               }
             }
    end

    test "daily cash report signs chargeback reclassification of settled cash", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-chargeback-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            open_group_operation(%{
              "operation_id" => "open-report-chargeback",
              "group_id" => "report-chargeback",
              "guest_id" => "guest-report-chargeback",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "ams-canal"
            }),
            %{
              "operation_id" => "pay-report-chargeback",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "report-chargeback",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-report-chargeback",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-03",
              "group_id" => "report-chargeback",
              "expected_revision" => 2
            },
            %{
              "operation_id" => "chargeback-report-refund",
              "type" => "charge_back_payment",
              "occurred_on" => "2027-01-04",
              "payment_operation_id" => "pay-report-chargeback",
              "expected_revision" => 3
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "chargeback-report-refund",
               "status" => "applied",
               "payment_operation_id" => "pay-report-chargeback",
               "group_id" => "report-chargeback",
               "charged_back_cents" => 1_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-03")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-03",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry(
                     "ams-canal",
                     1_000,
                     cash_movements(%{"refunded_cents" => 1_000}),
                     0
                   )
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" => late_adjustments()
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-04",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry(
                     "ams-canal",
                     0,
                     cash_movements(%{
                       "refunded_cents" => -1_000,
                       "charged_back_cents" => 1_000
                     }),
                     0
                   )
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" => late_adjustments()
               }
             }
    end

    test "daily credit report includes issued liability and passive expiry", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-credit-expiry-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            open_group_operation(%{
              "operation_id" => "open-report-credit-expiry",
              "group_id" => "report-credit-expiry",
              "guest_id" => "guest-report-credit-expiry",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-report-credit-expiry",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "report-credit-expiry",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-report-credit-expiry",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "report-credit-expiry",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "cancel-report-credit-expiry",
               "status" => "applied",
               "group_id" => "report-credit-expiry",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_100,
               "revision" => 3
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-10")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-10",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry(
                     "ams-canal",
                     1_000,
                     cash_movements(%{"converted_to_credit_cents" => 1_000}),
                     0
                   )
                 ],
                 "credit" =>
                   credit_report_entry(
                     0,
                     credit_movements(%{"issued_cents" => 1_100}),
                     1_100
                   ),
                 "late_adjustments" => late_adjustments()
               }
             }

      expiry_report =
        get(build_conn(), ~p"/api/v1/finance/daily-report?date=2028-01-11")
        |> json_response(200)

      assert expiry_report == %{
               "data" => %{
                 "date" => "2028-01-11",
                 "status" => "open",
                 "cash" => [],
                 "credit" =>
                   credit_report_entry(
                     1_100,
                     credit_movements(%{"expired_cents" => 1_100}),
                     0
                   ),
                 "late_adjustments" => late_adjustments()
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2028-01-11")
             |> json_response(200) == expiry_report
    end

    test "daily credit report tracks revocation and shortfall absorption", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-credit-shortfall-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            open_group_operation(%{
              "operation_id" => "open-report-shortfall-source",
              "group_id" => "report-shortfall-source",
              "guest_id" => "guest-report-shortfall",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04"
            }),
            %{
              "operation_id" => "pay-report-shortfall-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "report-shortfall-source",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-report-shortfall-source",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-10",
              "group_id" => "report-shortfall-source",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            },
            open_group_operation(%{
              "operation_id" => "open-report-shortfall-target",
              "group_id" => "report-shortfall-target",
              "guest_id" => "guest-report-shortfall",
              "occurred_on" => "2027-01-11",
              "arrival_on" => "2027-04-01",
              "departure_on" => "2027-04-04"
            }),
            %{
              "operation_id" => "apply-report-shortfall-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-12",
              "group_id" => "report-shortfall-target",
              "amount_cents" => 800,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "chargeback-report-shortfall-source",
              "type" => "charge_back_payment",
              "occurred_on" => "2027-01-13",
              "payment_operation_id" => "pay-report-shortfall-source",
              "expected_revision" => 3
            },
            %{
              "operation_id" => "cancel-report-shortfall-target",
              "type" => "cancel_group",
              "occurred_on" => "2027-02-01",
              "group_id" => "report-shortfall-target",
              "expected_revision" => 2
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "cancel-report-shortfall-target",
               "status" => "applied",
               "group_id" => "report-shortfall-target",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-13")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-13",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry(
                     "ams-canal",
                     0,
                     cash_movements(%{
                       "converted_to_credit_cents" => -1_000,
                       "charged_back_cents" => 1_000
                     }),
                     0
                   )
                 ],
                 "credit" =>
                   credit_report_entry(
                     1_100,
                     credit_movements(%{"revoked_cents" => 300}),
                     800
                   ),
                 "late_adjustments" => late_adjustments()
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-02-01")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-02-01",
                 "status" => "open",
                 "cash" => [],
                 "credit" =>
                   credit_report_entry(
                     800,
                     credit_movements(%{"absorbed_cents" => 800}),
                     0
                   ),
                 "late_adjustments" => late_adjustments()
               }
             }
    end

    test "validates and replays finance period closes", %{conn: conn} do
      assert post(conn, ~p"/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "close-before-reporting",
                   "type" => "close_finance_period",
                   "period_end_on" => "2027-01-01"
                 }
               ]
             })
             |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "close-before-reporting",
                   "status" => "rejected",
                   "code" => "invalid_period"
                 }
               ]
             }

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-close-validation",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            %{
              "operation_id" => "close-before-start",
              "type" => "close_finance_period",
              "period_end_on" => "2026-12-31"
            },
            %{
              "operation_id" => "close-through-start",
              "type" => "close_finance_period",
              "period_end_on" => "2027-01-01"
            },
            %{
              "operation_id" => "close-same-period",
              "type" => "close_finance_period",
              "period_end_on" => "2027-01-01"
            }
          ]
        })

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "start-close-validation",
                 "status" => "applied",
                 "starts_on" => "2027-01-01"
               },
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               },
               %{
                 "operation_id" => "close-through-start",
                 "status" => "applied",
                 "period_end_on" => "2027-01-01"
               },
               %{
                 "operation_id" => "close-same-period",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]

      assert post(build_conn(), ~p"/api/v1/partner-batches", %{
               "operations" => [
                 %{
                   "operation_id" => "close-through-start",
                   "type" => "close_finance_period",
                   "period_end_on" => "2027-01-01"
                 }
               ]
             })
             |> json_response(200) == %{
               "results" => [
                 %{
                   "operation_id" => "close-through-start",
                   "status" => "applied",
                   "period_end_on" => "2027-01-01"
                 }
               ]
             }
    end

    test "freezes closed reports and posts old corrections as late adjustments", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-close-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            open_group_operation(%{
              "operation_id" => "open-close-reporting",
              "group_id" => "close-reporting",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "ams-canal"
            }),
            %{
              "operation_id" => "pay-close-reporting",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "close-reporting",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "cancel-close-reporting",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-03",
              "group_id" => "close-reporting",
              "expected_revision" => 2
            },
            %{
              "operation_id" => "close-through-refund",
              "type" => "close_finance_period",
              "period_end_on" => "2027-01-03"
            },
            %{
              "operation_id" => "late-chargeback-refund",
              "type" => "charge_back_payment",
              "occurred_on" => "2027-01-02",
              "payment_operation_id" => "pay-close-reporting",
              "expected_revision" => 3
            },
            %{
              "operation_id" => "close-through-late-adjustment",
              "type" => "close_finance_period",
              "period_end_on" => "2027-01-04"
            }
          ]
        })

      assert Enum.slice(json_response(conn, 200)["results"], 4, 3) == [
               %{
                 "operation_id" => "close-through-refund",
                 "status" => "applied",
                 "period_end_on" => "2027-01-03"
               },
               %{
                 "operation_id" => "late-chargeback-refund",
                 "status" => "applied",
                 "payment_operation_id" => "pay-close-reporting",
                 "group_id" => "close-reporting",
                 "charged_back_cents" => 1_000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 4
               },
               %{
                 "operation_id" => "close-through-late-adjustment",
                 "status" => "applied",
                 "period_end_on" => "2027-01-04"
               }
             ]

      closed_refund_report =
        get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-03")
        |> json_response(200)

      assert closed_refund_report == %{
               "data" => %{
                 "date" => "2027-01-03",
                 "status" => "closed",
                 "cash" => [
                   cash_report_entry(
                     "ams-canal",
                     1_000,
                     cash_movements(%{"refunded_cents" => 1_000}),
                     0
                   )
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" => late_adjustments()
               }
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-03")
             |> json_response(200) == closed_refund_report

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-04")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-04",
                 "status" => "closed",
                 "cash" => [
                   cash_report_entry("ams-canal", 0, cash_movements(), 0)
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 0),
                 "late_adjustments" =>
                   late_adjustments(%{
                     "cash" => [
                       %{
                         "property_id" => "ams-canal",
                         "movements" =>
                           cash_movements(%{
                             "refunded_cents" => -1_000,
                             "charged_back_cents" => 1_000
                           })
                       }
                     ]
                   })
               }
             }
    end

    test "reports late credit movements in the first open period", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "start-late-credit-reporting",
              "type" => "start_finance_reporting",
              "starts_on" => "2027-01-01"
            },
            open_group_operation(%{
              "operation_id" => "open-late-credit-source",
              "group_id" => "late-credit-source",
              "guest_id" => "guest-late-credit",
              "occurred_on" => "2027-01-01",
              "arrival_on" => "2027-03-01",
              "departure_on" => "2027-03-04",
              "property_id" => "ams-canal"
            }),
            %{
              "operation_id" => "pay-late-credit-source",
              "type" => "record_cash_payment",
              "occurred_on" => "2027-01-02",
              "group_id" => "late-credit-source",
              "amount_cents" => 1_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "close-before-credit-cancel",
              "type" => "close_finance_period",
              "period_end_on" => "2027-01-05"
            },
            %{
              "operation_id" => "late-credit-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2027-01-03",
              "group_id" => "late-credit-source",
              "refund_method" => "hotel_credit",
              "expected_revision" => 2
            }
          ]
        })

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "late-credit-cancel",
               "status" => "applied",
               "group_id" => "late-credit-source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_100,
               "revision" => 3
             }

      assert get(build_conn(), ~p"/api/v1/finance/daily-report?date=2027-01-06")
             |> json_response(200) == %{
               "data" => %{
                 "date" => "2027-01-06",
                 "status" => "open",
                 "cash" => [
                   cash_report_entry("ams-canal", 1_000, cash_movements(), 0)
                 ],
                 "credit" => credit_report_entry(0, credit_movements(), 1_100),
                 "late_adjustments" =>
                   late_adjustments(%{
                     "cash" => [
                       %{
                         "property_id" => "ams-canal",
                         "movements" =>
                           cash_movements(%{
                             "converted_to_credit_cents" => 1_000
                           })
                       }
                     ],
                     "credit" => credit_movements(%{"issued_cents" => 1_100})
                   })
               }
             }
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

  defp cash_report_entry(property_id, opening_held_cents, movements, closing_held_cents) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening_held_cents,
      "movements" => movements,
      "closing_held_cents" => closing_held_cents
    }
  end

  defp cash_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit_report_entry(opening_liability_cents, movements, closing_liability_cents) do
    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => movements,
      "closing_liability_cents" => closing_liability_cents
    }
  end

  defp credit_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end

  defp late_adjustments(overrides \\ %{}) do
    Map.merge(
      %{
        "cash" => [],
        "credit" => credit_movements()
      },
      overrides
    )
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", body)
  end
end
