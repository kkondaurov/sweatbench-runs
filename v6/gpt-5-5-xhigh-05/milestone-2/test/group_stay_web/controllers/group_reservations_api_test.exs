defmodule GroupStayWeb.GroupReservationsAPITest do
  use GroupStayWeb.ConnCase

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
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 5_000,
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
                 "credit_paid_cents" => 1_100,
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
                 "credit_liability_cents" => 0
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
end
