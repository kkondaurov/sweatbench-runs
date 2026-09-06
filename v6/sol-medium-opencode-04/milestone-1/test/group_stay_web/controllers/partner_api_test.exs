defmodule GroupStayWeb.PartnerApiTest do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp post_operations(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "opens and reads a group with ordered rooms and calculated totals", %{conn: conn} do
    assert [result] = post_operations(conn, [open_operation()])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19_500,
             "revision" => 1
           }

    data = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert data["rooms"] == [
             %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
             %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
           ]

    assert data["lodging_total_cents"] == 97_500
    assert data["deposit_due_cents"] == 19_500
    assert data["deposit_paid_cents"] == 0
    assert data["outstanding_deposit_cents"] == 19_500
    assert data["revision"] == 1
    assert data["booked_on"] == "2026-10-03"
    assert data["status"] == "active"
  end

  test "advance purchase requires the full lodging amount", %{conn: conn} do
    op = open_operation(%{"rate_plan" => "advance_purchase"})
    assert [%{"deposit_due_cents" => 97_500}] = post_operations(conn, [op])
  end

  test "rounds flexible deposits per room before summing", %{conn: conn} do
    op =
      open_operation(%{
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 3},
          %{"room_id" => "room-b", "nightly_rate_cents" => 3}
        ]
      })

    assert [%{"deposit_due_cents" => 2}] = post_operations(conn, [op])
  end

  test "validates opening fields without persisting rejected groups", %{conn: conn} do
    operations = [
      open_operation(%{"operation_id" => "stay", "departure_on" => "2026-12-10"}),
      open_operation(%{"operation_id" => "rooms", "rooms" => []}),
      open_operation(%{"operation_id" => "rate", "rate_plan" => "mystery"}),
      Map.delete(open_operation(%{"operation_id" => "missing"}), "guest_id"),
      open_operation(%{"operation_id" => "valid"}),
      open_operation(%{"operation_id" => "duplicate"})
    ]

    assert [
             %{"code" => "invalid_stay"},
             %{"code" => "invalid_rooms"},
             %{"code" => "invalid_rate_plan"},
             %{"code" => "invalid_operation"},
             %{"status" => "applied"},
             %{"code" => "group_already_exists"}
           ] = post_operations(conn, operations)
  end

  test "processes payments in order and enforces revision before domain validation", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "expected_revision" => 1,
        "amount_cents" => 5_000
      },
      %{
        "operation_id" => "stale",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "expected_revision" => 1,
        "amount_cents" => -1
      },
      %{
        "operation_id" => "too-much",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 20_000
      }
    ]

    assert [_, paid, stale, exceeds] = post_operations(conn, operations)
    assert paid["outstanding_deposit_cents"] == 14_500
    assert paid["revision"] == 2

    assert stale == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert exceeds["code"] == "payment_exceeds_outstanding"

    data = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert data["deposit_paid_cents"] == 5_000
    assert data["revision"] == 2

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 5_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "reschedules by preserving stay length and rejects unusable dates", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-02"
      },
      %{
        "operation_id" => "bad-move",
        "type" => "reschedule_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-02-01"
      }
    ]

    assert [_, moved, bad] = post_operations(conn, operations)
    assert moved["new_arrival_on"] == "2027-01-02"
    assert moved["new_departure_on"] == "2027-01-05"
    assert moved["revision"] == 2
    assert bad["code"] == "invalid_stay"
  end

  test "cancellation refunds flexible cash at least fourteen days before arrival", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 6_000
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      %{
        "operation_id" => "after",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81",
        "amount_cents" => 1
      }
    ]

    assert [_, _, cancelled, after_cancel] = post_operations(conn, operations)
    assert cancelled["refunded_cents"] == 6_000
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 3
    assert after_cancel["code"] == "group_not_active"

    group = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["outstanding_deposit_cents"] == 0

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

    assert ledger == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 6_000,
             "cash_retained_cents" => 0
           }
  end

  test "late flexible and advance purchase cancellations retain paid cash", %{conn: conn} do
    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    operations = [
      open_operation(),
      payment("group-81", "pay-flex", 1_000),
      cancel("group-81", "cancel-flex", "2026-11-27"),
      advance,
      payment("advance", "pay-advance", 2_000),
      cancel("advance", "cancel-advance", "2026-10-10")
    ]

    assert [_, _, flex, _, _, advance_result] = post_operations(conn, operations)
    assert flex["retained_cents"] == 1_000
    assert advance_result["retained_cents"] == 2_000

    ledger = conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_retained_cents"] == 3_000
  end

  test "returns endpoint and operation errors in the documented shapes", %{conn: conn} do
    assert conn |> post(~p"/api/v1/partner-batches", %{}) |> json_response(422) ==
             %{"error" => %{"code" => "invalid_batch"}}

    assert conn |> get(~p"/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    invalid = %{"operation_id" => "bad", "type" => "unknown", "occurred_on" => "2026-01-01"}
    malformed_date = Map.put(payment("not-there", "date", 1), "occurred_on", 123)
    missing = Map.put(payment("not-there", "missing", -1), "expected_revision", 99)

    assert [
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"code" => "group_not_found"}
           ] = post_operations(conn, [invalid, malformed_date, missing])
  end

  defp payment(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel(group_id, operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end
end
