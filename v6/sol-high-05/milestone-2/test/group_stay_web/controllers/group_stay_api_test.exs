defmodule GroupStayWeb.GroupStayAPITest do
  use GroupStayWeb.ConnCase, async: false

  test "rejects an invalid batch" do
    conn = post(build_conn(), "/api/v1/partner-batches", %{})

    assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})

    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => "not-a-list"})
    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
  end

  test "accepts an empty batch and starts with an empty ledger" do
    assert submit([]) == []

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "opens and reads a flexible group with room-level deposit calculations" do
    operation = open_operation("group-flex")

    assert [result] = submit([operation])

    assert result == %{
             "operation_id" => "open-group-flex",
             "status" => "applied",
             "group_id" => "group-flex",
             "deposit_due_cents" => 19_500,
             "revision" => 1
           }

    conn = get(build_conn(), "/api/v1/groups/group-flex")

    assert %{"data" => group} = json_response(conn, 200)

    assert group == %{
             "group_id" => "group-flex",
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
  end

  test "rounds each flexible room deposit independently" do
    operation =
      open_operation("tiny-group", %{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "tiny-a", "nightly_rate_cents" => 2},
          %{"room_id" => "tiny-b", "nightly_rate_cents" => 2}
        ]
      })

    assert [%{"deposit_due_cents" => 0, "status" => "applied"}] = submit([operation])

    assert %{"data" => %{"lodging_total_cents" => 4, "deposit_due_cents" => 0}} =
             get(build_conn(), "/api/v1/groups/tiny-group") |> json_response(200)
  end

  test "advance purchase requires the full lodging total" do
    operation = open_operation("advance", %{"rate_plan" => "advance_purchase"})

    assert [%{"deposit_due_cents" => 97_500, "revision" => 1}] = submit([operation])
  end

  test "rejects invalid open operations without creating groups" do
    operations = [
      open_operation("bad-stay", %{"departure_on" => "2026-12-10"}),
      open_operation("bad-rooms", %{
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 100},
          %{"room_id" => "same", "nightly_rate_cents" => 200}
        ]
      }),
      open_operation("bad-plan", %{"rate_plan" => "breakfast_and_goblins"}),
      Map.delete(open_operation("missing"), "property_id"),
      %{"operation_id" => "unknown", "type" => "dance_group"}
    ]

    assert [
             %{"code" => "invalid_stay"},
             %{"code" => "invalid_rooms"},
             %{"code" => "invalid_rate_plan"},
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"}
           ] = submit(operations)

    for group_id <- ["bad-stay", "bad-rooms", "bad-plan", "missing"] do
      assert json_response(get(build_conn(), "/api/v1/groups/#{group_id}"), 404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end
  end

  test "keeps operation order, continues after rejection, and rejects duplicate groups" do
    operations = [
      open_operation("ordered"),
      %{
        "operation_id" => "too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "ordered",
        "amount_cents" => 20_000
      },
      %{
        "operation_id" => "payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "ordered",
        "amount_cents" => 5_000
      },
      open_operation("ordered", %{"operation_id" => "duplicate"})
    ]

    assert [
             %{"status" => "applied", "revision" => 1},
             %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
             %{
               "status" => "applied",
               "revision" => 2,
               "outstanding_deposit_cents" => 14_500
             },
             %{"status" => "rejected", "code" => "group_already_exists"}
           ] = submit(operations)

    assert %{"data" => %{"deposit_paid_cents" => 5_000, "revision" => 2}} =
             get(build_conn(), "/api/v1/groups/ordered") |> json_response(200)
  end

  test "validates cash payments and exposes held cash" do
    submit([open_operation("payments")])

    operations = [
      payment("missing-group", "none", 100),
      payment("zero", "payments", 0),
      payment("string", "payments", "100"),
      Map.delete(payment("missing-date", "payments", 100), "occurred_on"),
      payment("paid", "payments", 19_500),
      payment("already-covered", "payments", 1)
    ]

    assert [
             %{"code" => "group_not_found"},
             %{"code" => "invalid_amount"},
             %{"code" => "invalid_amount"},
             %{"code" => "invalid_operation"},
             %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2},
             %{"code" => "payment_exceeds_outstanding"}
           ] = submit(operations)

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 19_500,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "reschedules a stay without changing its length or price" do
    submit([open_operation("move")])

    assert [
             %{
               "status" => "applied",
               "new_arrival_on" => "2027-01-20",
               "new_departure_on" => "2027-01-23",
               "revision" => 2
             }
           ] =
             submit([
               %{
                 "operation_id" => "move-it",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "move",
                 "new_arrival_on" => "2027-01-20"
               }
             ])

    assert %{
             "data" => %{
               "arrival_on" => "2027-01-20",
               "departure_on" => "2027-01-23",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "revision" => 2
             }
           } = get(build_conn(), "/api/v1/groups/move") |> json_response(200)
  end

  test "rejects a non-future reschedule without changing the group" do
    submit([open_operation("bad-move")])

    assert [%{"code" => "invalid_stay", "status" => "rejected"}] =
             submit([
               %{
                 "operation_id" => "bad-move-op",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "bad-move",
                 "new_arrival_on" => "2026-11-01"
               }
             ])

    assert %{"data" => %{"arrival_on" => "2026-12-10", "revision" => 1}} =
             get(build_conn(), "/api/v1/groups/bad-move") |> json_response(200)
  end

  test "refunds early flexible cancellations and clears cash held and deposit balances" do
    submit([open_operation("refund"), payment("fund-refund", "refund", 10_000)])

    assert [
             %{
               "status" => "applied",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 3
             }
           ] = submit([cancellation("cancel-refund", "refund", "2026-11-26")])

    assert %{
             "data" => %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "revision" => 3
             }
           } = get(build_conn(), "/api/v1/groups/refund") |> json_response(200)

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 10_000,
               "cash_retained_cents" => 0
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
  end

  test "retains late flexible and all advance-purchase cash" do
    submit([
      open_operation("late-flex"),
      payment("fund-late", "late-flex", 1_000),
      open_operation("advance-cancel", %{"rate_plan" => "advance_purchase"}),
      payment("fund-advance", "advance-cancel", 2_000)
    ])

    assert [
             %{"refunded_cents" => 0, "retained_cents" => 1_000},
             %{"refunded_cents" => 0, "retained_cents" => 2_000}
           ] =
             submit([
               cancellation("late", "late-flex", "2026-11-27"),
               cancellation("advance", "advance-cancel", "2026-10-04")
             ])

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3_000
             }
           } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
  end

  test "checks revisions after existence and before other domain rules" do
    submit([
      open_operation("revisions"),
      Map.put(payment("revision-payment", "revisions", 1_000), "expected_revision", 1),
      cancellation("revision-cancel", "revisions", "2026-11-01")
    ])

    operations = [
      payment("missing", "not-there", 100) |> Map.put("expected_revision", 99),
      payment("stale", "revisions", -1) |> Map.put("expected_revision", 1),
      payment("inactive", "revisions", -1) |> Map.put("expected_revision", 3)
    ]

    assert [
             %{"code" => "group_not_found"},
             %{
               "code" => "stale_revision",
               "group_id" => "revisions",
               "expected_revision" => 1,
               "actual_revision" => 3
             },
             %{"code" => "group_not_active"}
           ] = submit(operations)

    assert %{"data" => %{"revision" => 3}} =
             get(build_conn(), "/api/v1/groups/revisions") |> json_response(200)
  end

  test "applies revision checks against earlier operations in the same batch" do
    submit([open_operation("same-batch")])

    assert [
             %{"status" => "applied", "revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"status" => "applied", "revision" => 3}
           ] =
             submit([
               payment("first", "same-batch", 100) |> Map.put("expected_revision", 1),
               payment("stale", "same-batch", 100) |> Map.put("expected_revision", 1),
               payment("third", "same-batch", 100) |> Map.put("expected_revision", 2)
             ])
  end

  test "rejects later operations for cancelled groups without incrementing revision" do
    submit([open_operation("done"), cancellation("cancel-done", "done", "2026-11-01")])

    assert [
             %{"code" => "group_not_active"},
             %{"code" => "group_not_active"},
             %{"code" => "group_not_active"}
           ] =
             submit([
               payment("late-payment", "done", 100),
               %{
                 "operation_id" => "late-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-02",
                 "group_id" => "done",
                 "new_arrival_on" => "2027-01-01"
               },
               cancellation("cancel-again", "done", "2026-11-02")
             ])

    assert %{"data" => %{"revision" => 2}} =
             get(build_conn(), "/api/v1/groups/done") |> json_response(200)
  end

  test "missing operation data is rejected and processing continues" do
    operations = [
      Map.delete(payment("missing-amount", "structure", 100), "amount_cents"),
      open_operation("structure"),
      Map.delete(cancellation("missing-date", "structure", "2026-11-01"), "occurred_on"),
      payment("after-rejections", "structure", 500)
    ]

    assert [
             %{"code" => "group_not_found"},
             %{"status" => "applied", "revision" => 1},
             %{"code" => "invalid_operation"},
             %{"status" => "applied", "revision" => 2}
           ] = submit(operations)
  end

  test "fixes cancellation policy at booking and recomputes its date after rescheduling" do
    submit([
      open_operation("legacy-policy", %{
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      }),
      open_operation("new-policy", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      }),
      open_operation("advance-policy", %{"rate_plan" => "advance_purchase"})
    ])

    assert %{
             "data" => %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-24"
             }
           } = get(build_conn(), "/api/v1/groups/legacy-policy") |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-02-08"
             }
           } = get(build_conn(), "/api/v1/groups/new-policy") |> json_response(200)

    assert %{
             "data" => %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
           } = get(build_conn(), "/api/v1/groups/advance-policy") |> json_response(200)

    assert [
             %{
               "status" => "applied",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-04-17"
             }
           ] =
             submit([
               %{
                 "operation_id" => "move-legacy-policy",
                 "type" => "reschedule_group",
                 "occurred_on" => "2027-02-01",
                 "group_id" => "legacy-policy",
                 "new_arrival_on" => "2027-05-01"
               }
             ])
  end

  test "uses the inclusive 30-day boundary for new flexible groups" do
    open =
      open_operation("thirty-day", %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

    submit([open, payment("fund-thirty", "thirty-day", 1_000)])

    assert [%{"refunded_cents" => 1_000, "retained_cents" => 0}] =
             submit([cancellation("at-boundary", "thirty-day", "2027-02-08")])

    submit([
      Map.put(open, "group_id", "inside-thirty")
      |> Map.put("operation_id", "open-inside-thirty"),
      payment("fund-inside", "inside-thirty", 1_000)
    ])

    assert [%{"refunded_cents" => 0, "retained_cents" => 1_000}] =
             submit([cancellation("inside-boundary", "inside-thirty", "2027-02-09")])
  end

  test "converts refundable cash to a rounded bonus lot and reports date-aware balances" do
    submit([
      open_operation("credit-source"),
      payment("fund-credit-source", "credit-source", 10_005)
    ])

    assert [
             %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_006,
               "revision" => 3
             }
           ] =
             submit([
               cancellation("issue-credit", "credit-source", "2026-11-26")
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert json_response(
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-11-26"),
             200
           ) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 11_006,
               "lots" => [
                 %{
                   "source_operation_id" => "issue-credit",
                   "remaining_cents" => 11_006,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }
           }

    assert %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_005,
               "credit_liability_cents" => 11_006
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-11-26") |> json_response(200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-11-27")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(build_conn(), "/api/v1/ledger?on=2027-11-27") |> json_response(200)
  end

  test "applies credit in lot order and keeps allocated credit in the liability" do
    for {group_id, operation_id, cancelled_on} <- [
          {"source-early-z", "z-early", "2026-11-01"},
          {"source-early-a", "a-early", "2026-11-01"},
          {"source-later", "a-later", "2026-11-02"}
        ] do
      submit([
        open_operation(group_id),
        payment("fund-#{group_id}", group_id, 1_000),
        cancellation(operation_id, group_id, cancelled_on)
        |> Map.put("refund_method", "hotel_credit")
      ])
    end

    submit([
      open_operation("credit-target", %{
        "arrival_on" => "2028-02-01",
        "departure_on" => "2028-02-04"
      })
    ])

    assert [%{"code" => "insufficient_credit", "status" => "rejected"}] =
             submit([hotel_credit("too-much-credit", "credit-target", 3_301, "2026-11-03")])

    assert [
             %{
               "status" => "applied",
               "amount_cents" => 1_200,
               "outstanding_deposit_cents" => 18_300,
               "revision" => 2
             }
           ] = submit([hotel_credit("use-credit", "credit-target", 1_200, "2026-11-03")])

    assert %{
             "data" => %{
               "deposit_paid_cents" => 1_200,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 1_200
             }
           } = get(build_conn(), "/api/v1/groups/credit-target") |> json_response(200)

    # Earlier expiry wins over source id, while equal expiries use source id as their tie-breaker.
    assert %{
             "data" => %{
               "available_cents" => 2_100,
               "lots" => [
                 %{"source_operation_id" => "z-early", "remaining_cents" => 1_000},
                 %{"source_operation_id" => "a-later", "remaining_cents" => 1_100}
               ]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-11-03")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 2_300}} =
             get(build_conn(), "/api/v1/ledger?on=2027-11-02") |> json_response(200)

    # After every lot expires, only the 1,200 funding the active group remains a liability.
    assert %{"data" => %{"credit_liability_cents" => 1_200}} =
             get(build_conn(), "/api/v1/ledger?on=2027-11-03") |> json_response(200)
  end

  test "restores applied lots without a second bonus while converting only new cash" do
    issue_credit("restore-source", "restore-lot", 10_000, "2026-11-01")

    submit([
      open_operation("restore-target", %{
        "arrival_on" => "2027-08-01",
        "departure_on" => "2027-08-04"
      }),
      hotel_credit("apply-restored", "restore-target", 4_000, "2026-11-02"),
      payment("cash-and-credit", "restore-target", 2_000)
    ])

    assert [
             %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 2_200,
               "revision" => 4
             }
           ] =
             submit([
               cancellation("refund-mixed", "restore-target", "2027-07-18")
               |> Map.put("refund_method", "hotel_credit")
             ])

    assert %{
             "data" => %{
               "available_cents" => 13_200,
               "lots" => [
                 %{"source_operation_id" => "restore-lot", "remaining_cents" => 11_000},
                 %{"source_operation_id" => "refund-mixed", "remaining_cents" => 2_200}
               ]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-07-18")
             |> json_response(200)

    assert %{
             "data" => %{
               "cash_refunded_cents" => 0,
               "cash_converted_to_credit_cents" => 12_000,
               "credit_liability_cents" => 13_200
             }
           } = get(build_conn(), "/api/v1/ledger?on=2027-07-18") |> json_response(200)
  end

  test "pauses allocated expiry, then drops expired credit when refundable cancellation restores it" do
    issue_credit("expiry-source", "expiry-lot", 10_000, "2026-01-01")

    submit([
      open_operation("expiry-target", %{
        "occurred_on" => "2026-01-02",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04"
      }),
      hotel_credit("apply-expiring", "expiry-target", 4_000, "2026-01-02")
    ])

    assert %{"data" => %{"available_cents" => 0}} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-01-02")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 4_000}} =
             get(build_conn(), "/api/v1/ledger?on=2027-01-02") |> json_response(200)

    assert [%{"credit_issued_cents" => 0, "status" => "applied"}] =
             submit([cancellation("restore-expired", "expiry-target", "2027-02-15")])

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(build_conn(), "/api/v1/ledger?on=2027-02-15") |> json_response(200)
  end

  test "consumes applied credit on non-refundable cancellation and rejects credit refund method" do
    issue_credit("consume-source", "consume-lot", 10_000, "2026-11-01")

    submit([
      open_operation("consume-target", %{"rate_plan" => "advance_purchase"}),
      hotel_credit("apply-consumed", "consume-target", 4_000, "2026-11-02")
    ])

    assert [%{"code" => "refund_method_not_available", "status" => "rejected"}] =
             submit([
               cancellation("bad-credit-refund", "consume-target", "2026-11-03")
               |> Map.put("refund_method", "hotel_credit")
               |> Map.put("expected_revision", 2)
             ])

    assert %{"data" => %{"status" => "active", "revision" => 2}} =
             get(build_conn(), "/api/v1/groups/consume-target") |> json_response(200)

    assert [%{"retained_cents" => 0, "credit_issued_cents" => 0, "revision" => 3}] =
             submit([cancellation("consume-credit", "consume-target", "2026-11-03")])

    assert %{"data" => %{"available_cents" => 7_000}} =
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-11-03")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 7_000}} =
             get(build_conn(), "/api/v1/ledger?on=2026-11-03") |> json_response(200)
  end

  test "checks credit revisions before refund and balance rules and validates read dates" do
    submit([open_operation("credit-validation")])

    assert [
             %{"code" => "stale_revision", "actual_revision" => 1},
             %{"code" => "invalid_amount"},
             %{"code" => "payment_exceeds_outstanding"},
             %{"code" => "insufficient_credit"}
           ] =
             submit([
               hotel_credit("stale-credit", "credit-validation", -1, "bad-date")
               |> Map.put("expected_revision", 99),
               hotel_credit("bad-amount", "credit-validation", 0, "2026-10-04"),
               hotel_credit("over-deposit", "credit-validation", 20_000, "2026-10-04"),
               hotel_credit("not-funded", "credit-validation", 100, "2026-10-04")
             ])

    assert json_response(get(build_conn(), "/api/v1/ledger?on=not-a-date"), 422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert json_response(
             get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-02-30"),
             422
           ) == %{"error" => %{"code" => "invalid_date"}}

    assert %{"data" => %{"revision" => 1}} =
             get(build_conn(), "/api/v1/groups/credit-validation") |> json_response(200)
  end

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
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

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancellation(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp hotel_credit(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp issue_credit(group_id, cancellation_id, cash_cents, occurred_on) do
    submit([
      open_operation(group_id, %{
        "occurred_on" => Date.add(Date.from_iso8601!(occurred_on), -30) |> Date.to_iso8601(),
        "arrival_on" => Date.add(Date.from_iso8601!(occurred_on), 30) |> Date.to_iso8601(),
        "departure_on" => Date.add(Date.from_iso8601!(occurred_on), 33) |> Date.to_iso8601()
      }),
      payment("fund-#{group_id}", group_id, cash_cents),
      cancellation(cancellation_id, group_id, occurred_on)
      |> Map.put("refund_method", "hotel_credit")
    ])
  end
end
