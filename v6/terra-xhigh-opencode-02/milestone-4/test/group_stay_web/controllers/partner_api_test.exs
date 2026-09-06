defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{PartnerOperation, Repo}

  test "opens a group, preserves room order, and reports empty finance totals", %{conn: conn} do
    response = post_batch(conn, [open_group()])

    assert response == %{
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

    group =
      conn
      |> get("/api/v1/groups/group-1")
      |> json_response(200)
      |> Map.fetch!("data")

    assert group == %{
             "group_id" => "group-1",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "revision" => 1,
             "rooms" => [
               room("room-a", 15_000, 45_000, 9_000),
               room("room-b", 17_500, 52_500, 10_500)
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "processes operations in order and continues after a rejected operation", %{conn: conn} do
    response =
      post_batch(conn, [
        open_group(),
        cash_payment("pay-1", 1_000, 1),
        cash_payment("too-much", 19_000, 2),
        reschedule("move-1", "2026-12-14", 2)
      ])

    assert [
             %{"status" => "applied", "revision" => 1},
             %{
               "status" => "applied",
               "amount_cents" => 1_000,
               "outstanding_deposit_cents" => 18_500,
               "revision" => 2
             },
             %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
             %{
               "status" => "applied",
               "new_arrival_on" => "2026-12-14",
               "new_departure_on" => "2026-12-17",
               "revision" => 3
             }
           ] = response["results"]

    group = group(conn, "group-1")
    assert group["arrival_on"] == "2026-12-14"
    assert group["departure_on"] == "2026-12-17"
    assert group["revision"] == 3
    assert group["outstanding_deposit_cents"] == 18_500
  end

  test "replays successful operations exactly and retains their audit records", %{conn: conn} do
    open = open_group("durable-open")
    payment = cash_payment("durable-payment", 500, 1)

    %{"results" => [open_result, _payment_result]} = post_batch(conn, [open, payment])

    stored_open = Repo.get_by!(PartnerOperation, operation_id: "durable-open")
    stored_payment = Repo.get_by!(PartnerOperation, operation_id: "durable-payment")

    assert stored_open.operation_type == "open_group"
    assert stored_open.payload === open
    assert stored_open.result === open_result
    assert stored_open.id < stored_payment.id

    reordered_open = open |> Map.to_list() |> Enum.reverse() |> Map.new()

    assert post_batch(conn, [reordered_open]) == %{"results" => [open_result]}

    assert get(conn, "/api/v1/operations/durable-open") |> json_response(200) == %{
             "data" => open_result
           }

    assert group(conn, "group-1")["revision"] == 2
  end

  test "replays remembered rejections and rejects changed retries", %{conn: conn} do
    post_batch(conn, [open_group(), cash_payment("initial-payment", 500, 1)])

    stale_operation = cash_payment("remembered-stale", 999_999, 1)

    stale_result =
      post_batch(conn, [stale_operation])
      |> Map.fetch!("results")
      |> List.first()

    assert stale_result == %{
             "operation_id" => "remembered-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    post_batch(conn, [cash_payment("later-payment", 500, 2)])

    assert post_batch(conn, [stale_operation]) == %{"results" => [stale_result]}

    corrected_retry = Map.put(stale_operation, "expected_revision", 3)

    assert post_batch(conn, [corrected_retry]) == %{
             "results" => [
               %{
                 "operation_id" => "remembered-stale",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert get(conn, "/api/v1/operations/remembered-stale") |> json_response(200) == %{
             "data" => stale_result
           }

    assert group(conn, "group-1") == %{
             "group_id" => "group-1",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "revision" => 3,
             "rooms" => [
               room("room-a", 15_000, 45_000, 9_000, 1_000),
               room("room-b", 17_500, 52_500, 10_500)
             ],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 1_000,
             "cash_paid_cents" => 1_000,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 18_500
           }
  end

  test "checks a supplied revision before all other group validation", %{conn: conn} do
    post_batch(conn, [open_group(), cash_payment("pay-1", 500, 1)])

    response = post_batch(conn, [cash_payment("stale-1", 999_999, 1)])

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "stale-1",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]
           }

    assert group(conn, "group-1")["revision"] == 2
    assert ledger(conn)["cash_held_cents"] == 500
  end

  test "calculates flexible deposits per room with half-up rounding", %{conn: conn} do
    response =
      post_batch(conn, [
        open_group("rounding", %{
          "group_id" => "rounding-group",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "rounding-a", "nightly_rate_cents" => 3},
            %{"room_id" => "rounding-b", "nightly_rate_cents" => 3}
          ]
        }),
        open_group("advance", %{
          "group_id" => "advance-group",
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "advance-room", "nightly_rate_cents" => 123}]
        })
      ])

    assert [
             %{"group_id" => "rounding-group", "deposit_due_cents" => 2},
             %{"group_id" => "advance-group", "deposit_due_cents" => 123}
           ] = response["results"]
  end

  test "validates opening and payment failures without creating or changing a group", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_group("bad-stay", %{"arrival_on" => "2026-12-13"}),
        open_group("bad-rooms", %{"rooms" => []}),
        open_group("bad-rate", %{"rate_plan" => "standard"}),
        open_group(),
        open_group("duplicate", %{"group_id" => "group-1"}),
        cash_payment("zero", 0, 1),
        cash_payment("excess", 19_501, 1),
        cash_payment("missing-group", 1, 99, "missing"),
        %{"operation_id" => "unknown", "type" => "unknown_operation"},
        %{
          "operation_id" => "incomplete-move",
          "type" => "reschedule_group",
          "group_id" => "group-1",
          "occurred_on" => "2026-10-04"
        }
      ])

    assert Enum.map(response["results"], & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan",
             nil,
             "group_already_exists",
             "invalid_amount",
             "payment_exceeds_outstanding",
             "group_not_found",
             "invalid_operation",
             "invalid_operation"
           ]

    assert group(conn, "group-1")["revision"] == 1
    assert group(conn, "group-1")["deposit_paid_cents"] == 0

    assert get(conn, "/api/v1/groups/bad-stay") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "cancellation settles flexible and advance-purchase cash and locks the group", %{
    conn: conn
  } do
    cancellation_results =
      post_batch(conn, [
        open_group("flex", %{"group_id" => "flex-group"}),
        cash_payment("flex-pay", 1_000, 1, "flex-group"),
        cancel("flex-cancel", "2026-11-26", 2, "flex-group"),
        open_group("advance", %{"group_id" => "advance-group", "rate_plan" => "advance_purchase"}),
        cash_payment("advance-pay", 2_000, 1, "advance-group"),
        cancel("advance-cancel", "2026-11-26", 2, "advance-group")
      ])

    assert %{"refunded_cents" => 1_000, "retained_cents" => 0, "revision" => 3} =
             Enum.at(cancellation_results["results"], 2)

    assert %{"refunded_cents" => 0, "retained_cents" => 2_000, "revision" => 3} =
             Enum.at(cancellation_results["results"], 5)

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 1_000,
             "cash_retained_cents" => 2_000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert %{
             "status" => "cancelled",
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0,
             "revision" => 3
           } = group(conn, "flex-group")

    response =
      post_batch(conn, [
        cash_payment("stale-after-cancel", 1, 2, "flex-group"),
        reschedule("move-after-cancel", "2026-12-14", nil, "flex-group")
      ])

    assert [
             %{
               "code" => "stale_revision",
               "expected_revision" => 2,
               "actual_revision" => 3
             },
             %{"code" => "group_not_active"}
           ] = response["results"]
  end

  test "fixes a cancellation policy at booking and recomputes its deadline when rescheduled", %{
    conn: conn
  } do
    post_batch(conn, [
      open_group("legacy-open", %{
        "group_id" => "legacy-group",
        "occurred_on" => "2026-12-31",
        "arrival_on" => "2027-02-14",
        "departure_on" => "2027-02-16"
      }),
      open_group("new-open", %{
        "group_id" => "new-group",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-17"
      }),
      reschedule("new-move", "2027-04-15", 1, "new-group"),
      open_group("advance-open", %{
        "group_id" => "advance-group",
        "rate_plan" => "advance_purchase"
      })
    ])

    assert %{
             "policy_version" => "flex-14",
             "refundable_until" => "2027-01-31"
           } = group(conn, "legacy-group")

    assert %{
             "policy_version" => "flex-30",
             "refundable_until" => "2027-03-16",
             "arrival_on" => "2027-04-15",
             "departure_on" => "2027-04-17"
           } = group(conn, "new-group")

    assert %{
             "policy_version" => "advance-nonrefundable",
             "refundable_until" => nil
           } = group(conn, "advance-group")
  end

  test "issues cancellation credit, applies it, and restores it without another bonus", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open_group("source-open", %{
          "group_id" => "source-group",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-15",
          "departure_on" => "2027-03-16"
        }),
        cash_payment("source-pay", 1_000, 1, "source-group"),
        Map.put(
          cancel("source-cancel", "2027-02-13", 2, "source-group"),
          "refund_method",
          "hotel_credit"
        ),
        open_group("target-open", %{
          "group_id" => "target-group",
          "occurred_on" => "2027-01-03",
          "arrival_on" => "2027-04-01",
          "departure_on" => "2027-04-02"
        }),
        hotel_credit_payment("target-credit", 1_000, 1, "2027-02-14", "target-group"),
        cancel("target-cancel", "2027-03-02", 2, "target-group")
      ])

    assert %{
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 1_100,
             "revision" => 3
           } = Enum.at(results["results"], 2)

    assert %{
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           } = Enum.at(results["results"], 5)

    assert %{"status" => "cancelled", "cash_paid_cents" => 0, "credit_paid_cents" => 0} =
             group(conn, "target-group")

    assert credit(conn, "guest-22", "2027-03-02") == %{
             "guest_id" => "guest-22",
             "available_cents" => 1_100,
             "lots" => [
               %{
                 "source_operation_id" => "source-cancel",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2028-02-14"
               }
             ]
           }

    assert ledger(conn, "2027-03-02") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 1_100,
             "credit_shortfall_cents" => 0
           }
  end

  test "uses credit by expiry and source order and rejects unavailable credit without changing a group",
       %{
         conn: conn
       } do
    response =
      post_batch(conn, [
        open_group("first-open", %{"group_id" => "first-source"}),
        cash_payment("first-pay", 500, 1, "first-source"),
        Map.put(
          cancel("z-lot", "2026-11-26", 2, "first-source"),
          "refund_method",
          "hotel_credit"
        ),
        open_group("second-open", %{"group_id" => "second-source"}),
        cash_payment("second-pay", 500, 1, "second-source"),
        Map.put(
          cancel("a-lot", "2026-11-26", 2, "second-source"),
          "refund_method",
          "hotel_credit"
        ),
        open_group("destination-open", %{"group_id" => "destination-group"}),
        hotel_credit_payment("destination-credit", 1_000, 1, "2026-11-27", "destination-group"),
        hotel_credit_payment("insufficient", 101, 2, "2026-11-27", "destination-group"),
        cancel("destination-cancel", "2026-12-01", 2, "destination-group")
      ])

    assert %{
             "status" => "rejected",
             "code" => "insufficient_credit",
             "group_id" => "destination-group"
           } =
             Enum.at(response["results"], 8)

    assert credit(conn, "guest-22", "2026-11-27") == %{
             "guest_id" => "guest-22",
             "available_cents" => 100,
             "lots" => [
               %{
                 "source_operation_id" => "z-lot",
                 "remaining_cents" => 100,
                 "expires_on" => "2027-11-27"
               }
             ]
           }

    assert %{"revision" => 3, "status" => "cancelled", "credit_paid_cents" => 0} =
             group(conn, "destination-group")

    assert ledger(conn, "2026-12-01")["credit_liability_cents"] == 100
  end

  test "expires restored credit immediately and rejects hotel credit for a non-refundable cancellation",
       %{
         conn: conn
       } do
    post_batch(conn, [
      open_group("expiring-source", %{
        "group_id" => "expiring-source-group",
        "occurred_on" => "2026-12-01",
        "arrival_on" => "2027-01-15",
        "departure_on" => "2027-01-16"
      }),
      cash_payment("expiring-source-pay", 1_000, 1, "expiring-source-group"),
      Map.put(
        cancel("expiring-source-cancel", "2027-01-01", 2, "expiring-source-group"),
        "refund_method",
        "hotel_credit"
      ),
      open_group("expiring-target", %{
        "group_id" => "expiring-target-group",
        "occurred_on" => "2027-01-02",
        "arrival_on" => "2028-02-15",
        "departure_on" => "2028-02-16"
      }),
      hotel_credit_payment("expiring-credit", 1_000, 1, "2028-01-01", "expiring-target-group"),
      open_group("advance-open", %{
        "group_id" => "nonrefundable-group",
        "rate_plan" => "advance_purchase"
      }),
      cash_payment("advance-pay", 1_000, 1, "nonrefundable-group")
    ])

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 1_000

    post_batch(conn, [
      cancel("expiring-target-cancel", "2028-01-02", 2, "expiring-target-group")
    ])

    assert credit(conn, "guest-22", "2028-01-02") == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }

    assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 0

    assert %{"status" => "active", "revision" => 2} = group(conn, "nonrefundable-group")

    results =
      post_batch(conn, [
        Map.put(
          cancel("advance-credit-cancel", "2026-11-26", 2, "nonrefundable-group"),
          "refund_method",
          "hotel_credit"
        ),
        Map.put(
          cancel("stale-advance-credit-cancel", "2026-11-26", 1, "nonrefundable-group"),
          "refund_method",
          "hotel_credit"
        )
      ])

    assert [
             %{"code" => "refund_method_not_available", "group_id" => "nonrefundable-group"},
             %{
               "code" => "stale_revision",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
           ] = results["results"]
  end

  test "rejects an invalid batch and returns missing groups as documented", %{conn: conn} do
    assert post(conn, "/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert get(conn, "/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert get(conn, "/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert get(conn, "/api/v1/ledger?on=not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert get(conn, "/api/v1/guests/guest-22/credit?on=not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }
  end

  test "accounts for rooms independently when a selected room is cancelled", %{conn: conn} do
    response =
      post_batch(conn, [
        open_group(),
        cash_payment("room-payment", 11_000, 1),
        cancel_rooms("invalid-room-cancel", ["room-a", "room-a"], 2),
        cancel_rooms("room-cancel", ["room-b"], 2)
      ])

    assert %{"code" => "invalid_rooms"} = Enum.at(response["results"], 2)

    room_cancel = %{
      "operation_id" => "room-cancel",
      "status" => "applied",
      "group_id" => "group-1",
      "cancelled_room_ids" => ["room-b"],
      "refunded_cents" => 2_000,
      "retained_cents" => 0,
      "credit_issued_cents" => 0,
      "revision" => 3
    }

    assert Enum.at(response["results"], 3) == room_cancel

    assert post_batch(conn, [cancel_rooms("room-cancel", ["room-b"], 2)]) == %{
             "results" => [room_cancel]
           }

    assert %{
             "status" => "active",
             "revision" => 3,
             "lodging_total_cents" => 45_000,
             "deposit_due_cents" => 9_000,
             "deposit_paid_cents" => 9_000,
             "outstanding_deposit_cents" => 0,
             "rooms" => [
               %{"room_id" => "room-a", "status" => "active", "cash_paid_cents" => 9_000},
               %{
                 "room_id" => "room-b",
                 "status" => "cancelled",
                 "cash_paid_cents" => 0,
                 "deposit_due_cents" => 10_500
               }
             ]
           } = group(conn, "group-1")

    assert %{"cash_held_cents" => 9_000, "cash_refunded_cents" => 2_000} = ledger(conn)

    assert %{"results" => [%{"refunded_cents" => 9_000, "revision" => 4}]} =
             post_batch(conn, [cancel("cancel-remainder", "2026-11-26", 3, "group-1")])

    assert %{
             "status" => "cancelled",
             "lodging_total_cents" => 0,
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "outstanding_deposit_cents" => 0
           } = group(conn, "group-1")

    assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 11_000} = ledger(conn)
  end

  test "reduces only held cash from its recorded payment and reconciles its disposition", %{
    conn: conn
  } do
    response =
      post_batch(conn, [
        open_group(),
        cash_payment("reducible-payment", 10_000, 1),
        reduce_cash_payment("reduce-payment", "reducible-payment", 1_500, 2)
      ])

    reduction = %{
      "operation_id" => "reduce-payment",
      "status" => "applied",
      "payment_operation_id" => "reducible-payment",
      "group_id" => "group-1",
      "amount_cents" => 1_500,
      "outstanding_deposit_cents" => 11_000,
      "revision" => 3
    }

    assert Enum.at(response["results"], 2) == reduction

    assert post_batch(conn, [reduce_cash_payment("reduce-payment", "reducible-payment", 1_500, 2)]) ==
             %{
               "results" => [reduction]
             }

    assert get(conn, "/api/v1/payments/reducible-payment") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "reducible-payment",
               "original_group_id" => "group-1",
               "recorded_cents" => 10_000,
               "held_cents" => 8_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_500,
               "charged_back_cents" => 0
             }
           }

    assert %{
             "outstanding_deposit_cents" => 11_000,
             "rooms" => [
               %{"room_id" => "room-a", "cash_paid_cents" => 8_500},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ]
           } = group(conn, "group-1")

    assert %{"cash_held_cents" => 8_500, "cash_reduced_cents" => 1_500} = ledger(conn)

    assert %{
             "results" => [
               %{"code" => "reduction_exceeds_held_cash"},
               %{"code" => "invalid_amount"}
             ]
           } =
             post_batch(conn, [
               reduce_cash_payment("excess-reduction", "reducible-payment", 8_501, 3),
               reduce_cash_payment("invalid-reduction", "reducible-payment", 0, 3)
             ])

    assert get(conn, "/api/v1/payments/open-1") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  test "charges back converted cash, reports a credit shortfall, and absorbs it on restoration",
       %{
         conn: conn
       } do
    post_batch(conn, [
      open_group("source-open", %{"group_id" => "source-group"}),
      cash_payment("source-payment-a", 500, 1, "source-group"),
      cash_payment("source-payment-b", 500, 2, "source-group"),
      Map.put(
        cancel("source-cancel", "2026-11-26", 3, "source-group"),
        "refund_method",
        "hotel_credit"
      ),
      open_group("target-open", %{
        "group_id" => "target-group",
        "occurred_on" => "2027-01-03",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02"
      }),
      hotel_credit_payment("target-credit", 1_000, 1, "2027-01-05", "target-group")
    ])

    chargeback =
      charge_back_payment("charge-source-payment", "source-payment-a", 4)

    chargeback_result = %{
      "operation_id" => "charge-source-payment",
      "status" => "applied",
      "payment_operation_id" => "source-payment-a",
      "group_id" => "source-group",
      "charged_back_cents" => 500,
      "outstanding_deposit_cents" => 0,
      "revision" => 5
    }

    assert post_batch(conn, [chargeback]) == %{"results" => [chargeback_result]}
    assert post_batch(conn, [chargeback]) == %{"results" => [chargeback_result]}

    assert get(conn, "/api/v1/payments/source-payment-a") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "source-payment-a",
               "original_group_id" => "source-group",
               "recorded_cents" => 500,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 500
             }
           }

    assert %{
             "cash_converted_to_credit_cents" => 500,
             "cash_charged_back_cents" => 500,
             "credit_liability_cents" => 1_000,
             "credit_shortfall_cents" => 450
           } = ledger(conn, "2027-01-05")

    assert %{"revision" => 2, "credit_paid_cents" => 1_000} = group(conn, "target-group")

    assert %{"results" => [%{"revision" => 3, "credit_issued_cents" => 0}]} =
             post_batch(conn, [cancel("target-cancel", "2027-02-01", 2, "target-group")])

    assert %{"credit_liability_cents" => 550, "credit_shortfall_cents" => 0} =
             ledger(conn, "2027-02-01")

    assert credit(conn, "guest-22", "2027-02-01") == %{
             "guest_id" => "guest-22",
             "available_cents" => 550,
             "lots" => [
               %{
                 "source_operation_id" => "source-cancel",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-11-27"
               }
             ]
           }
  end

  defp open_group(operation_id \\ "open-1", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
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

  defp room(
         room_id,
         nightly_rate_cents,
         lodging_total_cents,
         deposit_due_cents,
         cash_paid_cents \\ 0,
         credit_paid_cents \\ 0
       ) do
    %{
      "room_id" => room_id,
      "nightly_rate_cents" => nightly_rate_cents,
      "status" => "active",
      "lodging_total_cents" => lodging_total_cents,
      "deposit_due_cents" => deposit_due_cents,
      "cash_paid_cents" => cash_paid_cents,
      "credit_paid_cents" => credit_paid_cents
    }
  end

  defp cash_payment(operation_id, amount_cents, expected_revision, group_id \\ "group-1") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_rooms(operation_id, room_ids, expected_revision, group_id \\ "group-1") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2026-11-26",
      "group_id" => group_id,
      "room_ids" => room_ids,
      "expected_revision" => expected_revision
    }
  end

  defp reduce_cash_payment(operation_id, payment_operation_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp charge_back_payment(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp hotel_credit_payment(operation_id, amount_cents, expected_revision, occurred_on, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp reschedule(operation_id, new_arrival_on, expected_revision, group_id \\ "group-1") do
    operation = %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "new_arrival_on" => new_arrival_on
    }

    if is_nil(expected_revision),
      do: operation,
      else: Map.put(operation, "expected_revision", expected_revision)
  end

  defp cancel(operation_id, occurred_on, expected_revision, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn, on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"

    conn
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
