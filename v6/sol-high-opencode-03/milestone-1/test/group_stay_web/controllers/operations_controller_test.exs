defmodule GroupStayWeb.OperationsControllerTest do
  use GroupStayWeb.ConnCase

  test "rejects a body without an operations array" do
    conn = post(build_conn(), "/api/v1/partner-batches", %{})

    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})

    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
  end

  test "opens a group and returns all booking and deposit details" do
    operation =
      open_operation("open-1", "group-1", %{
        "rooms" => [
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
        ]
      })

    assert [result] = submit([operation])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-1",
             "deposit_due_cents" => 19_500,
             "revision" => 1
           }

    conn = get(build_conn(), "/api/v1/groups/group-1")

    assert json_response(conn, 200) == %{
             "data" => %{
               "group_id" => "group-1",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
           }
  end

  test "calculates flexible deposits per room and advance deposits in full" do
    flexible =
      open_operation("open-flex", "group-flex", %{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 2},
          %{"room_id" => "room-b", "nightly_rate_cents" => 3}
        ]
      })

    advance =
      open_operation("open-advance", "group-advance", %{
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12_345}]
      })

    assert [
             %{"status" => "applied", "deposit_due_cents" => 1},
             %{"status" => "applied", "deposit_due_cents" => 24_690}
           ] = submit([flexible, advance])
  end

  test "rejects invalid opens and operations while continuing the batch" do
    invalid_stay =
      open_operation("bad-stay", "group-2", %{
        "departure_on" => "2026-12-10"
      })

    invalid_rooms =
      open_operation("bad-rooms", "group-3", %{
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 100},
          %{"room_id" => "same", "nightly_rate_cents" => 200}
        ]
      })

    invalid_rate = open_operation("bad-rate", "group-4", %{"rate_plan" => "mystery"})

    assert results =
             submit([
               open_operation("open-1", "group-1"),
               open_operation("duplicate", "group-1"),
               invalid_stay,
               invalid_rooms,
               invalid_rate,
               %{"operation_id" => "unknown", "type" => "unknown"},
               payment_operation("missing", "missing-group", 100, 99),
               open_operation("open-5", "group-5")
             ])

    assert Enum.map(results, &{&1["operation_id"], &1["status"], &1["code"]}) == [
             {"open-1", "applied", nil},
             {"duplicate", "rejected", "group_already_exists"},
             {"bad-stay", "rejected", "invalid_stay"},
             {"bad-rooms", "rejected", "invalid_rooms"},
             {"bad-rate", "rejected", "invalid_rate_plan"},
             {"unknown", "rejected", "invalid_operation"},
             {"missing", "rejected", "group_not_found"},
             {"open-5", "applied", nil}
           ]

    assert json_response(get(build_conn(), "/api/v1/groups/group-2"), 404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "applies payments in order and gives stale revisions precedence" do
    results =
      submit([
        open_operation("open", "group-1"),
        payment_operation("stale", "group-1", -1, 9),
        payment_operation("pay", "group-1", 1_000, 1),
        %{
          "operation_id" => "stale-missing-amount",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "expected_revision" => 1
        },
        payment_operation("invalid", "group-1", 0, 2),
        payment_operation("too-much", "group-1", 99_999, 2),
        payment_operation("pay-again", "group-1", 500, 2)
      ])

    assert Enum.at(results, 1) == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 9,
             "actual_revision" => 1
           }

    assert Enum.at(results, 2) == %{
             "operation_id" => "pay",
             "status" => "applied",
             "group_id" => "group-1",
             "amount_cents" => 1_000,
             "outstanding_deposit_cents" => 5_000,
             "revision" => 2
           }

    assert Enum.at(results, 3)["code"] == "stale_revision"
    assert Enum.at(results, 4)["code"] == "invalid_amount"
    assert Enum.at(results, 5)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 6)["revision"] == 3

    group = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert group["revision"] == 3
    assert group["deposit_paid_cents"] == 1_500
    assert group["outstanding_deposit_cents"] == 4_500
  end

  test "reschedules active groups without changing stay length or price" do
    results =
      submit([
        open_operation("open", "group-1"),
        %{
          "operation_id" => "move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 1
        },
        %{
          "operation_id" => "bad-move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-20",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        }
      ])

    assert Enum.at(results, 1) == %{
             "operation_id" => "move",
             "status" => "applied",
             "group_id" => "group-1",
             "new_arrival_on" => "2026-12-20",
             "new_departure_on" => "2026-12-23",
             "revision" => 2
           }

    assert Enum.at(results, 2)["code"] == "invalid_stay"

    group = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert group["arrival_on"] == "2026-12-20"
    assert group["departure_on"] == "2026-12-23"
    assert group["lodging_total_cents"] == 30_000
    assert group["deposit_due_cents"] == 6_000
    assert group["revision"] == 2
  end

  test "settles cancellation cash and reports ledger totals" do
    operations = [
      open_operation("open-refund", "refund", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-21"
      }),
      payment_operation("pay-refund", "refund", 1_000, 1),
      cancel_operation("cancel-refund", "refund", "2026-12-06", 2),
      open_operation("open-retain", "retain", %{
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-21"
      }),
      payment_operation("pay-retain", "retain", 1_000, 1),
      cancel_operation("cancel-retain", "retain", "2026-12-07", 2),
      open_operation("open-advance", "advance", %{
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2026-12-20",
        "departure_on" => "2026-12-21"
      }),
      payment_operation("pay-advance", "advance", 1_000, 1),
      cancel_operation("cancel-advance", "advance", "2026-10-05", 2),
      open_operation("open-held", "held"),
      payment_operation("pay-held", "held", 500, 1),
      payment_operation("inactive-payment", "refund", 1, 3),
      cancel_operation("inactive-cancel", "refund", "2026-12-07", 3)
    ]

    results = submit(operations)

    assert Enum.at(results, 2) |> Map.take(["refunded_cents", "retained_cents", "revision"]) == %{
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "revision" => 3
           }

    assert Enum.at(results, 5) |> Map.take(["refunded_cents", "retained_cents"]) == %{
             "refunded_cents" => 0,
             "retained_cents" => 1_000
           }

    assert Enum.at(results, 8) |> Map.take(["refunded_cents", "retained_cents"]) == %{
             "refunded_cents" => 0,
             "retained_cents" => 1_000
           }

    assert Enum.at(results, 11)["code"] == "group_not_active"
    assert Enum.at(results, 12)["code"] == "group_not_active"

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 500,
               "cash_refunded_cents" => 1_000,
               "cash_retained_cents" => 2_000
             }
           }

    cancelled = json_response(get(build_conn(), "/api/v1/groups/refund"), 200)["data"]
    assert cancelled["status"] == "cancelled"
    assert cancelled["revision"] == 3
    assert cancelled["outstanding_deposit_cents"] == 0
  end

  test "requires operation data without changing an existing group" do
    results =
      submit([
        open_operation("open", "group-1"),
        %{
          "operation_id" => "missing-amount",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-1"
        },
        %{
          "operation_id" => "missing-date",
          "type" => "cancel_group",
          "group_id" => "group-1"
        },
        %{"operation_id" => "missing-group", "type" => "reschedule_group"},
        %{"type" => "cancel_group", "group_id" => "group-1"}
      ])

    assert Enum.map(results, & &1["code"]) == [
             nil,
             "invalid_operation",
             "invalid_operation",
             "invalid_operation",
             "invalid_operation"
           ]

    group = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert group["revision"] == 1
    assert group["status"] == "active"
  end

  test "applies existing-group operations without expected revisions" do
    payment = payment_operation("pay", "group-1", 500, 1) |> Map.delete("expected_revision")

    reschedule = %{
      "operation_id" => "move",
      "type" => "reschedule_group",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "new_arrival_on" => "2026-12-20"
    }

    cancellation =
      cancel_operation("cancel", "group-1", "2026-11-01", 3)
      |> Map.delete("expected_revision")

    results = submit([open_operation("open", "group-1"), payment, reschedule, cancellation])

    assert Enum.map(results, &{&1["status"], &1["revision"]}) == [
             {"applied", 1},
             {"applied", 2},
             {"applied", 3},
             {"applied", 4}
           ]
  end

  test "serializes concurrent updates at the revision check" do
    assert [%{"status" => "applied"}] = submit([open_operation("open", "group-1")])

    operations = [
      payment_operation("pay-1", "group-1", 100, 1),
      payment_operation("pay-2", "group-1", 100, 1)
    ]

    results =
      operations
      |> Enum.map(fn operation ->
        Task.async(fn -> GroupStay.Operations.submit([operation]) |> List.first() end)
      end)
      |> Task.await_many()

    assert Enum.sort(Enum.map(results, &{&1.status, &1[:code]})) == [
             {"applied", nil},
             {"rejected", "stale_revision"}
           ]

    group = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert group["deposit_paid_cents"] == 100
    assert group["revision"] == 2
  end

  defp submit(operations) do
    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})
    json_response(conn, 200)["results"]
  end

  defp open_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, group_id, amount_cents, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "expected_revision" => expected_revision
    }
  end
end
