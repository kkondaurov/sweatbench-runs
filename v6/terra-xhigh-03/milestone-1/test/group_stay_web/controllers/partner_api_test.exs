defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: true

  describe "POST /api/v1/partner-batches" do
    test "requires an operations array", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_batch"}} =
               conn
               |> post(~p"/api/v1/partner-batches", %{})
               |> json_response(422)
    end

    test "opens a group, calculates each flexible room's rounded deposit, and reads it back", %{
      conn: conn
    } do
      operation =
        open_group("open-rounded", "rounded-group", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3}
          ]
        })

      assert %{"results" => [result]} = batch(conn, [operation]) |> json_response(200)

      assert result == %{
               "operation_id" => "open-rounded",
               "status" => "applied",
               "group_id" => "rounded-group",
               "deposit_due_cents" => 2,
               "revision" => 1
             }

      assert %{"data" => group} =
               conn
               |> get(~p"/api/v1/groups/rounded-group")
               |> json_response(200)

      assert group == %{
               "group_id" => "rounded-group",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-11",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 3},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 3}
               ],
               "lodging_total_cents" => 6,
               "deposit_due_cents" => 2,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 2
             }
    end

    test "uses full lodging as the advance-purchase deposit and ignores expected_revision", %{
      conn: conn
    } do
      operation =
        open_group("open-advance", "advance-group", %{
          "expected_revision" => 99,
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })

      assert %{"results" => [%{"deposit_due_cents" => 45_000, "revision" => 1}]} =
               batch(conn, [operation]) |> json_response(200)
    end

    test "rejects duplicate group identifiers", %{conn: conn} do
      first = open_group("open-first", "duplicate-group")
      duplicate = open_group("open-duplicate", "duplicate-group")

      assert %{"results" => [_, result]} = batch(conn, [first, duplicate]) |> json_response(200)

      assert result == %{
               "operation_id" => "open-duplicate",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "duplicate-group"
             }
    end

    test "validates opening fields without creating a group", %{conn: conn} do
      invalid_stay = open_group("bad-stay", "bad-stay", %{"departure_on" => "2026-12-10"})

      invalid_rooms =
        open_group("bad-rooms", "bad-rooms", %{
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 1_000},
            %{"room_id" => "same", "nightly_rate_cents" => 1_000}
          ]
        })

      invalid_plan = open_group("bad-plan", "bad-plan", %{"rate_plan" => "weekend_magic"})

      assert %{"results" => results} =
               batch(conn, [invalid_stay, invalid_rooms, invalid_plan]) |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_rate_plan"
             ]

      assert %{"error" => %{"code" => "group_not_found"}} =
               conn
               |> get(~p"/api/v1/groups/bad-stay")
               |> json_response(404)
    end

    test "processes a batch in order and continues after a rejected payment", %{conn: conn} do
      group = open_group("open-sequential", "sequential-group", %{"rooms" => [room(10_000)]})

      too_large_payment = %{
        "operation_id" => "pay-too-large",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "sequential-group",
        "amount_cents" => 6_001
      }

      valid_payment = %{
        "operation_id" => "pay-valid",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "sequential-group",
        "amount_cents" => 6_000
      }

      assert %{"results" => [opened, rejected, paid]} =
               batch(conn, [group, too_large_payment, valid_payment]) |> json_response(200)

      assert opened["revision"] == 1

      assert rejected == %{
               "operation_id" => "pay-too-large",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert paid == %{
               "operation_id" => "pay-valid",
               "status" => "applied",
               "group_id" => "sequential-group",
               "amount_cents" => 6_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 6_000}} =
               conn
               |> get(~p"/api/v1/groups/sequential-group")
               |> json_response(200)

      assert ledger(conn) == %{
               "cash_held_cents" => 6_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "reschedules an active group without changing its length or price", %{conn: conn} do
      assert %{"results" => [_]} =
               batch(conn, [open_group("open-move", "move-group")]) |> json_response(200)

      move = %{
        "operation_id" => "move-group",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "move-group",
        "new_arrival_on" => "2026-12-20"
      }

      assert %{"results" => [result]} = batch(conn, [move]) |> json_response(200)

      assert result == %{
               "operation_id" => "move-group",
               "status" => "applied",
               "group_id" => "move-group",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 2
             }

      assert %{"data" => group} =
               conn |> get(~p"/api/v1/groups/move-group") |> json_response(200)

      assert group["lodging_total_cents"] == 30_000
      assert group["deposit_due_cents"] == 6_000

      invalid_move = %{move | "operation_id" => "bad-move", "new_arrival_on" => "2026-10-04"}

      assert %{"results" => [%{"code" => "invalid_stay"}]} =
               batch(conn, [invalid_move]) |> json_response(200)
    end

    test "settles flexible cancellation according to calendar days and removes held cash", %{
      conn: conn
    } do
      assert %{"results" => [_]} =
               batch(conn, [open_group("open-refund", "refund-group")]) |> json_response(200)

      pay = %{
        "operation_id" => "pay-refund",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "refund-group",
        "amount_cents" => 2_000
      }

      cancel = %{
        "operation_id" => "cancel-refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "refund-group"
      }

      assert %{"results" => [_, result]} = batch(conn, [pay, cancel]) |> json_response(200)

      assert result == %{
               "operation_id" => "cancel-refund",
               "status" => "applied",
               "group_id" => "refund-group",
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2_000,
               "cash_retained_cents" => 0
             }

      assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
               conn
               |> get(~p"/api/v1/groups/refund-group")
               |> json_response(200)
    end

    test "retains late flexible and every advance-purchase cancellation payment", %{conn: conn} do
      flexible = open_group("open-late", "late-group")

      advance =
        open_group("open-advance-cancel", "advance-cancel", %{
          "rate_plan" => "advance_purchase",
          "rooms" => [room(20_000)]
        })

      payments = [
        %{
          "operation_id" => "pay-late",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "late-group",
          "amount_cents" => 2_000
        },
        %{
          "operation_id" => "pay-advance",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "advance-cancel",
          "amount_cents" => 60_000
        }
      ]

      cancellations = [
        %{
          "operation_id" => "cancel-late",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "late-group"
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "advance-cancel"
        }
      ]

      assert %{"results" => _} =
               batch(conn, [flexible, advance] ++ payments ++ cancellations) |> json_response(200)

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 62_000
             }
    end

    test "enforces revisions before other domain validation and preserves state on stale writes",
         %{
           conn: conn
         } do
      assert %{"results" => [_]} =
               batch(conn, [open_group("open-revision", "revision-group")]) |> json_response(200)

      fresh_payment = %{
        "operation_id" => "fresh-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "revision-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      }

      stale_invalid_payment = %{
        "operation_id" => "stale-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "not-a-date",
        "group_id" => "revision-group",
        "amount_cents" => -1,
        "expected_revision" => 1
      }

      missing_group = %{
        "operation_id" => "missing-revision",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "does-not-exist",
        "expected_revision" => 999
      }

      assert %{"results" => [_, stale, missing]} =
               batch(conn, [fresh_payment, stale_invalid_payment, missing_group])
               |> json_response(200)

      assert stale == %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "revision-group",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert missing == %{
               "operation_id" => "missing-revision",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "does-not-exist"
             }

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
               conn
               |> get(~p"/api/v1/groups/revision-group")
               |> json_response(200)
    end

    test "rejects later operations on a cancelled group without changing its revision", %{
      conn: conn
    } do
      open = open_group("open-cancelled", "cancelled-group")

      cancel = %{
        "operation_id" => "cancel-once",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "cancelled-group"
      }

      payment = %{
        "operation_id" => "pay-cancelled",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "cancelled-group",
        "amount_cents" => 1
      }

      assert %{"results" => [_, _, rejected]} =
               batch(conn, [open, cancel, payment]) |> json_response(200)

      assert rejected["code"] == "group_not_active"

      assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} =
               conn
               |> get(~p"/api/v1/groups/cancelled-group")
               |> json_response(200)
    end

    test "rejects unknown and unidentifiable operations while preserving later operations", %{
      conn: conn
    } do
      unknown = %{
        "operation_id" => "unknown",
        "type" => "swap_group",
        "occurred_on" => "2026-10-03"
      }

      missing_identifier = %{"operation_id" => "missing-group", "type" => "cancel_group"}
      valid = open_group("open-after-invalid", "after-invalid")

      assert %{"results" => [first, second, third]} =
               batch(conn, [unknown, missing_identifier, valid]) |> json_response(200)

      assert first["code"] == "invalid_operation"
      assert second["code"] == "invalid_operation"
      assert third["status"] == "applied"
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts with zero finance totals", %{conn: conn} do
      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end
  end

  defp batch(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_group(operation_id, group_id, overrides \\ %{}) do
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
        "rooms" => [room(10_000)]
      },
      overrides
    )
  end

  defp room(nightly_rate_cents),
    do: %{"room_id" => "room-a", "nightly_rate_cents" => nightly_rate_cents}
end
