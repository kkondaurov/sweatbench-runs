defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "opens a group and exposes its calculated deposit", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/v1/partner-batches", %{operations: [open_operation()]})
        |> json_response(200)

      assert response == %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      group =
        build_conn()
        |> get(~p"/api/v1/groups/group-81")
        |> json_response(200)
        |> get_in(["data"])

      assert group == %{
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

    test "rounds each flexible room separately", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "tiny-a", "nightly_rate_cents" => 3},
            %{"room_id" => "tiny-b", "nightly_rate_cents" => 3}
          ]
        })

      assert %{"results" => [%{"deposit_due_cents" => 2}]} =
               conn
               |> post(~p"/api/v1/partner-batches", %{operations: [operation]})
               |> json_response(200)
    end

    test "allows a complimentary room represented by a zero-cent rate", %{conn: conn} do
      operation =
        open_operation(%{
          "rooms" => [%{"room_id" => "comp-room", "nightly_rate_cents" => 0}]
        })

      assert %{"results" => [%{"status" => "applied", "deposit_due_cents" => 0}]} =
               conn
               |> post(~p"/api/v1/partner-batches", %{operations: [operation]})
               |> json_response(200)
    end

    test "processes operations in order and isolates rejected operations", %{conn: conn} do
      payment = payment_operation("pay-1", 10_000, 1)
      excessive_payment = payment_operation("pay-2", 20_000, 2)
      final_payment = payment_operation("pay-3", 9_500, 2)

      response =
        conn
        |> post(~p"/api/v1/partner-batches", %{
          operations: [open_operation(), payment, excessive_payment, final_payment]
        })
        |> json_response(200)

      assert response["results"] == [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               },
               %{
                 "operation_id" => "pay-2",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "pay-3",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 9_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             ]
    end

    test "checks an existing group's revision before other domain validation", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay-1", 1_000, 1),
        payment_operation("stale", -1, 1),
        payment_operation("missing", 100, 99, "unknown-group")
      ]

      results =
        conn
        |> post(~p"/api/v1/partner-batches", %{operations: operations})
        |> json_response(200)
        |> Map.fetch!("results")

      assert Enum.at(results, 2) == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert List.last(results) == %{
               "operation_id" => "missing",
               "status" => "rejected",
               "code" => "group_not_found"
             }
    end

    test "reschedules by preserving stay length and increments the revision", %{conn: conn} do
      move = %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-01-02",
        "expected_revision" => 1
      }

      assert %{"results" => [_, result]} =
               conn
               |> post(~p"/api/v1/partner-batches", %{operations: [open_operation(), move]})
               |> json_response(200)

      assert result == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-01-02",
               "new_departure_on" => "2027-01-05",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-19",
               "revision" => 2
             }
    end

    test "cancels a flexible group at the refundable boundary", %{conn: conn} do
      cancellation = %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "expected_revision" => 2
      }

      operations = [open_operation(), payment_operation("pay-1", 10_000, 1), cancellation]

      assert %{"results" => [_, _, result]} =
               conn
               |> post(~p"/api/v1/partner-batches", %{operations: operations})
               |> json_response(200)

      assert result == %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0
               }
             } =
               build_conn()
               |> get(~p"/api/v1/ledger")
               |> json_response(200)

      assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
               build_conn()
               |> get(~p"/api/v1/groups/group-81")
               |> json_response(200)
    end

    test "retains advance-purchase cash and rejects later changes", %{conn: conn} do
      opening = open_operation(%{"rate_plan" => "advance_purchase"})

      cancellation = %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      }

      second_cancellation = Map.put(cancellation, "operation_id", "cancel-2")
      payment = payment_operation("pay-1", 20_000, nil) |> Map.delete("expected_revision")

      assert %{"results" => [_, _, cancellation_result, inactive_result]} =
               conn
               |> post(~p"/api/v1/partner-batches", %{
                 operations: [opening, payment, cancellation, second_cancellation]
               })
               |> json_response(200)

      assert cancellation_result["refunded_cents"] == 0
      assert cancellation_result["retained_cents"] == 20_000
      assert inactive_result["code"] == "group_not_active"

      assert %{"data" => %{"cash_retained_cents" => 20_000, "cash_held_cents" => 0}} =
               build_conn()
               |> get(~p"/api/v1/ledger")
               |> json_response(200)
    end

    test "returns stable validation failures and continues", %{conn: conn} do
      invalid_stay =
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"})

      duplicate_rooms = open_operation(%{"operation_id" => "bad-rooms"})
      [room | _] = duplicate_rooms["rooms"]
      duplicate_rooms = Map.put(duplicate_rooms, "rooms", [room, room])

      unknown = %{
        "operation_id" => "unknown",
        "type" => "surprise",
        "occurred_on" => "2026-01-01"
      }

      assert %{"results" => results} =
               conn
               |> post(~p"/api/v1/partner-batches", %{
                 operations: [invalid_stay, duplicate_rooms, unknown, open_operation()]
               })
               |> json_response(200)

      assert Enum.map(results, &Map.get(&1, "code")) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_operation",
               nil
             ]
    end

    test "rejects malformed operations without raising or persisting partial data", %{conn: conn} do
      malformed_rooms = open_operation(%{"rooms" => ["not-a-room"]})

      missing_rooms =
        open_operation() |> Map.delete("rooms") |> Map.put("operation_id", "missing")

      bad_amount = payment_operation("bad-pay", 0, 1)

      assert %{"results" => results} =
               conn
               |> post(~p"/api/v1/partner-batches", %{
                 operations: [malformed_rooms, missing_rooms, bad_amount]
               })
               |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_rooms",
               "invalid_operation",
               "group_not_found"
             ]

      assert build_conn() |> get(~p"/api/v1/groups/group-81") |> response(404)
    end

    test "late flexible cancellation retains paid cash", %{conn: conn} do
      cancellation = %{
        "operation_id" => "cancel-late",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81"
      }

      assert %{"results" => [_, _, result]} =
               conn
               |> post(~p"/api/v1/partner-batches", %{
                 operations: [
                   open_operation(),
                   payment_operation("pay-1", 1_500, 1),
                   cancellation
                 ]
               })
               |> json_response(200)

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 1_500
    end

    test "uses the documented domain error codes", %{conn: conn} do
      empty_rooms = open_operation(%{"operation_id" => "rooms", "rooms" => []})

      invalid_rate =
        open_operation(%{"operation_id" => "rate", "rate_plan" => "mystery"})

      invalid_move = %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-11-01"
      }

      zero_payment = payment_operation("zero", 0, nil) |> Map.delete("expected_revision")
      duplicate = open_operation(%{"operation_id" => "duplicate"})

      assert %{"results" => results} =
               conn
               |> post(~p"/api/v1/partner-batches", %{
                 operations: [
                   empty_rooms,
                   invalid_rate,
                   open_operation(),
                   zero_payment,
                   invalid_move,
                   duplicate
                 ]
               })
               |> json_response(200)

      assert Enum.map(results, &Map.get(&1, "code")) == [
               "invalid_rooms",
               "invalid_rate_plan",
               nil,
               "invalid_amount",
               "invalid_stay",
               "group_already_exists"
             ]
    end
  end

  describe "batch and read errors" do
    test "rejects a body without an operation array", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_batch"}} =
               conn
               |> post(~p"/api/v1/partner-batches", %{})
               |> json_response(422)
    end

    test "returns an empty ledger and a stable missing-group error", %{conn: conn} do
      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = conn |> get(~p"/api/v1/ledger") |> json_response(200)

      assert %{"error" => %{"code" => "group_not_found"}} =
               build_conn()
               |> get(~p"/api/v1/groups/missing")
               |> json_response(404)
    end
  end

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

  defp payment_operation(operation_id, amount, expected_revision, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end
end
