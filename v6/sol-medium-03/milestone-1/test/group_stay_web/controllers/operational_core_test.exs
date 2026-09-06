defmodule GroupStayWeb.OperationalCoreTest do
  use GroupStayWeb.ConnCase, async: false

  test "rejects an invalid batch and accepts an empty batch", %{conn: conn} do
    conn = post(conn, "/api/v1/partner-batches", %{})
    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => []})
    assert json_response(conn, 200) == %{"results" => []}
  end

  test "opens a group with per-room rounding and returns the complete view", %{conn: conn} do
    operation =
      open_operation(%{
        "rooms" => [
          %{"room_id" => "odd-cent", "nightly_rate_cents" => 102},
          %{"room_id" => "rounds-up", "nightly_rate_cents" => 103}
        ]
      })

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "deposit_due_cents" => 123,
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
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "revision" => 1,
               "rooms" => [
                 %{"room_id" => "odd-cent", "nightly_rate_cents" => 102},
                 %{"room_id" => "rounds-up", "nightly_rate_cents" => 103}
               ],
               "lodging_total_cents" => 615,
               "deposit_due_cents" => 123,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 123
             }
           }
  end

  test "advance purchase requires the full lodging total", %{conn: conn} do
    operation = open_operation(%{"rate_plan" => "advance_purchase"})
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

    assert %{"results" => [%{"deposit_due_cents" => 45_000}]} = json_response(conn, 200)
  end

  test "open validation rejects atomically and the batch continues", %{conn: conn} do
    operations = [
      open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "bad-rooms", "rooms" => []}),
      open_operation(%{"operation_id" => "bad-rate", "rate_plan" => "mystery"}),
      open_operation(),
      open_operation(%{"operation_id" => "duplicate"}),
      %{"operation_id" => "unknown", "type" => "dance_group"},
      open_operation(%{"operation_id" => "second", "group_id" => "group-2"})
    ]

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert Enum.map(json_response(conn, 200)["results"], &{&1["operation_id"], &1["code"]}) == [
             {"bad-stay", "invalid_stay"},
             {"bad-rooms", "invalid_rooms"},
             {"bad-rate", "invalid_rate_plan"},
             {"open-1", nil},
             {"duplicate", "group_already_exists"},
             {"unknown", "invalid_operation"},
             {"second", nil}
           ]

    assert json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]["revision"] ==
             1

    assert json_response(get(build_conn(), "/api/v1/groups/group-2"), 200)["data"]["revision"] ==
             1
  end

  test "validates rooms and missing operation data", %{conn: conn} do
    operations = [
      open_operation(%{
        "operation_id" => "duplicate-rooms",
        "rooms" => [
          %{"room_id" => "same", "nightly_rate_cents" => 10},
          %{"room_id" => "same", "nightly_rate_cents" => 20}
        ]
      }),
      open_operation(%{
        "operation_id" => "bad-price",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 0}]
      }),
      open_operation(%{
        "operation_id" => "overflow",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => Integer.pow(10, 38)}]
      }),
      Map.delete(open_operation(%{"operation_id" => "missing"}), "guest_id"),
      "not-an-operation",
      open_operation(%{"operation_id" => "continues", "group_id" => "group-2"})
    ]

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) == [
             "invalid_rooms",
             "invalid_rooms",
             "invalid_rooms",
             "invalid_operation",
             "invalid_operation",
             nil
           ]
  end

  test "payments use same-batch revisions and stale checks precede domain validation", %{
    conn: conn
  } do
    operations = [
      open_operation(),
      payment_operation("pay-1", 3_000, 1),
      payment_operation("stale", -1, 1),
      payment_operation("pay-2", 6_000, 2),
      payment_operation("too-much", 1, 3)
    ]

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    results = json_response(conn, 200)["results"]

    assert Enum.at(results, 1) == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-1",
             "amount_cents" => 3_000,
             "outstanding_deposit_cents" => 6_000,
             "revision" => 2
           }

    assert Enum.at(results, 2) == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-1",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert Enum.at(results, 3)["revision"] == 3
    assert Enum.at(results, 3)["outstanding_deposit_cents"] == 0
    assert Enum.at(results, 4)["code"] == "payment_exceeds_outstanding"

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 9_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "missing groups win over revision and payment validation errors", %{conn: conn} do
    operation = payment_operation("missing", -10, 99, "absent")
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "missing",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             ]
           }
  end

  test "concurrent writes cannot both apply against the same revision", %{conn: conn} do
    post(conn, "/api/v1/partner-batches", %{"operations" => [open_operation()]})

    results =
      [payment_operation("concurrent-a", 1_000, 1), payment_operation("concurrent-b", 1_000, 1)]
      |> Task.async_stream(
        fn operation -> GroupStay.Reservations.apply_batch([operation]) |> hd() end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(Enum.map(results, & &1.status)) == ["applied", "rejected"]
    assert Enum.find(results, &(&1.status == "rejected")).code == "stale_revision"

    data = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert data["revision"] == 2
    assert data["deposit_paid_cents"] == 1_000
  end

  test "rescheduling shifts both stay dates and preserves price", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1",
        "new_arrival_on" => "2027-01-30",
        "expected_revision" => 1
      }
    ]

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert List.last(json_response(conn, 200)["results"]) == %{
             "operation_id" => "move",
             "status" => "applied",
             "group_id" => "group-1",
             "new_arrival_on" => "2027-01-30",
             "new_departure_on" => "2027-02-02",
             "revision" => 2
           }

    data = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert data["lodging_total_cents"] == 45_000
    assert data["deposit_due_cents"] == 9_000

    invalid = %{
      "operation_id" => "invalid-move",
      "type" => "reschedule_group",
      "occurred_on" => "2027-02-01",
      "group_id" => "group-1",
      "new_arrival_on" => "2027-02-01"
    }

    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => [invalid]})
    assert get_in(json_response(conn, 200), ["results", Access.at(0), "code"]) == "invalid_stay"
  end

  test "flexible cancellation at the 14-day boundary refunds paid cash", %{conn: conn} do
    operations = [
      open_operation(),
      payment_operation("pay", 4_000),
      cancel_operation("cancel", "2026-11-26")
    ]

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

    assert List.last(json_response(conn, 200)["results"]) == %{
             "operation_id" => "cancel",
             "status" => "applied",
             "group_id" => "group-1",
             "refunded_cents" => 4_000,
             "retained_cents" => 0,
             "revision" => 3
           }

    data = json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]
    assert data["status"] == "cancelled"
    assert data["deposit_due_cents"] == 9_000
    assert data["deposit_paid_cents"] == 4_000
    assert data["outstanding_deposit_cents"] == 0

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 4_000,
             "cash_retained_cents" => 0
           }
  end

  test "late flexible and advance-purchase cancellations retain cash", %{conn: conn} do
    operations = [
      open_operation(),
      payment_operation("flex-pay", 2_000),
      cancel_operation("flex-cancel", "2026-11-27"),
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      }),
      payment_operation("advance-pay", 10_000, nil, "advance"),
      cancel_operation("advance-cancel", "2026-10-04", "advance")
    ]

    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    results = json_response(conn, 200)["results"]
    assert Enum.at(results, 2)["retained_cents"] == 2_000
    assert Enum.at(results, 5)["retained_cents"] == 10_000

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 12_000
           }
  end

  test "operations after cancellation are rejected without revision or ledger changes", %{
    conn: conn
  } do
    initial = [
      open_operation(),
      payment_operation("pay", 1_000),
      cancel_operation("cancel", "2026-11-27")
    ]

    post(conn, "/api/v1/partner-batches", %{"operations" => initial})

    rejected = [
      payment_operation("late-pay", 1),
      %{
        "operation_id" => "late-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-1",
        "new_arrival_on" => "2027-01-01"
      },
      cancel_operation("second-cancel", "2026-11-28")
    ]

    conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => rejected})

    assert Enum.map(json_response(conn, 200)["results"], & &1["code"]) ==
             List.duplicate("group_not_active", 3)

    assert json_response(get(build_conn(), "/api/v1/groups/group-1"), 200)["data"]["revision"] ==
             3

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200)["data"]["cash_retained_cents"] ==
             1_000
  end

  test "missing group read and initial ledger use documented errors and totals", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/groups/not-there"), 404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
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
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, amount, expected_revision \\ nil, group_id \\ "group-1") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
    |> maybe_expected_revision(expected_revision)
  end

  defp cancel_operation(operation_id, occurred_on, group_id \\ "group-1") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp maybe_expected_revision(operation, nil), do: operation

  defp maybe_expected_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)
end
