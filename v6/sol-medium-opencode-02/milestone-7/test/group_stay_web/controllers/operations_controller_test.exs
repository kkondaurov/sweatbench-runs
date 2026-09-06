defmodule GroupStayWeb.OperationsControllerTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

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

  defp operation(type, id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "rejects a body without an operations array", %{conn: conn} do
    response = conn |> post("/api/v1/partner-batches", %{}) |> json_response(422)
    assert response == %{"error" => %{"code" => "invalid_batch"}}

    response =
      conn |> post("/api/v1/partner-batches", %{"operations" => %{}}) |> json_response(422)

    assert response == %{"error" => %{"code" => "invalid_batch"}}
  end

  test "opens and reads a group with calculated totals and original room order", %{conn: conn} do
    assert submit(conn, [open_operation()]) == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    data = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert data == %{
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
  end

  test "rounds each flexible room deposit separately and fully deposits advance purchases", %{
    conn: conn
  } do
    rounded =
      open_operation(%{
        "group_id" => "rounded",
        "rooms" => [
          %{"room_id" => "a", "nightly_rate_cents" => 2},
          %{"room_id" => "b", "nightly_rate_cents" => 3}
        ],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11"
      })

    advance =
      open_operation(%{
        "operation_id" => "open-2",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 10_001}],
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12"
      })

    assert [rounded_result, advance_result] = submit(conn, [rounded, advance])
    assert rounded_result["deposit_due_cents"] == 1
    assert advance_result["deposit_due_cents"] == 20_002
  end

  test "processes operations in order and a rejection does not stop or undo the batch", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      operation("record_cash_payment", "pay-too-much", %{"amount_cents" => 20_000}),
      operation("record_cash_payment", "pay-1", %{
        "amount_cents" => 5_000,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", "pay-stale", %{
        "amount_cents" => -1,
        "expected_revision" => 1
      }),
      operation("record_cash_payment", "pay-2", %{
        "amount_cents" => 14_500,
        "expected_revision" => 2
      })
    ]

    assert [opened, excessive, paid, stale, paid_rest] = submit(conn, operations)
    assert opened["status"] == "applied"
    assert excessive["code"] == "payment_exceeds_outstanding"

    assert paid == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_500,
             "revision" => 2
           }

    assert stale == %{
             "operation_id" => "pay-stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert paid_rest["revision"] == 3
    assert paid_rest["outstanding_deposit_cents"] == 0

    ledger = conn |> get("/api/v1/ledger") |> json_response(200)

    assert ledger == %{
             "data" => %{
               "cash_held_cents" => 19_500,
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

  test "reschedules by preserving stay length and validates against the operation date", %{
    conn: conn
  } do
    assert [_, moved, invalid] =
             submit(conn, [
               open_operation(),
               operation("reschedule_group", "move-1", %{
                 "new_arrival_on" => "2027-01-20",
                 "expected_revision" => 1
               }),
               operation("reschedule_group", "move-2", %{"new_arrival_on" => "2026-10-04"})
             ])

    assert moved == %{
             "operation_id" => "move-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2027-01-20",
             "new_departure_on" => "2027-01-23",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-01-06",
             "revision" => 2
           }

    assert invalid["code"] == "invalid_stay"

    data = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert data["revision"] == 2
    assert data["lodging_total_cents"] == 97_500
  end

  test "refunds flexible cash at the 14 day boundary and updates ledger totals", %{conn: conn} do
    assert [_, _, cancelled] =
             submit(conn, [
               open_operation(),
               operation("record_cash_payment", "pay", %{"amount_cents" => 10_000}),
               operation("cancel_group", "cancel", %{
                 "occurred_on" => "2026-11-26",
                 "expected_revision" => 2
               })
             ])

    assert cancelled == %{
             "operation_id" => "cancel",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 10_000,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert conn |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["outstanding_deposit_cents"] == 0

    assert [inactive] =
             submit(conn, [operation("record_cash_payment", "late-pay", %{"amount_cents" => 1})])

    assert inactive["code"] == "group_not_active"
    assert inactive["actual_revision"] == nil
  end

  test "retains late flexible and all advance-purchase cash", %{conn: conn} do
    late = open_operation(%{"group_id" => "late"})

    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    operations = [
      late,
      operation("record_cash_payment", "pay-late", %{"group_id" => "late", "amount_cents" => 100}),
      operation("cancel_group", "cancel-late", %{
        "group_id" => "late",
        "occurred_on" => "2026-11-27"
      }),
      advance,
      operation("record_cash_payment", "pay-advance", %{
        "group_id" => "advance",
        "amount_cents" => 200
      }),
      operation("cancel_group", "cancel-advance", %{
        "group_id" => "advance",
        "occurred_on" => "2026-10-04"
      })
    ]

    results = submit(conn, operations)
    assert Enum.at(results, 2)["retained_cents"] == 100
    assert Enum.at(results, 5)["retained_cents"] == 200

    assert conn |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 300,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
           }
  end

  test "rejects invalid opens without creating partial records", %{conn: conn} do
    invalid_operations = [
      open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "bad-rooms", "rooms" => []}),
      open_operation(%{
        "operation_id" => "duplicate-rooms",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 2}
        ]
      }),
      open_operation(%{"operation_id" => "bad-rate", "rate_plan" => "mystery"})
    ]

    assert Enum.map(submit(conn, invalid_operations), & &1["code"]) == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rooms",
             "invalid_rate_plan"
           ]

    assert conn |> get("/api/v1/groups/group-81") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "uses stable errors for duplicates, missing groups, and malformed operations", %{
    conn: conn
  } do
    assert [_, duplicate, missing, unknown, malformed, invalid_id] =
             submit(conn, [
               open_operation(),
               open_operation(%{"operation_id" => "duplicate"}),
               operation("cancel_group", "missing", %{
                 "group_id" => "absent",
                 "expected_revision" => 99
               }),
               operation("unknown", "unknown"),
               %{"operation_id" => "malformed", "type" => "record_cash_payment"},
               operation("cancel_group", "invalid-id", %{"group_id" => 123})
             ])

    assert duplicate["code"] == "group_already_exists"
    assert missing["code"] == "group_not_found"
    assert unknown["code"] == "invalid_operation"
    assert malformed["code"] == "invalid_operation"
    assert invalid_id["code"] == "invalid_operation"
  end

  test "returns an empty ledger and a stable missing-group response", %{conn: conn} do
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

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "fixes the cancellation policy at booking and recomputes its deadline on reschedule", %{
    conn: conn
  } do
    modern =
      open_operation(%{
        "operation_id" => "open-modern",
        "group_id" => "modern",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-12"
      })

    advance =
      open_operation(%{
        "operation_id" => "open-advance-policy",
        "group_id" => "advance-policy",
        "rate_plan" => "advance_purchase"
      })

    assert [_, _, moved, _] =
             submit(conn, [
               open_operation(),
               modern,
               operation("reschedule_group", "move-modern", %{
                 "group_id" => "modern",
                 "occurred_on" => "2027-01-02",
                 "new_arrival_on" => "2027-04-10"
               }),
               advance
             ])

    legacy = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    modern = conn |> get("/api/v1/groups/modern") |> json_response(200) |> Map.fetch!("data")

    advance =
      conn |> get("/api/v1/groups/advance-policy") |> json_response(200) |> Map.fetch!("data")

    assert {legacy["policy_version"], legacy["refundable_until"]} ==
             {"flex-14", "2026-11-26"}

    assert {modern["policy_version"], modern["refundable_until"]} ==
             {"flex-30", "2027-03-11"}

    assert moved["policy_version"] == "flex-30"
    assert moved["refundable_until"] == "2027-03-11"
    assert advance["policy_version"] == "advance-nonrefundable"
    assert advance["refundable_until"] == nil
  end

  test "converts refundable cash to expiring hotel credit with the rounded bonus", %{conn: conn} do
    assert [_, _, cancelled] =
             submit(conn, [
               open_operation(),
               operation("record_cash_payment", "pay-credit", %{"amount_cents" => 5_005}),
               operation("cancel_group", "cancel-credit", %{
                 "occurred_on" => "2026-11-26",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 5_506

    assert conn |> get("/api/v1/guests/guest-22/credit?on=2027-11-26") |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 5_506,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-credit",
                   "remaining_cents" => 5_506,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }
           }

    ledger =
      conn |> get("/api/v1/ledger?on=2027-11-26") |> json_response(200) |> Map.fetch!("data")

    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 5_005
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["credit_liability_cents"] == 5_506

    expired = conn |> get("/api/v1/guests/guest-22/credit?on=2027-11-27") |> json_response(200)
    assert expired["data"]["available_cents"] == 0
    assert expired["data"]["lots"] == []

    assert conn
           |> get("/api/v1/ledger?on=2027-11-27")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "applies equal-expiry lots by source id and restores them without a second bonus", %{
    conn: conn
  } do
    source = fn group_id, open_id, pay_id, cancel_id ->
      [
        open_operation(%{
          "operation_id" => open_id,
          "group_id" => group_id,
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02",
          "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1_000}]
        }),
        operation("record_cash_payment", pay_id, %{"group_id" => group_id, "amount_cents" => 100}),
        operation("cancel_group", cancel_id, %{
          "group_id" => group_id,
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      ]
    end

    target =
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-08-01",
        "departure_on" => "2027-08-02"
      })

    operations =
      source.("source-z", "open-z", "pay-z", "z-cancel") ++
        source.("source-a", "open-a", "pay-a", "a-cancel") ++
        [
          target,
          operation("apply_hotel_credit", "apply", %{
            "group_id" => "target",
            "occurred_on" => "2027-01-02",
            "amount_cents" => 150,
            "expected_revision" => 1
          }),
          operation("apply_hotel_credit", "stale-apply", %{
            "group_id" => "target",
            "occurred_on" => "2027-01-02",
            "amount_cents" => -1,
            "expected_revision" => 1
          }),
          operation("apply_hotel_credit", "insufficient", %{
            "group_id" => "target",
            "occurred_on" => "2027-01-02",
            "amount_cents" => 100
          })
        ]

    results = submit(conn, operations)
    assert Enum.at(results, 7)["revision"] == 2
    assert Enum.at(results, 8)["code"] == "stale_revision"
    assert Enum.at(results, 9)["code"] == "insufficient_credit"

    credit = conn |> get("/api/v1/guests/guest-22/credit?on=2027-01-02") |> json_response(200)
    assert credit["data"]["available_cents"] == 70

    assert Enum.map(credit["data"]["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [{"z-cancel", 70}]

    target_data = conn |> get("/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")
    assert target_data["cash_paid_cents"] == 0
    assert target_data["credit_paid_cents"] == 150
    assert target_data["deposit_paid_cents"] == 150

    ledger = conn |> get("/api/v1/ledger?on=2027-01-02") |> json_response(200)
    assert ledger["data"]["cash_held_cents"] == 0
    assert ledger["data"]["credit_liability_cents"] == 220

    assert [cancelled] =
             submit(conn, [
               operation("cancel_group", "cancel-target", %{
                 "group_id" => "target",
                 "occurred_on" => "2027-02-01",
                 "expected_revision" => 2
               })
             ])

    assert cancelled["credit_issued_cents"] == 0

    restored = conn |> get("/api/v1/guests/guest-22/credit?on=2027-02-01") |> json_response(200)
    assert restored["data"]["available_cents"] == 220

    assert Enum.map(restored["data"]["lots"], &{&1["source_operation_id"], &1["remaining_cents"]}) ==
             [
               {"a-cancel", 110},
               {"z-cancel", 110}
             ]
  end

  test "pauses applied credit expiry and removes it when restoration is already expired", %{
    conn: conn
  } do
    source =
      open_operation(%{
        "group_id" => "expiry-source",
        "occurred_on" => "2025-12-01",
        "arrival_on" => "2026-06-01",
        "departure_on" => "2026-06-02",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1_000}]
      })

    target =
      open_operation(%{
        "operation_id" => "open-expiry-target",
        "group_id" => "expiry-target",
        "occurred_on" => "2026-03-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-16"
      })

    assert Enum.all?(
             submit(conn, [
               source,
               operation("record_cash_payment", "expiry-pay", %{
                 "group_id" => "expiry-source",
                 "amount_cents" => 100
               }),
               operation("cancel_group", "expiry-credit", %{
                 "group_id" => "expiry-source",
                 "occurred_on" => "2026-01-01",
                 "refund_method" => "hotel_credit"
               }),
               target,
               operation("apply_hotel_credit", "expiry-apply", %{
                 "group_id" => "expiry-target",
                 "occurred_on" => "2026-06-01",
                 "amount_cents" => 110
               })
             ]),
             &(&1["status"] == "applied")
           )

    ledger = conn |> get("/api/v1/ledger?on=2027-02-01") |> json_response(200)
    assert ledger["data"]["credit_liability_cents"] == 110

    assert [cancelled] =
             submit(conn, [
               operation("cancel_group", "cancel-expiry-target", %{
                 "group_id" => "expiry-target",
                 "occurred_on" => "2027-02-01"
               })
             ])

    assert cancelled["status"] == "applied"

    assert conn
           |> get("/api/v1/ledger?on=2027-02-01")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0

    assert conn
           |> get("/api/v1/guests/guest-22/credit?on=2027-02-01")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 0
  end

  test "rejects hotel credit for a non-refundable cancellation and later consumes applied credit",
       %{
         conn: conn
       } do
    credit_source =
      open_operation(%{
        "group_id" => "credit-source",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1_000}]
      })

    advance =
      open_operation(%{
        "operation_id" => "open-credit-advance",
        "group_id" => "credit-advance",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1_000}],
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02"
      })

    results =
      submit(conn, [
        credit_source,
        operation("record_cash_payment", "source-pay", %{
          "group_id" => "credit-source",
          "amount_cents" => 100
        }),
        operation("cancel_group", "source-cancel", %{
          "group_id" => "credit-source",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        }),
        advance,
        operation("apply_hotel_credit", "advance-apply", %{
          "group_id" => "credit-advance",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 110
        }),
        operation("cancel_group", "rejected-credit-cancel", %{
          "group_id" => "credit-advance",
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        })
      ])

    rejected = List.last(results)
    assert rejected["code"] == "refund_method_not_available"

    group =
      conn |> get("/api/v1/groups/credit-advance") |> json_response(200) |> Map.fetch!("data")

    assert group["status"] == "active"
    assert group["revision"] == 2
    assert group["credit_paid_cents"] == 110

    assert conn
           |> get("/api/v1/ledger?on=2026-11-03")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 110

    assert [cancelled] =
             submit(conn, [
               operation("cancel_group", "cash-cancel-advance", %{
                 "group_id" => "credit-advance",
                 "occurred_on" => "2026-11-03",
                 "expected_revision" => 2
               })
             ])

    assert cancelled["retained_cents"] == 0
    assert cancelled["credit_issued_cents"] == 0

    assert conn
           |> get("/api/v1/ledger?on=2026-11-03")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "replays an applied operation exactly without consulting changed group state", %{
    conn: conn
  } do
    payment =
      operation("record_cash_payment", "durable-payment", %{
        "amount_cents" => 5_000,
        "expected_revision" => 1
      })

    assert [_, original, _] =
             submit(conn, [
               open_operation(),
               payment,
               operation("record_cash_payment", "later-payment", %{
                 "amount_cents" => 1_000,
                 "expected_revision" => 2
               })
             ])

    assert original["revision"] == 2
    assert original["outstanding_deposit_cents"] == 14_500
    assert submit(conn, [payment]) == [original]

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["revision"] == 3
    assert group["cash_paid_cents"] == 6_000

    assert conn |> get("/api/v1/operations/durable-payment") |> json_response(200) == %{
             "data" => original
           }
  end

  test "remembers rejections even when domain state later makes the operation valid", %{
    conn: conn
  } do
    payment =
      operation("record_cash_payment", "missing-payment", %{
        "amount_cents" => 100,
        "expected_revision" => 1
      })

    assert [original, _] = submit(conn, [payment, open_operation()])
    assert original["code"] == "group_not_found"
    assert submit(conn, [payment]) == [original]

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["revision"] == 1
    assert group["cash_paid_cents"] == 0
  end

  test "replays original stale-revision details and rejects a corrected payload", %{conn: conn} do
    stale =
      operation("record_cash_payment", "stale-payment", %{
        "amount_cents" => 100,
        "expected_revision" => 1
      })

    assert [_, _, original, _] =
             submit(conn, [
               open_operation(),
               operation("record_cash_payment", "first-payment", %{"amount_cents" => 100}),
               stale,
               operation("record_cash_payment", "second-payment", %{"amount_cents" => 100})
             ])

    assert original["code"] == "stale_revision"
    assert original["actual_revision"] == 2
    assert submit(conn, [stale]) == [original]

    corrected = Map.put(stale, "expected_revision", 3)
    assert [conflict] = submit(conn, [corrected])
    assert conflict["code"] == "operation_id_conflict"

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["revision"] == 3
    assert group["cash_paid_cents"] == 200
  end

  test "rejects reuse with a different payload and preserves the original audit record", %{
    conn: conn
  } do
    original = open_operation()
    changed = open_operation(%{"arrival_on" => "2026-12-11"})

    assert [opened] = submit(conn, [original])

    assert submit(conn, [changed]) == [
             %{
               "operation_id" => "open-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
           ]

    assert conn |> get("/api/v1/operations/open-1") |> json_response(200) == %{"data" => opened}

    record = GroupStay.Repo.get_by!(GroupStay.OperationRecord, operation_id: "open-1")
    assert record.operation_type == "open_group"
    assert record.submission == original
    assert record.result == opened
    assert GroupStay.Repo.aggregate(GroupStay.OperationRecord, :count) == 1
  end

  test "retains malformed submissions and durable records in first-commit order", %{conn: conn} do
    malformed = %{
      "operation_id" => "bad-1",
      "type" => "unknown",
      "nested" => %{"b" => 2, "a" => 1}
    }

    assert [rejected, _] = submit(conn, [malformed, open_operation()])
    assert rejected["code"] == "invalid_operation"

    records =
      GroupStay.Repo.all(
        from record in GroupStay.OperationRecord,
          order_by: [asc: record.id]
      )

    assert Enum.map(records, & &1.operation_id) == ["bad-1", "open-1"]
    assert hd(records).submission === malformed

    assert submit(conn, [
             %{"nested" => %{"a" => 1, "b" => 2}, "type" => "unknown", "operation_id" => "bad-1"}
           ]) == [rejected]
  end

  test "returns a stable response for a missing operation", %{conn: conn} do
    assert conn |> get("/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end
end
