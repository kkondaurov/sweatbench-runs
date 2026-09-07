defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  defp open_group(overrides \\ %{}) do
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
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  describe "opening and reading a group" do
    test "calculates deposits, preserves room order, and exposes the group", %{conn: conn} do
      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             } = submit(conn, [open_group()])

      response =
        conn
        |> get(~p"/api/v1/groups/group-81")
        |> json_response(200)

      assert response == %{
               "data" => %{
                 "group_id" => "group-81",
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
             }
    end

    test "rounds each flexible room separately and charges advance purchases in full", %{
      conn: conn
    } do
      flexible =
        open_group(%{
          "group_id" => "rounding",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "one", "nightly_rate_cents" => 3},
            %{"room_id" => "two", "nightly_rate_cents" => 3}
          ]
        })

      advance =
        open_group(%{
          "operation_id" => "open-2",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase"
        })

      assert %{"results" => [flexible_result, advance_result]} = submit(conn, [flexible, advance])
      assert flexible_result["deposit_due_cents"] == 2
      assert advance_result["deposit_due_cents"] == 97_500
    end

    test "rejects invalid group definitions without leaving partial data", %{conn: conn} do
      operations = [
        open_group(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
        open_group(%{"operation_id" => "bad-plan", "rate_plan" => "mystery"}),
        open_group(%{"operation_id" => "bad-rooms", "rooms" => []}),
        open_group(%{
          "operation_id" => "duplicate-rooms",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        })
      ]

      assert %{"results" => results} = submit(conn, operations)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rate_plan",
               "invalid_rooms",
               "invalid_rooms"
             ]

      assert conn |> get(~p"/api/v1/groups/group-81") |> json_response(404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "enforces unique group identifiers", %{conn: conn} do
      duplicate = open_group(%{"operation_id" => "open-again"})

      assert %{"results" => [first, second]} = submit(conn, [open_group(), duplicate])
      assert first["status"] == "applied"
      assert second == rejected("open-again", "group_already_exists")
    end
  end

  describe "cash and ordered batch processing" do
    test "applies operations in order, continues after rejections, and increments revisions", %{
      conn: conn
    } do
      payment_1 = %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000,
        "expected_revision" => 1
      }

      excessive = %{
        payment_1
        | "operation_id" => "pay-too-much",
          "amount_cents" => 20_000,
          "expected_revision" => 2
      }

      payment_2 = %{
        payment_1
        | "operation_id" => "pay-2",
          "amount_cents" => 2_500,
          "expected_revision" => 2
      }

      assert %{"results" => [opened, paid_1, rejected_payment, paid_2]} =
               submit(conn, [open_group(), payment_1, excessive, payment_2])

      assert opened["revision"] == 1

      assert paid_1 == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      assert rejected_payment ==
               rejected("pay-too-much", "payment_exceeds_outstanding")

      assert paid_2["revision"] == 3
      assert paid_2["outstanding_deposit_cents"] == 12_000

      assert %{"data" => group} =
               conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)

      assert group["deposit_paid_cents"] == 7_500
      assert group["revision"] == 3
    end

    test "rejects non-positive, non-integer, and excessive amounts", %{conn: conn} do
      submit(conn, [open_group()])

      payments =
        Enum.with_index([0, -1, 1.5, "100", 19_501], 1)
        |> Enum.map(fn {amount, index} ->
          %{
            "operation_id" => "pay-#{index}",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => amount
          }
        end)

      assert %{"results" => results} = submit(conn, payments)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_amount",
               "invalid_amount",
               "invalid_amount",
               "invalid_amount",
               "payment_exceeds_outstanding"
             ]

      assert %{"data" => %{"deposit_paid_cents" => 0, "revision" => 1}} =
               conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)
    end
  end

  describe "revisions and rescheduling" do
    test "checks existence first and stale revisions before other domain validation", %{
      conn: conn
    } do
      submit(conn, [open_group()])

      stale = %{
        "operation_id" => "stale",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => -50,
        "expected_revision" => 9
      }

      missing = %{stale | "operation_id" => "missing", "group_id" => "absent"}

      assert %{"results" => [stale_result, missing_result]} = submit(conn, [stale, missing])

      assert stale_result == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      assert missing_result == rejected("missing", "group_not_found")
    end

    test "moves both stay dates without changing price", %{conn: conn} do
      reschedule = %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-02",
        "expected_revision" => 1
      }

      assert %{"results" => [_opened, result]} = submit(conn, [open_group(), reschedule])

      assert result == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-01-02",
               "new_departure_on" => "2027-01-05",
               "revision" => 2
             }

      assert %{
               "data" => %{
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500
               }
             } = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)
    end

    test "requires the new arrival to be after the operation date", %{conn: conn} do
      invalid_move = %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-12-10",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-10"
      }

      assert %{"results" => [_opened, result]} = submit(conn, [open_group(), invalid_move])
      assert result == rejected("move-1", "invalid_stay")
    end
  end

  describe "cancellation and ledger totals" do
    test "refunds timely flexible cancellations and clears held cash", %{conn: conn} do
      payment = payment("pay-1", "group-81", 10_000)
      cancellation = cancellation("cancel-1", "group-81", "2026-11-26")

      assert %{"results" => [_opened, _paid, cancelled]} =
               submit(conn, [open_group(), payment, cancellation])

      assert cancelled["refunded_cents"] == 10_000
      assert cancelled["retained_cents"] == 0
      assert cancelled["revision"] == 3

      assert conn |> get(~p"/api/v1/ledger") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0
               }
             }

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 10_000,
                 "outstanding_deposit_cents" => 0
               }
             } = conn |> get(~p"/api/v1/groups/group-81") |> json_response(200)
    end

    test "retains late flexible and all advance-purchase cash", %{conn: conn} do
      advance =
        open_group(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase"
        })

      operations = [
        open_group(),
        payment("pay-flex", "group-81", 4_000),
        cancellation("cancel-flex", "group-81", "2026-11-27"),
        advance,
        payment("pay-advance", "advance", 8_000),
        cancellation("cancel-advance", "advance", "2026-10-04")
      ]

      assert %{"results" => results} = submit(conn, operations)
      assert Enum.at(results, 2)["retained_cents"] == 4_000
      assert Enum.at(results, 5)["retained_cents"] == 8_000

      assert %{"data" => totals} = conn |> get(~p"/api/v1/ledger") |> json_response(200)

      assert totals == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 12_000
             }
    end

    test "rejects all later mutations of cancelled groups", %{conn: conn} do
      operations = [
        open_group(),
        cancellation("cancel", "group-81", "2026-10-04"),
        payment("pay", "group-81", 1),
        %{
          "operation_id" => "move",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "new_arrival_on" => "2027-01-01"
        },
        cancellation("cancel-again", "group-81", "2026-10-05")
      ]

      assert %{"results" => [_opened, _cancelled | rejected_results]} = submit(conn, operations)
      assert Enum.map(rejected_results, & &1["code"]) == List.duplicate("group_not_active", 3)
    end
  end

  describe "batch validation" do
    test "rejects a body without an operations array", %{conn: conn} do
      assert conn |> post(~p"/api/v1/partner-batches", %{}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }

      assert conn
             |> post(~p"/api/v1/partner-batches", %{"operations" => %{}})
             |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects malformed and unknown operations but continues", %{conn: conn} do
      operations = [
        %{"operation_id" => "unknown", "type" => "dance"},
        %{"operation_id" => "incomplete", "type" => "record_cash_payment"},
        "not-an-object",
        open_group()
      ]

      assert %{"results" => [unknown, incomplete, malformed, opened]} = submit(conn, operations)
      assert unknown == rejected("unknown", "invalid_operation")
      assert incomplete == rejected("incomplete", "invalid_operation")
      assert malformed == rejected(nil, "invalid_operation")
      assert opened["status"] == "applied"
    end
  end

  test "an empty ledger starts at zero", %{conn: conn} do
    assert conn |> get(~p"/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
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

  defp rejected(operation_id, code) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
  end
end
