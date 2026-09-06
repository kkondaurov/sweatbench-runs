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
               "cash_retained_cents" => 0
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
               "cash_retained_cents" => 0
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
end
