defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "opens a flexible group and exposes it through reads", %{conn: conn} do
      open_group = %{
        "operation_id" => "op-1001",
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

      conn = post(conn, ~p"/api/v1/partner-batches", %{"operations" => [open_group]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
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

      conn = get(build_conn(), ~p"/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "applies payments, reschedules, and refundable cancellation in batch order", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("group-sequence"),
            %{
              "operation_id" => "op-pay",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-sequence",
              "amount_cents" => 4_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-move",
              "type" => "reschedule_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-sequence",
              "new_arrival_on" => "2026-12-20",
              "expected_revision" => 2
            },
            %{
              "operation_id" => "op-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-12-01",
              "group_id" => "group-sequence",
              "expected_revision" => 3
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open-group-sequence",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "deposit_due_cents" => 10_000,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "amount_cents" => 4_000,
                   "outstanding_deposit_cents" => 6_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-move",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-22",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "applied",
                   "group_id" => "group-sequence",
                   "refunded_cents" => 4_000,
                   "retained_cents" => 0,
                   "revision" => 4
                 }
               ]
             }

      assert %{
               "data" => %{
                 "revision" => 4,
                 "arrival_on" => "2026-12-20",
                 "departure_on" => "2026-12-22",
                 "status" => "cancelled",
                 "deposit_paid_cents" => 4_000,
                 "outstanding_deposit_cents" => 0
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-sequence") |> json_response(200)

      assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 4_000,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "retains advance-purchase payments on cancellation", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-open-advance",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "group-advance",
              "guest_id" => "guest-advance",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-12",
              "rate_plan" => "advance_purchase",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 12_000}
              ]
            },
            %{
              "operation_id" => "op-pay-advance",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-advance",
              "amount_cents" => 24_000
            },
            %{
              "operation_id" => "op-cancel-advance",
              "type" => "cancel_group",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-advance"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"deposit_due_cents" => 24_000, "revision" => 1},
                 %{"outstanding_deposit_cents" => 0, "revision" => 2},
                 %{"refunded_cents" => 0, "retained_cents" => 24_000, "revision" => 3}
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 24_000
               }
             }
    end

    test "rounds flexible deposits per room before summing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "op-rounding",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "group-rounding",
              "guest_id" => "guest-rounding",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rate_plan" => "flexible",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 3},
                %{"room_id" => "room-b", "nightly_rate_cents" => 3}
              ]
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-rounding",
                   "status" => "applied",
                   "group_id" => "group-rounding",
                   "deposit_due_cents" => 2,
                   "revision" => 1
                 }
               ]
             }
    end

    test "rejects stale revisions before domain validation and keeps processing", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("group-revisions"),
            %{
              "operation_id" => "op-first-payment",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-revisions",
              "amount_cents" => 2_000,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-stale-invalid",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-05",
              "group_id" => "group-revisions",
              "amount_cents" => -100,
              "expected_revision" => 1
            },
            %{
              "operation_id" => "op-next-payment",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-06",
              "group_id" => "group-revisions",
              "amount_cents" => 1_000
            }
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open-group-revisions",
                   "status" => "applied",
                   "group_id" => "group-revisions",
                   "deposit_due_cents" => 10_000,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-first-payment",
                   "status" => "applied",
                   "group_id" => "group-revisions",
                   "amount_cents" => 2_000,
                   "outstanding_deposit_cents" => 8_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-stale-invalid",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-revisions",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-next-payment",
                   "status" => "applied",
                   "group_id" => "group-revisions",
                   "amount_cents" => 1_000,
                   "outstanding_deposit_cents" => 7_000,
                   "revision" => 3
                 }
               ]
             }

      assert %{
               "data" => %{
                 "revision" => 3,
                 "deposit_paid_cents" => 3_000,
                 "outstanding_deposit_cents" => 7_000
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-revisions") |> json_response(200)
    end

    test "rejects invalid operations without rolling back earlier or later operations", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "bad-stay",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "bad-stay",
              "guest_id" => "guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-10",
              "rate_plan" => "flexible",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
            },
            %{
              "operation_id" => "bad-rooms",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "bad-rooms",
              "guest_id" => "guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rate_plan" => "flexible",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
                %{"room_id" => "room-a", "nightly_rate_cents" => 11_000}
              ]
            },
            %{
              "operation_id" => "bad-rate",
              "type" => "open_group",
              "occurred_on" => "2026-10-03",
              "group_id" => "bad-rate",
              "guest_id" => "guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-10",
              "departure_on" => "2026-12-11",
              "rate_plan" => "mystery",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
            },
            flexible_open("valid-after-invalid")
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "bad-stay",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{
                   "operation_id" => "bad-rooms",
                   "status" => "rejected",
                   "code" => "invalid_rooms"
                 },
                 %{
                   "operation_id" => "bad-rate",
                   "status" => "rejected",
                   "code" => "invalid_rate_plan"
                 },
                 %{
                   "operation_id" => "op-open-valid-after-invalid",
                   "status" => "applied",
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      assert get(build_conn(), ~p"/api/v1/groups/bad-stay") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }

      assert get(build_conn(), ~p"/api/v1/groups/valid-after-invalid") |> json_response(200)
    end

    test "rejects duplicate group identifiers without replacing the original", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            flexible_open("group-duplicate"),
            %{
              "operation_id" => "op-duplicate",
              "type" => "open_group",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-duplicate",
              "guest_id" => "replacement-guest",
              "property_id" => "ams-canal",
              "arrival_on" => "2026-12-20",
              "departure_on" => "2026-12-22",
              "rate_plan" => "advance_purchase",
              "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 99_999}]
            }
          ]
        })

      assert %{
               "results" => [
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-duplicate",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "guest_id" => "guest-group-duplicate",
                 "arrival_on" => "2026-12-10",
                 "rate_plan" => "flexible",
                 "deposit_due_cents" => 10_000,
                 "revision" => 1
               }
             } = get(build_conn(), ~p"/api/v1/groups/group-duplicate") |> json_response(200)
    end

    test "rejects group operations for missing groups, inactive groups, and bad amounts", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "missing-with-revision",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-03",
              "group_id" => "missing",
              "amount_cents" => 100,
              "expected_revision" => 99
            },
            flexible_open("group-errors"),
            %{
              "operation_id" => "bad-amount",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-errors",
              "amount_cents" => 0
            },
            %{
              "operation_id" => "too-much",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-04",
              "group_id" => "group-errors",
              "amount_cents" => 10_001
            },
            %{
              "operation_id" => "cancel",
              "type" => "cancel_group",
              "occurred_on" => "2026-12-01",
              "group_id" => "group-errors"
            },
            %{
              "operation_id" => "pay-cancelled",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-12-02",
              "group_id" => "group-errors",
              "amount_cents" => 100
            }
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "missing-with-revision",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 },
                 %{"status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "bad-amount",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "too-much",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{"operation_id" => "cancel", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "pay-cancelled",
                   "status" => "rejected",
                   "code" => "group_not_active"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects unknown and structurally invalid operations", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          "operations" => [
            %{
              "operation_id" => "unknown",
              "type" => "something_else",
              "occurred_on" => "2026-10-03"
            },
            %{
              "operation_id" => "missing-group",
              "type" => "record_cash_payment",
              "occurred_on" => "2026-10-03"
            },
            "not-an-object"
          ]
        })

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{
                   "operation_id" => "missing-group",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 },
                 %{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}
               ]
             }
    end

    test "rejects invalid batch bodies", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns group_not_found for missing groups", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/groups/missing")

      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  defp flexible_open(group_id) do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-#{group_id}",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-12",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 25_000}
      ]
    }
  end
end
