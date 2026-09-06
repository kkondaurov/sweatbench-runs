defmodule GroupStayWeb.GroupReservationsAPITest do
  use GroupStayWeb.ConnCase

  alias GroupStay.GroupReservations.PartnerOperation
  alias GroupStay.Repo

  describe "POST /api/v1/partner-batches" do
    test "rounds flexible deposits per room and ignores expected_revision on open", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              group_id: "rounded",
              expected_revision: 99,
              arrival_on: "2026-12-10",
              departure_on: "2026-12-11",
              rooms: [
                %{room_id: "room-a", nightly_rate_cents: 10_002},
                %{room_id: "room-b", nightly_rate_cents: 10_002},
                %{room_id: "room-c", nightly_rate_cents: 10_002}
              ]
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "rounded",
                   "deposit_due_cents" => 6_000,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "opens a flexible group and returns it with original room order", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              rooms: [
                %{room_id: "room-a", nightly_rate_cents: 15_001},
                %{room_id: "room-b", nightly_rate_cents: 17_502}
              ]
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_502,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")

      assert %{
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
                 "lodging_total_cents" => 97_509,
                 "deposit_due_cents" => 19_502,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_502,
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_502}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "processes operations in order and continues after rejected operations", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "op-1", group_id: "ordered"}),
            %{
              operation_id: "op-2",
              type: "record_cash_payment",
              group_id: "ordered",
              amount_cents: 10_000,
              expected_revision: 1
            },
            %{
              operation_id: "op-3",
              type: "record_cash_payment",
              group_id: "ordered",
              amount_cents: 1,
              expected_revision: 1
            },
            %{
              operation_id: "op-4",
              type: "record_cash_payment",
              group_id: "ordered",
              amount_cents: 9_500,
              expected_revision: 2
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-1", "status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "op-2",
                   "status" => "applied",
                   "amount_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-3",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "ordered",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "op-4",
                   "status" => "applied",
                   "amount_cents" => 9_500,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = get(build_conn(), ~p"/api/v1/groups/ordered")

      assert %{
               "data" => %{
                 "revision" => 3,
                 "deposit_paid_cents" => 19_500,
                 "outstanding_deposit_cents" => 0
               }
             } = json_response(conn, 200)
    end

    test "rejects invalid batches", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{not_operations: []})

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "rejects invalid opening operations without creating a group", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              operation_id: "bad-stay",
              group_id: "bad-stay",
              departure_on: "2026-12-10"
            }),
            open_group_operation(%{
              operation_id: "bad-rooms",
              group_id: "bad-rooms",
              rooms: [
                %{room_id: "room-a", nightly_rate_cents: 10_000},
                %{room_id: "room-a", nightly_rate_cents: 12_000}
              ]
            }),
            open_group_operation(%{
              operation_id: "bad-rate",
              group_id: "bad-rate",
              rate_plan: "seasonal"
            }),
            open_group_operation(%{operation_id: "created", group_id: "created"}),
            open_group_operation(%{operation_id: "duplicate", group_id: "created"}),
            %{operation_id: "unknown", type: "sleep_group"}
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
                 %{"operation_id" => "created", "status" => "applied"},
                 %{
                   "operation_id" => "duplicate",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 },
                 %{
                   "operation_id" => "unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 }
               ]
             } = json_response(conn, 200)

      assert %{"error" => %{"code" => "group_not_found"}} =
               build_conn()
               |> get(~p"/api/v1/groups/bad-stay")
               |> json_response(404)
    end

    test "rejects missing groups before revision checks", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            %{
              operation_id: "missing",
              type: "record_cash_payment",
              group_id: "missing",
              amount_cents: 500,
              expected_revision: 99
            }
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "missing",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "replays an equivalent operation without touching current group state", %{conn: conn} do
      first_json = """
      {
        "operations": [
          {
            "rooms": [
              {"room_id": "room-a", "nightly_rate_cents": 15000},
              {"room_id": "room-b", "nightly_rate_cents": 17500}
            ],
            "rate_plan": "flexible",
            "departure_on": "2026-12-13",
            "arrival_on": "2026-12-10",
            "property_id": "ams-canal",
            "guest_id": "guest-22",
            "group_id": "idempotent-open",
            "occurred_on": "2026-10-03",
            "type": "open_group",
            "operation_id": "idem-open"
          }
        ]
      }
      """

      second_json = """
      {
        "operations": [
          {
            "operation_id": "idem-open",
            "type": "open_group",
            "occurred_on": "2026-10-03",
            "group_id": "idempotent-open",
            "guest_id": "guest-22",
            "property_id": "ams-canal",
            "arrival_on": "2026-12-10",
            "departure_on": "2026-12-13",
            "rate_plan": "flexible",
            "rooms": [
              {"nightly_rate_cents": 15000, "room_id": "room-a"},
              {"nightly_rate_cents": 17500, "room_id": "room-b"}
            ]
          }
        ]
      }
      """

      first_result =
        conn
        |> post_json(~p"/api/v1/partner-batches", first_json)
        |> json_response(200)
        |> Map.fetch!("results")
        |> List.first()

      assert %{
               "operation_id" => "idem-open",
               "status" => "applied",
               "group_id" => "idempotent-open",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             } = first_result

      retry_result =
        build_conn()
        |> post_json(~p"/api/v1/partner-batches", second_json)
        |> json_response(200)
        |> Map.fetch!("results")
        |> List.first()

      assert retry_result == first_result

      assert %{
               "data" => %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/idempotent-open")
               |> json_response(200)

      assert %{"data" => ^first_result} =
               build_conn()
               |> get(~p"/api/v1/operations/idem-open")
               |> json_response(200)
    end

    test "rejects reused operation identifiers with different payloads", %{conn: conn} do
      original_operation =
        open_group_operation(%{operation_id: "reuse-open", group_id: "reuse-a"})

      first_result =
        conn
        |> post(~p"/api/v1/partner-batches", %{operations: [original_operation]})
        |> json_response(200)
        |> Map.fetch!("results")
        |> List.first()

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "reuse-open", group_id: "reuse-b"})
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "reuse-open",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)

      assert %{"error" => %{"code" => "group_not_found"}} =
               build_conn()
               |> get(~p"/api/v1/groups/reuse-b")
               |> json_response(404)

      retry_result =
        build_conn()
        |> post(~p"/api/v1/partner-batches", %{operations: [original_operation]})
        |> json_response(200)
        |> Map.fetch!("results")
        |> List.first()

      assert retry_result == first_result

      assert %{"data" => ^first_result} =
               build_conn()
               |> get(~p"/api/v1/operations/reuse-open")
               |> json_response(200)
    end

    test "remembers rejected operations even when later state would make them valid", %{
      conn: conn
    } do
      rejected_payment = %{
        operation_id: "remembered-rejection",
        type: "record_cash_payment",
        group_id: "eventual-group",
        amount_cents: 500
      }

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            rejected_payment,
            open_group_operation(%{operation_id: "eventual-open", group_id: "eventual-group"})
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-rejection",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 },
                 %{"operation_id" => "eventual-open", "status" => "applied", "revision" => 1}
               ]
             } = json_response(conn, 200)

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{operations: [rejected_payment]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "remembered-rejection",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 1,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/eventual-group")
               |> json_response(200)
    end

    test "replays stale revision details without consulting the current group", %{conn: conn} do
      stale_operation = %{
        operation_id: "stale-once",
        type: "record_cash_payment",
        group_id: "stale-freeze",
        amount_cents: 100,
        expected_revision: 1
      }

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "stale-open", group_id: "stale-freeze"}),
            %{
              operation_id: "stale-pay",
              type: "record_cash_payment",
              group_id: "stale-freeze",
              amount_cents: 1_000,
              expected_revision: 1
            },
            stale_operation,
            %{
              operation_id: "advance-after-stale",
              type: "record_cash_payment",
              group_id: "stale-freeze",
              amount_cents: 1_000,
              expected_revision: 2
            }
          ]
        })

      original_rejection = %{
        "operation_id" => "stale-once",
        "status" => "rejected",
        "code" => "stale_revision",
        "group_id" => "stale-freeze",
        "expected_revision" => 1,
        "actual_revision" => 2
      }

      assert %{
               "results" => [
                 %{"operation_id" => "stale-open", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "stale-pay", "status" => "applied", "revision" => 2},
                 ^original_rejection,
                 %{
                   "operation_id" => "advance-after-stale",
                   "status" => "applied",
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{operations: [stale_operation]})

      assert %{"results" => [^original_rejection]} = json_response(conn, 200)

      corrected_payload = Map.put(stale_operation, :expected_revision, 3)
      conn = post(build_conn(), ~p"/api/v1/partner-batches", %{operations: [corrected_payload]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "stale-once",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "retains submitted content, type, result, and first commit order", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "audit-open", group_id: "audit-group"}),
            %{
              operation_id: "audit-unknown",
              type: "sleep_group",
              note: %{
                "key-order" => "is not significant"
              }
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "audit-open", "status" => "applied"},
                 %{
                   "operation_id" => "audit-unknown",
                   "status" => "rejected",
                   "code" => "invalid_operation"
                 }
               ]
             } = json_response(conn, 200)

      records =
        PartnerOperation
        |> Repo.all()
        |> Enum.sort_by(& &1.id)

      assert Enum.map(records, & &1.operation_id) == ["audit-open", "audit-unknown"]
      assert Enum.map(records, & &1.operation_type) == ["open_group", "sleep_group"]

      open_payload = Jason.decode!(hd(records).payload_json)
      assert open_payload["operation_id"] == "audit-open"

      assert open_payload["rooms"] == [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
             ]

      unknown_result =
        records
        |> List.last()
        |> Map.fetch!(:result_json)
        |> Jason.decode!()

      assert unknown_result == %{
               "operation_id" => "audit-unknown",
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end
  end

  describe "payments, reschedules, cancellations, and ledger" do
    test "records cash, reschedules, and refunds flexible cancellations at least 14 days out", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{group_id: "flex-refund"}),
            %{
              operation_id: "pay",
              type: "record_cash_payment",
              group_id: "flex-refund",
              amount_cents: 5_000
            },
            %{
              operation_id: "move",
              type: "reschedule_group",
              occurred_on: "2026-10-10",
              group_id: "flex-refund",
              new_arrival_on: "2026-12-20"
            },
            %{
              operation_id: "cancel",
              type: "cancel_group",
              occurred_on: "2026-12-01",
              group_id: "flex-refund"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "pay",
                   "status" => "applied",
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "move",
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "cancel",
                   "status" => "applied",
                   "refunded_cents" => 5_000,
                   "retained_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 5_000,
                 "cash_retained_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger")
               |> json_response(200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 4,
                 "deposit_due_cents" => 0,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/flex-refund")
               |> json_response(200)
    end

    test "retains late flexible and advance-purchase cash", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{group_id: "late-flex"}),
            %{
              operation_id: "late-pay",
              type: "record_cash_payment",
              group_id: "late-flex",
              amount_cents: 1_000
            },
            %{
              operation_id: "late-cancel",
              type: "cancel_group",
              occurred_on: "2026-12-01",
              group_id: "late-flex"
            },
            open_group_operation(%{
              operation_id: "open-advance",
              group_id: "advance",
              rate_plan: "advance_purchase"
            }),
            %{
              operation_id: "advance-pay",
              type: "record_cash_payment",
              group_id: "advance",
              amount_cents: 1_000
            },
            %{
              operation_id: "advance-cancel",
              type: "cancel_group",
              occurred_on: "2026-10-04",
              group_id: "advance"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied"},
                 %{"operation_id" => "late-pay", "status" => "applied"},
                 %{
                   "operation_id" => "late-cancel",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 1_000
                 },
                 %{
                   "operation_id" => "open-advance",
                   "status" => "applied",
                   "deposit_due_cents" => 97_500
                 },
                 %{"operation_id" => "advance-pay", "status" => "applied"},
                 %{
                   "operation_id" => "advance-cancel",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 1_000
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 2_000
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger")
               |> json_response(200)
    end

    test "rejected group operations leave group and ledger unchanged", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{group_id: "unchanged"}),
            %{
              operation_id: "pay",
              type: "record_cash_payment",
              group_id: "unchanged",
              amount_cents: 1_000
            },
            %{
              operation_id: "bad-payment",
              type: "record_cash_payment",
              group_id: "unchanged",
              amount_cents: 99_999
            },
            %{
              operation_id: "bad-reschedule",
              type: "reschedule_group",
              occurred_on: "2026-10-10",
              group_id: "unchanged",
              new_arrival_on: "2026-10-10"
            },
            %{
              operation_id: "bad-cancel",
              type: "cancel_group",
              occurred_on: "not-a-date",
              group_id: "unchanged"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied"},
                 %{"operation_id" => "pay", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "bad-payment",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 },
                 %{
                   "operation_id" => "bad-reschedule",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 },
                 %{
                   "operation_id" => "bad-cancel",
                   "status" => "rejected",
                   "code" => "invalid_stay"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "status" => "active",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "deposit_paid_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_500
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/unchanged")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 1_000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger")
               |> json_response(200)
    end

    test "rejects operations against cancelled groups", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{group_id: "cancelled"}),
            %{
              operation_id: "cancel",
              type: "cancel_group",
              occurred_on: "2026-12-01",
              group_id: "cancelled"
            },
            %{
              operation_id: "pay-after-cancel",
              type: "record_cash_payment",
              group_id: "cancelled",
              amount_cents: 1
            },
            %{
              operation_id: "move-after-cancel",
              type: "reschedule_group",
              occurred_on: "2026-10-10",
              group_id: "cancelled",
              new_arrival_on: "2026-12-20"
            },
            %{
              operation_id: "cancel-again",
              type: "cancel_group",
              occurred_on: "2026-12-01",
              group_id: "cancelled"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "cancel", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "pay-after-cancel",
                   "status" => "rejected",
                   "code" => "group_not_active"
                 },
                 %{
                   "operation_id" => "move-after-cancel",
                   "status" => "rejected",
                   "code" => "group_not_active"
                 },
                 %{
                   "operation_id" => "cancel-again",
                   "status" => "rejected",
                   "code" => "group_not_active"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "returns fixed policy versions and recomputes refundable dates on reschedule", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              operation_id: "open-old-flex",
              group_id: "old-flex",
              occurred_on: "2026-12-31",
              arrival_on: "2027-02-15",
              departure_on: "2027-02-18"
            }),
            open_group_operation(%{
              operation_id: "open-new-flex",
              group_id: "new-flex",
              occurred_on: "2027-01-01",
              arrival_on: "2027-02-15",
              departure_on: "2027-02-18"
            }),
            open_group_operation(%{
              operation_id: "open-advance",
              group_id: "advance-policy",
              rate_plan: "advance_purchase",
              occurred_on: "2027-01-01",
              arrival_on: "2027-02-15",
              departure_on: "2027-02-18"
            }),
            %{
              operation_id: "move-old-flex",
              type: "reschedule_group",
              occurred_on: "2027-01-02",
              group_id: "old-flex",
              new_arrival_on: "2027-03-10"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-old-flex", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "open-new-flex", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "open-advance", "status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "move-old-flex",
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-02-24",
                   "new_arrival_on" => "2027-03-10",
                   "new_departure_on" => "2027-03-13",
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-02-24",
                 "arrival_on" => "2027-03-10",
                 "departure_on" => "2027-03-13",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "deposit_paid_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/old-flex")
               |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-01-16"
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/new-flex")
               |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/advance-policy")
               |> json_response(200)
    end

    test "converts refundable cash to hotel credit with the bonus and ledger expiry", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{group_id: "credit-source"}),
            %{
              operation_id: "source-pay",
              type: "record_cash_payment",
              group_id: "credit-source",
              amount_cents: 5_005
            },
            %{
              operation_id: "source-cancel",
              type: "cancel_group",
              occurred_on: "2026-11-26",
              group_id: "credit-source",
              refund_method: "hotel_credit"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "source-pay", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "source-cancel",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 5_506,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "guest_id" => "guest-22",
                 "available_cents" => 5_506,
                 "lots" => [
                   %{
                     "source_operation_id" => "source-cancel",
                     "remaining_cents" => 5_506,
                     "expires_on" => "2027-11-26"
                   }
                 ]
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2027-11-26"})
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 5_005,
                 "credit_liability_cents" => 5_506
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2027-11-26"})
               |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2027-11-27"})
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 5_005,
                 "credit_liability_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2027-11-27"})
               |> json_response(200)
    end

    test "rejects hotel credit refunds for non-refundable cancellations after revision checks", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              group_id: "late-credit",
              occurred_on: "2027-01-01",
              arrival_on: "2027-02-15",
              departure_on: "2027-02-18"
            }),
            %{
              operation_id: "late-pay",
              type: "record_cash_payment",
              group_id: "late-credit",
              amount_cents: 1_000
            },
            %{
              operation_id: "stale-credit-cancel",
              type: "cancel_group",
              occurred_on: "2027-01-20",
              group_id: "late-credit",
              refund_method: "hotel_credit",
              expected_revision: 1
            },
            %{
              operation_id: "late-credit-cancel",
              type: "cancel_group",
              occurred_on: "2027-01-20",
              group_id: "late-credit",
              refund_method: "hotel_credit",
              expected_revision: 2
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied", "revision" => 1},
                 %{"operation_id" => "late-pay", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "stale-credit-cancel",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{
                   "operation_id" => "late-credit-cancel",
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "active",
                 "revision" => 2,
                 "cash_paid_cents" => 1_000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 18_500
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/late-credit")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 1_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2027-01-20"})
               |> json_response(200)
    end

    test "applies credit by lot order and restores it on refundable cancellation", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "open-a", group_id: "source-a"}),
            %{
              operation_id: "pay-a",
              type: "record_cash_payment",
              group_id: "source-a",
              amount_cents: 1_000
            },
            %{
              operation_id: "cancel-a",
              type: "cancel_group",
              occurred_on: "2026-11-01",
              group_id: "source-a",
              refund_method: "hotel_credit"
            },
            open_group_operation(%{operation_id: "open-b", group_id: "source-b"}),
            %{
              operation_id: "pay-b",
              type: "record_cash_payment",
              group_id: "source-b",
              amount_cents: 2_000
            },
            %{
              operation_id: "cancel-b",
              type: "cancel_group",
              occurred_on: "2026-11-01",
              group_id: "source-b",
              refund_method: "hotel_credit"
            },
            open_group_operation(%{operation_id: "open-target", group_id: "credit-target"}),
            %{
              operation_id: "apply-credit",
              type: "apply_hotel_credit",
              occurred_on: "2026-11-02",
              group_id: "credit-target",
              amount_cents: 1_500,
              expected_revision: 1
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-a", "status" => "applied"},
                 %{"operation_id" => "pay-a", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-a",
                   "status" => "applied",
                   "credit_issued_cents" => 1_100
                 },
                 %{"operation_id" => "open-b", "status" => "applied"},
                 %{"operation_id" => "pay-b", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-b",
                   "status" => "applied",
                   "credit_issued_cents" => 2_200
                 },
                 %{"operation_id" => "open-target", "status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "apply-credit",
                   "status" => "applied",
                   "amount_cents" => 1_500,
                   "outstanding_deposit_cents" => 18_000,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 1_500,
                 "deposit_paid_cents" => 1_500,
                 "outstanding_deposit_cents" => 18_000
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/credit-target")
               |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 1_800,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 1_800,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2026-11-02"})
               |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 3_300
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2026-11-02"})
               |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          operations: [
            %{
              operation_id: "cancel-target",
              type: "cancel_group",
              occurred_on: "2026-11-20",
              group_id: "credit-target",
              expected_revision: 2
            }
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-target",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 3_300,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 1_100,
                     "expires_on" => "2027-11-01"
                   },
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 2_200,
                     "expires_on" => "2027-11-01"
                   }
                 ]
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2026-11-20"})
               |> json_response(200)
    end

    test "restored credit that has passed its original expiry reduces liability", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "open-source", group_id: "expiring-source"}),
            %{
              operation_id: "pay-source",
              type: "record_cash_payment",
              group_id: "expiring-source",
              amount_cents: 1_000
            },
            %{
              operation_id: "cancel-source",
              type: "cancel_group",
              occurred_on: "2026-10-01",
              group_id: "expiring-source",
              refund_method: "hotel_credit"
            },
            open_group_operation(%{
              operation_id: "open-expiry-target",
              group_id: "expiry-target",
              occurred_on: "2026-12-20",
              arrival_on: "2027-10-30",
              departure_on: "2027-11-02"
            }),
            %{
              operation_id: "apply-expiring-credit",
              type: "apply_hotel_credit",
              occurred_on: "2027-10-01",
              group_id: "expiry-target",
              amount_cents: 1_100
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-source", "status" => "applied"},
                 %{"operation_id" => "pay-source", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-source",
                   "status" => "applied",
                   "credit_issued_cents" => 1_100
                 },
                 %{"operation_id" => "open-expiry-target", "status" => "applied"},
                 %{
                   "operation_id" => "apply-expiring-credit",
                   "status" => "applied",
                   "amount_cents" => 1_100,
                   "revision" => 2
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2027-10-02"})
               |> json_response(200)

      assert %{
               "data" => %{"credit_liability_cents" => 1_100}
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2027-10-02"})
               |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          operations: [
            %{
              operation_id: "cancel-expiry-target",
              type: "cancel_group",
              occurred_on: "2027-10-02",
              group_id: "expiry-target"
            }
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-expiry-target",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{"credit_liability_cents" => 0}
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2027-10-02"})
               |> json_response(200)
    end

    test "non-refundable cancellation consumes applied credit", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{operation_id: "open-source", group_id: "consume-source"}),
            %{
              operation_id: "pay-source",
              type: "record_cash_payment",
              group_id: "consume-source",
              amount_cents: 1_000
            },
            %{
              operation_id: "cancel-source",
              type: "cancel_group",
              occurred_on: "2026-11-01",
              group_id: "consume-source",
              refund_method: "hotel_credit"
            },
            open_group_operation(%{operation_id: "open-target", group_id: "consume-target"}),
            %{
              operation_id: "apply-credit",
              type: "apply_hotel_credit",
              occurred_on: "2026-11-02",
              group_id: "consume-target",
              amount_cents: 1_100
            },
            %{
              operation_id: "late-cancel",
              type: "cancel_group",
              occurred_on: "2026-12-01",
              group_id: "consume-target"
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-source", "status" => "applied"},
                 %{"operation_id" => "pay-source", "status" => "applied"},
                 %{
                   "operation_id" => "cancel-source",
                   "status" => "applied",
                   "credit_issued_cents" => 1_100
                 },
                 %{"operation_id" => "open-target", "status" => "applied"},
                 %{"operation_id" => "apply-credit", "status" => "applied", "revision" => 2},
                 %{
                   "operation_id" => "late-cancel",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/consume-target")
               |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2026-12-01"})
               |> json_response(200)

      assert %{
               "data" => %{"credit_liability_cents" => 0}
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2026-12-01"})
               |> json_response(200)
    end

    test "rejects insufficient credit without advancing the revision", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{group_id: "no-credit"}),
            %{
              operation_id: "stale-apply-credit",
              type: "apply_hotel_credit",
              occurred_on: "2026-10-04",
              group_id: "no-credit",
              amount_cents: 100,
              expected_revision: 0
            },
            %{
              operation_id: "apply-without-credit",
              type: "apply_hotel_credit",
              occurred_on: "2026-10-04",
              group_id: "no-credit",
              amount_cents: 100,
              expected_revision: 1
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "op-open", "status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "stale-apply-credit",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 },
                 %{
                   "operation_id" => "apply-without-credit",
                   "status" => "rejected",
                   "code" => "insufficient_credit"
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 1,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/no-credit")
               |> json_response(200)
    end

    test "allocates cash to rooms and settles selected rooms in original order", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            one_night_group(%{operation_id: "open-room-block", group_id: "room-block"}),
            %{
              operation_id: "pay-room-block",
              type: "record_cash_payment",
              group_id: "room-block",
              amount_cents: 7_000
            },
            %{
              operation_id: "cancel-selected",
              type: "cancel_rooms",
              occurred_on: "2026-11-20",
              group_id: "room-block",
              room_ids: ["room-c", "room-b"]
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-room-block", "status" => "applied", "revision" => 1},
                 %{
                   "operation_id" => "pay-room-block",
                   "status" => "applied",
                   "outstanding_deposit_cents" => 5_000,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "cancel-selected",
                   "status" => "applied",
                   "cancelled_room_ids" => ["room-b", "room-c"],
                   "refunded_cents" => 5_000,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "status" => "active",
                 "deposit_due_cents" => 2_000,
                 "deposit_paid_cents" => 2_000,
                 "cash_paid_cents" => 2_000,
                 "outstanding_deposit_cents" => 0,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "active",
                     "lodging_total_cents" => 10_000,
                     "deposit_due_cents" => 2_000,
                     "cash_paid_cents" => 2_000
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "cancelled",
                     "deposit_due_cents" => 4_000,
                     "cash_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-c",
                     "status" => "cancelled",
                     "deposit_due_cents" => 6_000,
                     "cash_paid_cents" => 0
                   }
                 ]
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/room-block")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 2_000,
                 "cash_refunded_cents" => 5_000
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger")
               |> json_response(200)
    end

    test "reduces held cash in reverse fill order and preserves the original payment result", %{
      conn: conn
    } do
      payment = %{
        operation_id: "reducible-pay",
        type: "record_cash_payment",
        group_id: "reducible",
        amount_cents: 7_000
      }

      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            one_night_group(%{operation_id: "open-reducible", group_id: "reducible"}),
            payment,
            %{
              operation_id: "reduce-pay",
              type: "reduce_cash_payment",
              payment_operation_id: "reducible-pay",
              amount_cents: 1_500,
              expected_revision: 2
            }
          ]
        })

      original_payment_result = %{
        "operation_id" => "reducible-pay",
        "status" => "applied",
        "group_id" => "reducible",
        "amount_cents" => 7_000,
        "outstanding_deposit_cents" => 5_000,
        "revision" => 2
      }

      assert %{
               "results" => [
                 %{"operation_id" => "open-reducible", "status" => "applied", "revision" => 1},
                 ^original_payment_result,
                 %{
                   "operation_id" => "reduce-pay",
                   "status" => "applied",
                   "payment_operation_id" => "reducible-pay",
                   "group_id" => "reducible",
                   "amount_cents" => 1_500,
                   "outstanding_deposit_cents" => 6_500,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "cash_paid_cents" => 5_500,
                 "outstanding_deposit_cents" => 6_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 2_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 3_500},
                   %{"room_id" => "room-c", "cash_paid_cents" => 0}
                 ]
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/reducible")
               |> json_response(200)

      assert %{
               "data" => %{
                 "payment_operation_id" => "reducible-pay",
                 "original_group_id" => "reducible",
                 "recorded_cents" => 7_000,
                 "held_cents" => 5_500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 1_500,
                 "charged_back_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/payments/reducible-pay")
               |> json_response(200)

      assert %{"data" => ^original_payment_result} =
               build_conn()
               |> get(~p"/api/v1/operations/reducible-pay")
               |> json_response(200)

      assert %{
               "results" => [^original_payment_result]
             } =
               build_conn()
               |> post(~p"/api/v1/partner-batches", %{operations: [payment]})
               |> json_response(200)
    end

    test "rejects unreducible cash reductions with stable codes", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            one_night_group(%{operation_id: "open-reject-reduce", group_id: "reject-reduce"}),
            %{
              operation_id: "pay-reject-reduce",
              type: "record_cash_payment",
              group_id: "reject-reduce",
              amount_cents: 1_000
            },
            %{
              operation_id: "missing-reduction",
              type: "reduce_cash_payment",
              payment_operation_id: "legacy-pay",
              amount_cents: 1
            },
            %{
              operation_id: "non-payment-reduction",
              type: "reduce_cash_payment",
              payment_operation_id: "open-reject-reduce",
              amount_cents: 1
            },
            %{
              operation_id: "bad-amount-reduction",
              type: "reduce_cash_payment",
              payment_operation_id: "pay-reject-reduce",
              amount_cents: 0
            },
            %{
              operation_id: "too-large-reduction",
              type: "reduce_cash_payment",
              payment_operation_id: "pay-reject-reduce",
              amount_cents: 1_001
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-reject-reduce", "status" => "applied"},
                 %{"operation_id" => "pay-reject-reduce", "status" => "applied"},
                 %{
                   "operation_id" => "missing-reduction",
                   "status" => "rejected",
                   "code" => "operation_not_found"
                 },
                 %{
                   "operation_id" => "non-payment-reduction",
                   "status" => "rejected",
                   "code" => "payment_not_reducible"
                 },
                 %{
                   "operation_id" => "bad-amount-reduction",
                   "status" => "rejected",
                   "code" => "invalid_amount"
                 },
                 %{
                   "operation_id" => "too-large-reduction",
                   "status" => "rejected",
                   "code" => "reduction_exceeds_held_cash"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "charges back converted cash and revokes unspent credit", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              operation_id: "open-chargeback-source",
              group_id: "chargeback-source"
            }),
            %{
              operation_id: "chargeback-pay",
              type: "record_cash_payment",
              group_id: "chargeback-source",
              amount_cents: 5_005
            },
            %{
              operation_id: "chargeback-convert",
              type: "cancel_group",
              occurred_on: "2026-11-26",
              group_id: "chargeback-source",
              refund_method: "hotel_credit"
            },
            %{
              operation_id: "chargeback-payment",
              type: "charge_back_payment",
              payment_operation_id: "chargeback-pay",
              expected_revision: 3
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-chargeback-source", "status" => "applied"},
                 %{"operation_id" => "chargeback-pay", "status" => "applied"},
                 %{
                   "operation_id" => "chargeback-convert",
                   "status" => "applied",
                   "credit_issued_cents" => 5_506,
                   "revision" => 3
                 },
                 %{
                   "operation_id" => "chargeback-payment",
                   "status" => "applied",
                   "payment_operation_id" => "chargeback-pay",
                   "group_id" => "chargeback-source",
                   "charged_back_cents" => 5_005,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "recorded_cents" => 5_005,
                 "held_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 5_005
               }
             } =
               build_conn()
               |> get(~p"/api/v1/payments/chargeback-pay")
               |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2026-11-27"})
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 5_005,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2026-11-27"})
               |> json_response(200)
    end

    test "charges back spent credit as a shortfall and absorbs restored credit", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{
          operations: [
            open_group_operation(%{
              operation_id: "open-shortfall-source",
              group_id: "shortfall-source"
            }),
            %{
              operation_id: "shortfall-pay",
              type: "record_cash_payment",
              group_id: "shortfall-source",
              amount_cents: 1_000
            },
            %{
              operation_id: "shortfall-convert",
              type: "cancel_group",
              occurred_on: "2026-11-01",
              group_id: "shortfall-source",
              refund_method: "hotel_credit"
            },
            open_group_operation(%{
              operation_id: "open-shortfall-target",
              group_id: "shortfall-target"
            }),
            %{
              operation_id: "spend-shortfall-credit",
              type: "apply_hotel_credit",
              occurred_on: "2026-11-02",
              group_id: "shortfall-target",
              amount_cents: 1_100
            },
            %{
              operation_id: "chargeback-shortfall",
              type: "charge_back_payment",
              payment_operation_id: "shortfall-pay",
              expected_revision: 3
            }
          ]
        })

      assert %{
               "results" => [
                 %{"operation_id" => "open-shortfall-source", "status" => "applied"},
                 %{"operation_id" => "shortfall-pay", "status" => "applied"},
                 %{
                   "operation_id" => "shortfall-convert",
                   "status" => "applied",
                   "credit_issued_cents" => 1_100,
                   "revision" => 3
                 },
                 %{"operation_id" => "open-shortfall-target", "status" => "applied"},
                 %{
                   "operation_id" => "spend-shortfall-credit",
                   "status" => "applied",
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "chargeback-shortfall",
                   "status" => "applied",
                   "charged_back_cents" => 1_000,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "revision" => 2,
                 "credit_paid_cents" => 1_100
               }
             } =
               build_conn()
               |> get(~p"/api/v1/groups/shortfall-target")
               |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 1_100,
                 "credit_shortfall_cents" => 1_100
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2026-11-03"})
               |> json_response(200)

      conn =
        post(build_conn(), ~p"/api/v1/partner-batches", %{
          operations: [
            %{
              operation_id: "cancel-shortfall-target",
              type: "cancel_group",
              occurred_on: "2026-11-20",
              group_id: "shortfall-target",
              expected_revision: 2
            }
          ]
        })

      assert %{
               "results" => [
                 %{
                   "operation_id" => "cancel-shortfall-target",
                   "status" => "applied",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               build_conn()
               |> get(~p"/api/v1/guests/guest-22/credit", %{on: "2026-11-20"})
               |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger", %{on: "2026-11-20"})
               |> json_response(200)
    end
  end

  describe "GET /api/v1/ledger" do
    test "returns zero totals when no cash has moved", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ledger")

      assert %{
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
             } = json_response(conn, 200)
    end

    test "rejects invalid on dates", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ledger", %{on: "not-a-date"})

      assert %{"error" => %{"code" => "invalid_on"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns group_not_found for missing groups", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/groups/not-here")

      assert %{"error" => %{"code" => "group_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "returns empty credit for guests without lots", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/guests/guest-without-credit/credit")

      assert %{
               "data" => %{
                 "guest_id" => "guest-without-credit",
                 "available_cents" => 0,
                 "lots" => []
               }
             } = json_response(conn, 200)
    end

    test "rejects invalid on dates", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/guests/guest-22/credit", %{on: "not-a-date"})

      assert %{"error" => %{"code" => "invalid_on"}} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns operation_not_found for unknown operations", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/operations/not-here")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "returns operation_not_found for unknown operations", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/payments/not-here")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "returns payment_not_reconcilable for non-payment operations", %{conn: conn} do
      post(conn, ~p"/api/v1/partner-batches", %{
        operations: [
          open_group_operation(%{operation_id: "not-a-payment", group_id: "no-statement"})
        ]
      })

      conn = get(build_conn(), ~p"/api/v1/payments/not-a-payment")

      assert %{"error" => %{"code" => "payment_not_reconcilable"}} =
               json_response(conn, 422)
    end
  end

  defp post_json(conn, path, json) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, json)
  end

  defp open_group_operation(overrides) do
    %{
      operation_id: "op-open",
      type: "open_group",
      occurred_on: "2026-10-03",
      group_id: "group-81",
      guest_id: "guest-22",
      property_id: "ams-canal",
      arrival_on: "2026-12-10",
      departure_on: "2026-12-13",
      rate_plan: "flexible",
      rooms: [
        %{room_id: "room-a", nightly_rate_cents: 15_000},
        %{room_id: "room-b", nightly_rate_cents: 17_500}
      ]
    }
    |> Map.merge(overrides)
  end

  defp one_night_group(overrides) do
    open_group_operation(%{
      arrival_on: "2026-12-10",
      departure_on: "2026-12-11",
      rooms: [
        %{room_id: "room-a", nightly_rate_cents: 10_000},
        %{room_id: "room-b", nightly_rate_cents: 20_000},
        %{room_id: "room-c", nightly_rate_cents: 30_000}
      ]
    })
    |> Map.merge(overrides)
  end
end
