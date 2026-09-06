defmodule GroupStayWeb.OperationalCoreTest do
  use GroupStayWeb.ConnCase

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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_503}
        ]
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "rejects an invalid batch and accepts an empty one", %{conn: conn} do
    invalid = conn |> post(~p"/api/v1/partner-batches", %{}) |> json_response(422)
    assert invalid == %{"error" => %{"code" => "invalid_batch"}}

    assert submit(build_conn(), []) == []
  end

  test "opens and reads a group with room-level deposit rounding and original room order", %{
    conn: conn
  } do
    assert [result] = submit(conn, [open_operation()])

    # 45,003 * 20% = 9,000.6 -> 9,001; 52,509 * 20% = 10,501.8 -> 10,502.
    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19_503,
             "revision" => 1
           }

    data = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

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
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_503}
             ],
             "lodging_total_cents" => 97_512,
             "deposit_due_cents" => 19_503,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_503
           }
  end

  test "advance purchase requires the full lodging amount", %{conn: conn} do
    [result] = submit(conn, [open_operation(%{"rate_plan" => "advance_purchase"})])
    assert result["deposit_due_cents"] == 97_512
  end

  test "validates group opening and does not create rejected groups" do
    cases = [
      {Map.delete(open_operation(), "rooms"), "invalid_operation"},
      {open_operation(%{"departure_on" => "2026-12-10"}), "invalid_stay"},
      {open_operation(%{"rooms" => []}), "invalid_rooms"},
      {open_operation(%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 0}]}),
       "invalid_rooms"},
      {open_operation(%{
         "rooms" => [
           %{"room_id" => "a", "nightly_rate_cents" => 100},
           %{"room_id" => "a", "nightly_rate_cents" => 200}
         ]
       }), "invalid_rooms"},
      {open_operation(%{"rate_plan" => "mystery"}), "invalid_rate_plan"}
    ]

    Enum.with_index(cases, fn {operation, code}, index ->
      operation =
        operation
        |> Map.put("operation_id", "bad-open-#{index}")
        |> Map.put("group_id", "bad-#{index}")

      assert [%{"status" => "rejected", "code" => ^code}] = submit(build_conn(), [operation])

      assert build_conn() |> get("/api/v1/groups/bad-#{index}") |> json_response(404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end)
  end

  test "processes operations in order and isolates rejected operations", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      },
      %{
        "operation_id" => "too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 99_999,
        "expected_revision" => 2
      },
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-31",
        "expected_revision" => 2
      }
    ]

    [open, payment, rejected, moved] = submit(conn, operations)
    assert open["revision"] == 1

    assert payment == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_503,
             "revision" => 2
           }

    assert rejected["code"] == "payment_exceeds_outstanding"

    assert moved == %{
             "operation_id" => "move-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2027-01-31",
             "new_departure_on" => "2027-02-03",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-01-17",
             "revision" => 3
           }
  end

  test "stale revision wins over domain errors and leaves group and ledger unchanged", %{
    conn: conn
  } do
    submit(conn, [open_operation()])

    [result] =
      submit(build_conn(), [
        %{
          "operation_id" => "stale-payment",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -10,
          "expected_revision" => 99
        }
      ])

    assert result == %{
             "operation_id" => "stale-payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 99,
             "actual_revision" => 1
           }

    assert get(build_conn(), ~p"/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1

    assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "missing groups are resolved before revision checks", %{conn: conn} do
    [result] =
      submit(conn, [
        %{
          "operation_id" => "missing",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "absent",
          "expected_revision" => 99
        }
      ])

    assert result["code"] == "group_not_found"
  end

  test "payments validate amounts and outstanding deposit", %{conn: conn} do
    submit(conn, [open_operation()])

    base = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81"
    }

    assert [invalid] =
             submit(build_conn(), [
               base
               |> Map.put("operation_id", "pay-invalid")
               |> Map.put("amount_cents", 0)
             ])

    assert invalid["code"] == "invalid_amount"

    assert [bad_date] =
             submit(build_conn(), [
               base
               |> Map.put("operation_id", "pay-bad-date")
               |> Map.put("amount_cents", 100)
               |> Map.put("occurred_on", "not-a-date")
             ])

    assert bad_date["code"] == "invalid_operation"

    assert [over] =
             submit(build_conn(), [
               base
               |> Map.put("operation_id", "pay-over")
               |> Map.put("amount_cents", 19_504)
             ])

    assert over["code"] == "payment_exceeds_outstanding"

    assert [paid] =
             submit(build_conn(), [
               base
               |> Map.put("operation_id", "pay-full")
               |> Map.put("amount_cents", 19_503)
             ])

    assert paid["outstanding_deposit_cents"] == 0
    assert paid["revision"] == 2
  end

  test "cancellation moves held cash to refunded at the 14-day boundary", %{conn: conn} do
    submit(conn, [
      open_operation(),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      }
    ])

    [cancelled] =
      submit(build_conn(), [
        %{
          "operation_id" => "cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-26",
          "group_id" => "group-81",
          "expected_revision" => 2
        }
      ])

    assert cancelled["refunded_cents"] == 5_000
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 3

    data =
      get(build_conn(), ~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert data["status"] == "cancelled"
    assert data["outstanding_deposit_cents"] == 0

    assert get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }

    [inactive] =
      submit(build_conn(), [
        Map.put(
          %{
            "operation_id" => "again",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-27",
            "group_id" => "group-81"
          },
          "expected_revision",
          3
        )
      ])

    assert inactive["code"] == "group_not_active"
  end

  test "late flexible and all advance-purchase cancellations retain paid cash" do
    for {group_id, rate_plan, occurred_on} <- [
          {"flex", "flexible", "2026-11-27"},
          {"advance", "advance_purchase", "2026-10-04"}
        ] do
      open =
        open_operation(%{
          "operation_id" => "open-#{group_id}",
          "group_id" => group_id,
          "rate_plan" => rate_plan
        })

      due = if rate_plan == "flexible", do: 19_503, else: 97_512

      results =
        submit(build_conn(), [
          open,
          %{
            "operation_id" => "pay-#{group_id}",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => group_id,
            "amount_cents" => due
          },
          %{
            "operation_id" => "cancel-#{group_id}",
            "type" => "cancel_group",
            "occurred_on" => occurred_on,
            "group_id" => group_id
          }
        ])

      cancelled = List.last(results)
      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == due
    end

    ledger = get(build_conn(), ~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_retained_cents"] == 117_015
  end

  test "rescheduling changes the arrival used for cancellation", %{conn: conn} do
    [_, _, cancellation] =
      submit(conn, [
        open_operation(),
        %{
          "operation_id" => "move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-10-20"
        },
        %{
          "operation_id" => "cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-10",
          "group_id" => "group-81"
        }
      ])

    assert cancellation["retained_cents"] == 0

    data =
      get(build_conn(), ~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert data["arrival_on"] == "2026-10-20"
    assert data["departure_on"] == "2026-10-23"
  end

  test "duplicate groups, unknown operations, and missing operation data are rejected", %{
    conn: conn
  } do
    submit(conn, [open_operation()])

    [duplicate, unknown, incomplete] =
      submit(build_conn(), [
        open_operation(%{"operation_id" => "duplicate"}),
        %{"operation_id" => "unknown", "type" => "feed_gremlin"},
        %{"operation_id" => "incomplete", "type" => "record_cash_payment"}
      ])

    assert duplicate["code"] == "group_already_exists"
    assert unknown["code"] == "invalid_operation"
    assert incomplete["code"] == "invalid_operation"
  end
end
