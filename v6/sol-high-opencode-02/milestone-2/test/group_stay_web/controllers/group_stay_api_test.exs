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
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 3
             }

      assert cancelled == %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 0,
               "retained_cents" => 10_000,
               "credit_issued_cents" => 0,
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

    test "fixes cancellation policy at booking and recomputes its date after rescheduling", %{
      conn: conn
    } do
      operations = [
        open_operation(%{
          "operation_id" => "open-old",
          "group_id" => "old-flex",
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        open_operation(%{
          "operation_id" => "open-new",
          "group_id" => "new-flex",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "occurred_on" => "2027-01-01",
          "rate_plan" => "advance_purchase"
        }),
        %{
          "operation_id" => "move-new",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "new-flex",
          "new_arrival_on" => "2027-04-15",
          "expected_revision" => 1
        }
      ]

      assert %{"results" => [_, _, _, moved]} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert moved == %{
               "operation_id" => "move-new",
               "status" => "applied",
               "group_id" => "new-flex",
               "new_arrival_on" => "2027-04-15",
               "new_departure_on" => "2027-04-18",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-16",
               "revision" => 2
             }

      assert %{"data" => %{"policy_version" => "flex-14", "refundable_until" => "2027-03-01"}} =
               get(build_conn(), "/api/v1/groups/old-flex") |> json_response(200)

      assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-03-16"}} =
               get(build_conn(), "/api/v1/groups/new-flex") |> json_response(200)

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get(build_conn(), "/api/v1/groups/advance") |> json_response(200)
    end

    test "converts refundable cash to credit with rounded bonus and date-aware totals", %{
      conn: conn
    } do
      operations = [
        open_operation(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        payment_operation(105),
        %{
          "operation_id" => "cancel-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-10",
          "group_id" => "group-1",
          "refund_method" => "hotel_credit"
        }
      ]

      assert %{"results" => [_, _, cancellation]} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert cancellation == %{
               "operation_id" => "cancel-credit",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 116,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "guest_id" => "guest-1",
                 "available_cents" => 116,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-credit",
                     "remaining_cents" => 116,
                     "expires_on" => "2028-01-10"
                   }
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2028-01-10")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 105,
                 "credit_liability_cents" => 116
               }
             } = get(build_conn(), "/api/v1/ledger?on=2028-01-10") |> json_response(200)

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2028-01-11")
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get(build_conn(), "/api/v1/ledger?on=2028-01-11") |> json_response(200)
    end

    test "consumes equal-expiry lots by source and restores their provenance", %{conn: conn} do
      source = fn group_id, open_id, pay_id, cancel_id ->
        [
          open_operation(%{
            "operation_id" => open_id,
            "group_id" => group_id,
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-04"
          }),
          payment_operation(100)
          |> Map.merge(%{"operation_id" => pay_id, "group_id" => group_id}),
          %{
            "operation_id" => cancel_id,
            "type" => "cancel_group",
            "occurred_on" => "2027-01-10",
            "group_id" => group_id,
            "refund_method" => "hotel_credit"
          }
        ]
      end

      destination =
        open_operation(%{
          "operation_id" => "open-destination",
          "group_id" => "destination",
          "occurred_on" => "2027-01-10",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      operations =
        source.("source-z", "open-z", "pay-z", "cancel-z") ++
          source.("source-a", "open-a", "pay-a", "cancel-a") ++
          [
            destination,
            %{
              "operation_id" => "apply-credit",
              "type" => "apply_hotel_credit",
              "occurred_on" => "2027-01-11",
              "group_id" => "destination",
              "amount_cents" => 165,
              "expected_revision" => 1
            }
          ]

      assert %{"results" => results} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert List.last(results)["revision"] == 2

      assert %{
               "data" => %{
                 "available_cents" => 55,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-z",
                     "remaining_cents" => 55
                   }
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-11")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 165,
                 "deposit_paid_cents" => 165
               }
             } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 220}} =
               get(build_conn(), "/api/v1/ledger?on=2027-01-11") |> json_response(200)

      cancellation = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-20",
        "group_id" => "destination",
        "expected_revision" => 2
      }

      assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 0}]} =
               post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancellation]})
               |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 220,
                 "lots" => [
                   %{"source_operation_id" => "cancel-a", "remaining_cents" => 110},
                   %{"source_operation_id" => "cancel-z", "remaining_cents" => 110}
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-20")
               |> json_response(200)
    end

    test "pauses applied credit expiry and drops it when restored after expiry", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "open-source",
          "group_id" => "source",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        payment_operation(100)
        |> Map.merge(%{"operation_id" => "pay-source", "group_id" => "source"}),
        %{
          "operation_id" => "issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        },
        open_operation(%{
          "operation_id" => "open-destination",
          "group_id" => "destination",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        }),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-02",
          "group_id" => "destination",
          "amount_cents" => 110
        }
      ]

      assert %{"results" => results} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"credit_liability_cents" => 110}} =
               get(build_conn(), "/api/v1/ledger?on=2028-01-02") |> json_response(200)

      cancellation = %{
        "operation_id" => "cancel-destination",
        "type" => "cancel_group",
        "occurred_on" => "2028-01-02",
        "group_id" => "destination"
      }

      assert %{"results" => [%{"status" => "applied"}]} =
               post(build_conn(), "/api/v1/partner-batches", %{"operations" => [cancellation]})
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get(build_conn(), "/api/v1/ledger?on=2028-01-02") |> json_response(200)
    end

    test "rejects unavailable refund methods and consumes credit on non-refundable cancellation",
         %{
           conn: conn
         } do
      operations = [
        open_operation(%{
          "operation_id" => "open-source",
          "group_id" => "source",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        payment_operation(100)
        |> Map.merge(%{"operation_id" => "pay-source", "group_id" => "source"}),
        %{
          "operation_id" => "issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        },
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "guest_id" => "guest-1",
          "rate_plan" => "advance_purchase"
        }),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-03",
          "group_id" => "advance",
          "amount_cents" => 100
        },
        payment_operation(50)
        |> Map.merge(%{"operation_id" => "pay-advance", "group_id" => "advance"}),
        %{
          "operation_id" => "bad-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "advance",
          "refund_method" => "hotel_credit",
          "expected_revision" => 3
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-04",
          "group_id" => "advance",
          "expected_revision" => 3
        }
      ]

      assert %{"results" => results} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert Enum.at(results, 6) == %{
               "operation_id" => "bad-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert List.last(results) == %{
               "operation_id" => "cancel-advance",
               "status" => "applied",
               "group_id" => "advance",
               "refunded_cents" => 0,
               "retained_cents" => 50,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      assert %{"data" => %{"available_cents" => 10}} =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-04")
               |> json_response(200)
    end

    test "refunds mixed funding on the policy and credit-expiry boundary", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "open-source",
          "group_id" => "source",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        payment_operation(100)
        |> Map.merge(%{
          "operation_id" => "pay-source",
          "occurred_on" => "2027-01-02",
          "group_id" => "source"
        }),
        %{
          "operation_id" => "issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-10",
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        },
        open_operation(%{
          "operation_id" => "open-destination",
          "group_id" => "destination",
          "occurred_on" => "2027-01-11",
          "arrival_on" => "2028-02-09",
          "departure_on" => "2028-02-12"
        }),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-12",
          "group_id" => "destination",
          "amount_cents" => 60
        },
        payment_operation(40)
        |> Map.merge(%{
          "operation_id" => "pay-destination",
          "occurred_on" => "2027-01-12",
          "group_id" => "destination"
        }),
        %{
          "operation_id" => "cancel-destination",
          "type" => "cancel_group",
          "occurred_on" => "2028-01-10",
          "group_id" => "destination",
          "expected_revision" => 3
        }
      ]

      assert %{"results" => results} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert List.last(results) == %{
               "operation_id" => "cancel-destination",
               "status" => "applied",
               "group_id" => "destination",
               "refunded_cents" => 40,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      assert %{
               "data" => %{
                 "available_cents" => 110,
                 "lots" => [
                   %{
                     "source_operation_id" => "issue-credit",
                     "remaining_cents" => 110,
                     "expires_on" => "2028-01-10"
                   }
                 ]
               }
             } =
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2028-01-10")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 40,
                 "cash_converted_to_credit_cents" => 100,
                 "credit_liability_cents" => 110
               }
             } = get(build_conn(), "/api/v1/ledger?on=2028-01-10") |> json_response(200)
    end

    test "checks revisions before a late flexible credit-refund rejection", %{conn: conn} do
      operations = [
        open_operation(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-18"
        }),
        payment_operation(100),
        %{
          "operation_id" => "stale-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-14",
          "group_id" => "group-1",
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        },
        %{
          "operation_id" => "late-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-14",
          "group_id" => "group-1",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ]

      assert %{"results" => [_, _, stale, late]} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert stale["code"] == "stale_revision"
      assert late["code"] == "refund_method_not_available"

      assert %{"data" => %{"status" => "active", "revision" => 2}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end

    test "checks revision before insufficient credit", %{conn: conn} do
      operations = [
        open_operation(),
        %{
          "operation_id" => "stale-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1",
          "amount_cents" => 1,
          "expected_revision" => 0
        },
        %{
          "operation_id" => "insufficient-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1",
          "amount_cents" => 1,
          "expected_revision" => 1
        }
      ]

      assert %{"results" => [_, stale, insufficient]} =
               post(conn, "/api/v1/partner-batches", %{"operations" => operations})
               |> json_response(200)

      assert stale["code"] == "stale_revision"
      assert insufficient["code"] == "insufficient_credit"

      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} =
               get(build_conn(), "/api/v1/groups/group-1") |> json_response(200)
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
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
