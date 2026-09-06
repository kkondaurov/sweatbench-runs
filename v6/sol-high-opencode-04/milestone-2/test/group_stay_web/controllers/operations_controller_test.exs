defmodule GroupStayWeb.OperationsControllerTest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "rejects an invalid batch envelope", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})

      assert response(conn, 422) == Jason.encode!(%{error: %{code: "invalid_batch"}})

      conn = post(build_conn(), "/api/v1/partner-batches", %{operations: %{}})

      assert response(conn, 422) == Jason.encode!(%{error: %{code: "invalid_batch"}})
    end

    test "accepts an empty batch", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{operations: []})

      assert json_response(conn, 200) == %{"results" => []}
    end

    test "opens and reads a flexible group with ordered rooms", %{conn: conn} do
      operation = open_operation()

      conn = post(conn, "/api/v1/partner-batches", %{operations: [operation]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-1",
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
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
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

    test "rounds each flexible room deposit separately", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 2},
            %{"room_id" => "room-b", "nightly_rate_cents" => 2}
          ]
        })

      conn = post(conn, "/api/v1/partner-batches", %{operations: [operation]})

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 0, "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "requires the full lodging total for advance purchase", %{conn: conn} do
      operation = open_operation(%{"rate_plan" => "advance_purchase"})

      conn = post(conn, "/api/v1/partner-batches", %{operations: [operation]})

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 97_500, "revision" => 1}
               ]
             } = json_response(conn, 200)
    end

    test "rejects room amounts that cannot be persisted safely", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 9_223_372_036_854_775_807}
          ]
        })

      conn = post(conn, "/api/v1/partner-batches", %{operations: [operation]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
               json_response(conn, 200)
    end

    test "rejects invalid opening data without creating a group", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "bad-stay",
          "departure_on" => "2026-12-10"
        }),
        open_operation(%{
          "operation_id" => "bad-rooms",
          "group_id" => "group-2",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        }),
        open_operation(%{
          "operation_id" => "bad-plan",
          "group_id" => "group-3",
          "rate_plan" => "breakfast"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_rate_plan"
             ]

      assert response(get(build_conn(), "/api/v1/groups/group-1"), 404) ==
               Jason.encode!(%{error: %{code: "group_not_found"}})
    end

    test "rejects a duplicate group", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{operations: [open_operation()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      duplicate = open_operation(%{"operation_id" => "open-again"})
      conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [duplicate]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-again",
                   "status" => "rejected",
                   "code" => "group_already_exists",
                   "group_id" => "group-1"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "records payments and enforces amount rules", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"operation_id" => "zero", "amount_cents" => 0}),
        payment_operation(%{"operation_id" => "too-much", "amount_cents" => 19_501}),
        payment_operation(%{"amount_cents" => 5_000})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [opened, zero, too_much, paid]} = json_response(conn, 200)
      assert opened["revision"] == 1
      assert zero["code"] == "invalid_amount"
      assert too_much["code"] == "payment_exceeds_outstanding"

      assert paid == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{"data" => %{"deposit_paid_cents" => 5_000, "revision" => 2}} =
               json_response(conn, 200)
    end

    test "uses revisions from earlier operations in the same batch", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"amount_cents" => 1_000, "expected_revision" => 1}),
        payment_operation(%{
          "operation_id" => "stale",
          "amount_cents" => 2_000,
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "current",
          "amount_cents" => 3_000,
          "expected_revision" => 2
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, first, stale, current]} = json_response(conn, 200)
      assert first["revision"] == 2

      assert stale == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert current["revision"] == 3

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 4_000}} =
               json_response(conn, 200)
    end

    test "treats every supplied expected revision as a comparison", %{conn: conn} do
      missing = payment_operation(%{"group_id" => "missing", "expected_revision" => 0})
      conn = post(conn, "/api/v1/partner-batches", %{operations: [missing]})

      assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(conn, 200)

      operations = [
        open_operation(),
        payment_operation(%{"expected_revision" => 0})
      ]

      conn = post(build_conn(), "/api/v1/partner-batches", %{operations: operations})

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 0,
                   "actual_revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "reschedules by the same stay length and validates the operation date", %{conn: conn} do
      operations = [
        open_operation(),
        reschedule_operation(%{"new_arrival_on" => "2026-10-03"}),
        reschedule_operation(%{
          "operation_id" => "move",
          "new_arrival_on" => "2027-01-30",
          "expected_revision" => 1
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, invalid, moved]} = json_response(conn, 200)
      assert invalid["code"] == "invalid_stay"

      assert moved == %{
               "operation_id" => "move",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2027-01-30",
               "new_departure_on" => "2027-02-02",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-16",
               "revision" => 2
             }
    end

    test "rejects a reschedule whose shifted departure is outside the date range", %{conn: conn} do
      operations = [
        open_operation(),
        reschedule_operation(%{"new_arrival_on" => "9999-12-31"})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, %{"code" => "invalid_stay"}]} = json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{"data" => %{"arrival_on" => "2026-12-10", "revision" => 1}} =
               json_response(conn, 200)
    end

    test "refunds flexible cash at the fourteen-day boundary", %{conn: conn} do
      operations = [
        open_operation(%{"arrival_on" => "2026-10-17", "departure_on" => "2026-10-20"}),
        payment_operation(%{"amount_cents" => 5_000}),
        cancel_operation(%{"expected_revision" => 2})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, _, cancelled]} = json_response(conn, 200)

      assert cancelled == %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 5_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 5_000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             } = json_response(conn, 200)
    end

    test "retains late flexible and all advance-purchase cash in aggregate ledger", %{conn: conn} do
      first = [
        open_operation(%{"arrival_on" => "2026-10-16", "departure_on" => "2026-10-19"}),
        payment_operation(%{"amount_cents" => 4_000}),
        cancel_operation()
      ]

      second = [
        open_operation(%{
          "operation_id" => "open-2",
          "group_id" => "group-2",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation(%{
          "operation_id" => "pay-2",
          "group_id" => "group-2",
          "amount_cents" => 6_000
        }),
        cancel_operation(%{"operation_id" => "cancel-2", "group_id" => "group-2"})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: first ++ second})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 10_000,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "checks stale revisions before inactive and operation-specific rules", %{conn: conn} do
      operations = [open_operation(), cancel_operation()]
      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, %{"revision" => 2}]} = json_response(conn, 200)

      checks = [
        payment_operation(%{
          "operation_id" => "stale-payment",
          "amount_cents" => 0,
          "expected_revision" => 1
        }),
        reschedule_operation(%{
          "operation_id" => "stale-move",
          "new_arrival_on" => "bad-date",
          "expected_revision" => 1
        }),
        cancel_operation(%{"operation_id" => "again"})
      ]

      conn = post(build_conn(), "/api/v1/partner-batches", %{operations: checks})
      assert %{"results" => [stale_payment, stale_move, inactive]} = json_response(conn, 200)
      assert stale_payment["code"] == "stale_revision"
      assert stale_move["code"] == "stale_revision"
      assert inactive["code"] == "group_not_active"
    end

    test "resolves group existence before revision comparison", %{conn: conn} do
      operation =
        payment_operation(%{
          "group_id" => "missing",
          "amount_cents" => 1,
          "expected_revision" => 99
        })

      conn = post(conn, "/api/v1/partner-batches", %{operations: [operation]})

      assert %{"results" => [%{"code" => "group_not_found", "group_id" => "missing"}]} =
               json_response(conn, 200)
    end

    test "rejects malformed operations and continues processing", %{conn: conn} do
      valid = open_operation()

      operations = [
        %{"operation_id" => "unknown", "type" => "other", "occurred_on" => "2026-10-03"},
        %{
          "operation_id" => "missing-data",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-03"
        },
        "not-an-object",
        valid
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [unknown, missing, malformed, applied]} = json_response(conn, 200)
      assert unknown["code"] == "invalid_operation"
      assert missing["code"] == "invalid_operation"
      assert malformed["code"] == "invalid_operation"
      assert applied["status"] == "applied"
    end

    test "rejections leave group and ledger state unchanged", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"amount_cents" => 1_000}),
        payment_operation(%{
          "operation_id" => "rejected",
          "amount_cents" => 50_000,
          "expected_revision" => 2
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, _, %{"code" => "payment_exceeds_outstanding"}]} =
               json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
               json_response(conn, 200)

      conn = get(build_conn(), "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 1_000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET read endpoints" do
    test "returns API errors and zero ledger totals", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
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

  describe "cancellation economics" do
    test "assigns fixed policy versions at the booking-date cutoff", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "legacy",
          "group_id" => "legacy",
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-02",
          "departure_on" => "2027-03-05"
        }),
        open_operation(%{
          "operation_id" => "new",
          "group_id" => "new",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-02",
          "departure_on" => "2027-03-05"
        }),
        open_operation(%{
          "operation_id" => "advance",
          "group_id" => "advance",
          "occurred_on" => "2027-01-01",
          "rate_plan" => "advance_purchase"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-02-16"
               }
             } = json_response(get(build_conn(), "/api/v1/groups/legacy"), 200)

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-01-31"
               }
             } = json_response(get(build_conn(), "/api/v1/groups/new"), 200)

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = json_response(get(build_conn(), "/api/v1/groups/advance"), 200)
    end

    test "preserves policy and recomputes the refund date when rescheduling", %{conn: conn} do
      operations = [
        open_operation(%{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-02",
          "departure_on" => "2027-03-05"
        }),
        reschedule_operation(%{
          "occurred_on" => "2027-01-02",
          "new_arrival_on" => "2027-04-01"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{
               "results" => [
                 _,
                 %{
                   "status" => "applied",
                   "policy_version" => "flex-14",
                   "refundable_until" => "2027-03-18"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "uses the inclusive thirty-day cancellation boundary", %{conn: conn} do
      refundable = [
        open_operation(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-02-01",
          "departure_on" => "2027-02-04"
        }),
        payment_operation(%{"occurred_on" => "2027-01-01", "amount_cents" => 100}),
        cancel_operation(%{"occurred_on" => "2027-01-02"})
      ]

      late = [
        open_operation(%{
          "operation_id" => "open-late",
          "group_id" => "late",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-02-01",
          "departure_on" => "2027-02-04"
        }),
        payment_operation(%{
          "operation_id" => "pay-late",
          "group_id" => "late",
          "occurred_on" => "2027-01-01",
          "amount_cents" => 100
        }),
        cancel_operation(%{
          "operation_id" => "cancel-late",
          "group_id" => "late",
          "occurred_on" => "2027-01-03",
          "refund_method" => "hotel_credit"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: refundable ++ late})
      assert %{"results" => [_, _, boundary, _, _, rejected]} = json_response(conn, 200)
      assert boundary["refunded_cents"] == 100
      assert boundary["credit_issued_cents"] == 0
      assert rejected["code"] == "refund_method_not_available"

      assert %{"data" => %{"status" => "active", "revision" => 2}} =
               json_response(get(build_conn(), "/api/v1/groups/late"), 200)
    end

    test "converts refundable cash to expiring credit with a rounded bonus", %{conn: conn} do
      operations = [
        open_operation(%{
          "occurred_on" => "2027-05-01",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        payment_operation(%{"occurred_on" => "2027-05-01", "amount_cents" => 5}),
        cancel_operation(%{
          "occurred_on" => "2027-05-02",
          "refund_method" => "hotel_credit"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => [_, _, cancelled]} = json_response(conn, 200)

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 6
             } = cancelled

      assert json_response(
               get(build_conn(), "/api/v1/guests/guest-1/credit?on=2028-05-01"),
               200
             ) == %{
               "data" => %{
                 "guest_id" => "guest-1",
                 "available_cents" => 6,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-1",
                     "remaining_cents" => 6,
                     "expires_on" => "2028-05-01"
                   }
                 ]
               }
             }

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } =
               json_response(
                 get(build_conn(), "/api/v1/guests/guest-1/credit?on=2028-05-02"),
                 200
               )

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 5,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "credit_liability_cents" => 6
               }
             } = json_response(get(build_conn(), "/api/v1/ledger?on=2028-05-01"), 200)
    end

    test "keeps credit expiry readable beyond the built-in date storage range", %{conn: conn} do
      operations = [
        open_operation(%{
          "occurred_on" => "9999-11-01",
          "arrival_on" => "9999-12-30",
          "departure_on" => "9999-12-31"
        }),
        payment_operation(%{"occurred_on" => "9999-11-01", "amount_cents" => 20}),
        cancel_operation(%{
          "occurred_on" => "9999-11-30",
          "refund_method" => "hotel_credit"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, _, %{"status" => "applied", "credit_issued_cents" => 22}]} =
               json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 22,
                 "lots" => [
                   %{
                     "remaining_cents" => 22,
                     "expires_on" => "10000-11-29"
                   }
                 ]
               }
             } =
               json_response(
                 get(build_conn(), "/api/v1/guests/guest-1/credit?on=9999-12-31"),
                 200
               )

      assert %{"data" => %{"credit_liability_cents" => 22}} =
               json_response(get(build_conn(), "/api/v1/ledger?on=9999-12-31"), 200)

      assert %{"data" => %{"available_cents" => 22}} =
               json_response(
                 get(build_conn(), "/api/v1/guests/guest-1/credit?on=10000-11-29"),
                 200
               )

      assert %{"data" => %{"available_cents" => 0}} =
               json_response(
                 get(build_conn(), "/api/v1/guests/guest-1/credit?on=10000-11-30"),
                 200
               )
    end

    test "consumes equal-expiry lots by source id and restores their provenance", %{conn: conn} do
      operations =
        credit_source_operations("source-z", "z-source", 3_000) ++
          credit_source_operations("source-a", "a-source", 2_000) ++
          [
            open_operation(%{
              "operation_id" => "open-target",
              "group_id" => "target",
              "guest_id" => "guest-1"
            }),
            payment_operation(%{
              "operation_id" => "cash-target",
              "group_id" => "target",
              "amount_cents" => 500
            }),
            credit_operation(%{
              "operation_id" => "credit-target",
              "group_id" => "target",
              "amount_cents" => 3_000
            })
          ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 3_500,
                 "cash_paid_cents" => 500,
                 "credit_paid_cents" => 3_000
               }
             } = json_response(get(build_conn(), "/api/v1/groups/target"), 200)

      assert %{
               "data" => %{
                 "available_cents" => 2_500,
                 "lots" => [
                   %{"source_operation_id" => "z-source", "remaining_cents" => 2_500}
                 ]
               }
             } =
               json_response(
                 get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-04"),
                 200
               )

      conn =
        post(build_conn(), "/api/v1/partner-batches", %{
          operations: [
            cancel_operation(%{
              "operation_id" => "cancel-target",
              "group_id" => "target",
              "occurred_on" => "2026-10-04"
            })
          ]
        })

      assert %{
               "results" => [
                 %{
                   "refunded_cents" => 500,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ]
             } = json_response(conn, 200)

      assert %{
               "data" => %{
                 "available_cents" => 5_500,
                 "lots" => [
                   %{"source_operation_id" => "a-source", "remaining_cents" => 2_200},
                   %{"source_operation_id" => "z-source", "remaining_cents" => 3_300}
                 ]
               }
             } =
               json_response(
                 get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-04"),
                 200
               )

      assert %{"data" => %{"credit_liability_cents" => 5_500}} =
               json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-04"), 200)
    end

    test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
      operations =
        credit_source_operations("source", "source-credit", 1_000) ++
          [
            open_operation(%{
              "operation_id" => "open-target",
              "group_id" => "target",
              "guest_id" => "guest-1",
              "rate_plan" => "advance_purchase"
            }),
            credit_operation(%{"group_id" => "target", "amount_cents" => 1_000}),
            cancel_operation(%{"group_id" => "target"})
          ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "data" => %{
                 "cash_retained_cents" => 0,
                 "credit_liability_cents" => 100
               }
             } = json_response(get(build_conn(), "/api/v1/ledger?on=2026-10-03"), 200)
    end

    test "drops liability when restored credit has passed its original expiry", %{conn: conn} do
      operations =
        credit_source_operations("source", "source-credit", 1_000) ++
          [
            open_operation(%{
              "operation_id" => "open-target",
              "group_id" => "target",
              "guest_id" => "guest-1",
              "arrival_on" => "2027-12-10",
              "departure_on" => "2027-12-13"
            }),
            credit_operation(%{
              "operation_id" => "credit-target",
              "group_id" => "target",
              "occurred_on" => "2027-10-03",
              "amount_cents" => 1_000
            })
          ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"credit_liability_cents" => 1_000}} =
               json_response(get(build_conn(), "/api/v1/ledger?on=2027-10-04"), 200)

      conn =
        post(build_conn(), "/api/v1/partner-batches", %{
          operations: [
            cancel_operation(%{
              "operation_id" => "cancel-target",
              "group_id" => "target",
              "occurred_on" => "2027-10-04"
            })
          ]
        })

      assert %{"results" => [%{"status" => "applied", "refunded_cents" => 0}]} =
               json_response(conn, 200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               json_response(get(build_conn(), "/api/v1/ledger?on=2027-10-04"), 200)
    end

    test "checks revision before credit and refund-method rules", %{conn: conn} do
      operations = [
        open_operation(%{"rate_plan" => "advance_purchase"}),
        payment_operation(%{"amount_cents" => 100}),
        credit_operation(%{"expected_revision" => 1}),
        cancel_operation(%{"expected_revision" => 1, "refund_method" => "hotel_credit"}),
        credit_operation(%{"operation_id" => "no-credit", "expected_revision" => 2}),
        cancel_operation(%{
          "operation_id" => "bad-method",
          "expected_revision" => 2,
          "refund_method" => "hotel_credit"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})

      assert %{"results" => [_, _, stale_credit, stale_cancel, no_credit, bad_method]} =
               json_response(conn, 200)

      assert stale_credit["code"] == "stale_revision"
      assert stale_cancel["code"] == "stale_revision"
      assert no_credit["code"] == "insufficient_credit"
      assert bad_method["code"] == "refund_method_not_available"

      assert %{"data" => %{"status" => "active", "revision" => 2}} =
               json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)
    end

    test "validates dates on credit and ledger reads", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/guests/unknown/credit"), 200) == %{
               "data" => %{"guest_id" => "unknown", "available_cents" => 0, "lots" => []}
             }

      assert json_response(get(build_conn(), "/api/v1/guests/unknown/credit?on=bad"), 422) ==
               %{"error" => %{"code" => "invalid_date"}}

      assert json_response(get(build_conn(), "/api/v1/ledger?on=bad"), 422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  describe "GET /api/v1/ledger" do
    test "ledger totals remain exact above SQLite's aggregate integer limit", %{conn: conn} do
      max = 9_223_372_036_854_775_807

      operations =
        for number <- 1..2,
            operation <- [
              open_operation(%{
                "operation_id" => "open-#{number}",
                "group_id" => "group-#{number}",
                "arrival_on" => "2026-12-10",
                "departure_on" => "2026-12-11",
                "rate_plan" => "advance_purchase",
                "rooms" => [%{"room_id" => "room-#{number}", "nightly_rate_cents" => max}]
              }),
              payment_operation(%{
                "operation_id" => "pay-#{number}",
                "group_id" => "group-#{number}",
                "amount_cents" => max
              })
            ],
            do: operation

      conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(build_conn(), "/api/v1/ledger")

      assert %{"data" => %{"cash_held_cents" => 18_446_744_073_709_551_614}} =
               json_response(conn, 200)
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
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "new_arrival_on" => "2026-12-20"
      },
      overrides
    )
  end

  defp cancel_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1"
      },
      overrides
    )
  end

  defp credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "credit-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp credit_source_operations(group_id, cancellation_id, amount) do
    [
      open_operation(%{"operation_id" => "open-#{group_id}", "group_id" => group_id}),
      payment_operation(%{
        "operation_id" => "pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => amount
      }),
      cancel_operation(%{
        "operation_id" => cancellation_id,
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      })
    ]
  end
end
