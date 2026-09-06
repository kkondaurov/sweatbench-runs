defmodule GroupStayWeb.OperationsControllerTest do
  use GroupStayWeb.ConnCase, async: false

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

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "opens a group, preserving room order and rounding deposits per room", %{conn: conn} do
    operation =
      open_operation(%{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "odd-cent", "nightly_rate_cents" => 3},
          %{"room_id" => "second", "nightly_rate_cents" => 4}
        ]
      })

    assert [result] = submit(conn, [operation])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 2,
             "revision" => 1
           }

    data = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert data["booked_on"] == "2026-10-03"
    assert data["lodging_total_cents"] == 7
    assert data["outstanding_deposit_cents"] == 2
    assert Enum.map(data["rooms"], & &1["room_id"]) == ["odd-cent", "second"]

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_held_cents"] == 0
  end

  test "processes in order and isolates rejected operations", %{conn: conn} do
    operations = [
      open_operation(),
      payment("pay-too-much", "group-81", 19_501),
      Map.put(payment("pay-1", "group-81", 5_000), "expected_revision", 1),
      %{
        "operation_id" => "stale",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20",
        "expected_revision" => 1
      },
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-20",
        "expected_revision" => 2
      }
    ]

    [opened, too_much, paid, stale, moved] = submit(conn, operations)
    assert opened["revision"] == 1
    assert too_much["code"] == "payment_exceeds_outstanding"
    assert paid["revision"] == 2

    assert stale == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert moved["new_departure_on"] == "2026-12-23"
    assert moved["revision"] == 3

    data = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert data["revision"] == 3
    assert data["deposit_paid_cents"] == 5_000
  end

  test "refunds timely flexible cancellations and updates ledger totals", %{conn: conn} do
    [_, _, cancellation] =
      submit(conn, [
        open_operation(),
        payment("pay", "group-81", 5_000),
        cancellation("cancel", "group-81", "2026-11-26")
      ])

    assert cancellation["refunded_cents"] == 5_000
    assert cancellation["retained_cents"] == 0
    assert cancellation["revision"] == 3

    group = conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["outstanding_deposit_cents"] == 0

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_converted_to_credit_cents" => 0,
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 5_000,
             "cash_retained_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "retains late flexible and advance-purchase cash", %{conn: conn} do
    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    results =
      submit(conn, [
        open_operation(),
        advance,
        payment("late-pay", "group-81", 1_000),
        payment("advance-pay", "advance", 2_000),
        cancellation("late-cancel", "group-81", "2026-11-27"),
        cancellation("advance-cancel", "advance", "2026-10-10")
      ])

    assert Enum.at(results, 4)["retained_cents"] == 1_000
    assert Enum.at(results, 5)["retained_cents"] == 2_000

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_retained_cents"] == 3_000
  end

  test "returns stable errors and continues after malformed operations", %{conn: conn} do
    results =
      submit(conn, [
        Map.delete(open_operation(), "rooms"),
        open_operation(%{"operation_id" => "bad-rooms", "rooms" => []}),
        open_operation(%{"operation_id" => "bad-plan", "rate_plan" => "mystery"}),
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
        open_operation(%{"operation_id" => "bad-date", "arrival_on" => "not-a-date"}),
        %{"operation_id" => "unknown", "type" => "dance"},
        open_operation(%{"operation_id" => "valid"})
      ])

    assert Enum.map(results, & &1["code"]) == [
             "invalid_operation",
             "invalid_rooms",
             "invalid_rate_plan",
             "invalid_stay",
             "invalid_stay",
             "invalid_operation",
             nil
           ]
  end

  test "checks existence before revision and revision before domain rules", %{conn: conn} do
    [_, stale, missing] =
      submit(conn, [
        open_operation(),
        payment("stale-bad-payment", "group-81", -1) |> Map.put("expected_revision", 99),
        %{
          "operation_id" => "missing",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "absent",
          "expected_revision" => 99
        }
      ])

    assert stale["code"] == "stale_revision"
    assert missing["code"] == "group_not_found"
  end

  test "rejects invalid batches and missing group reads", %{conn: conn} do
    response = conn |> post("/api/v1/partner-batches", %{}) |> json_response(422)
    assert response == %{"error" => %{"code" => "invalid_batch"}}

    response = conn |> get("/api/v1/groups/absent") |> json_response(404)
    assert response == %{"error" => %{"code" => "group_not_found"}}
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
