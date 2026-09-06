defmodule GroupStayWeb.GroupStayControllerTest do
  use GroupStayWeb.ConnCase, async: false

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})
    end

    test "opens a group and exposes its rooms and calculated totals", %{conn: conn} do
      result = submit(conn, [open_operation()]) |> only_result()

      assert result == %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-1",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      conn = get(conn, "/api/v1/groups/group-1")

      assert %{"data" => group} = json_response(conn, 200)

      assert group == %{
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
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
    end

    test "processes a mixed batch in order and applies revision checks before domain rules", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation("pay-1", 10_000, 1),
        payment_operation("stale", -1, 1),
        payment_operation("too-much", 10_000, 2),
        payment_operation("pay-2", 9_500, 2),
        %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-1",
          "new_arrival_on" => "2026-12-15",
          "expected_revision" => 3
        }
      ]

      assert %{"results" => results} = submit(conn, operations)

      assert Enum.at(results, 1) == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9_500,
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

      assert Enum.at(results, 3) == %{
               "operation_id" => "too-much",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert Enum.at(results, 4)["revision"] == 3

      assert Enum.at(results, 5) == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2026-12-15",
               "new_departure_on" => "2026-12-18",
               "revision" => 4
             }

      conn = get(conn, "/api/v1/groups/group-1")
      group = json_response(conn, 200)["data"]
      assert group["deposit_paid_cents"] == 19_500
      assert group["outstanding_deposit_cents"] == 0
      assert group["revision"] == 4
    end

    test "rejects invalid operations independently and leaves prior state intact", %{conn: conn} do
      invalid_open =
        put_in(open_operation()["rooms"], [
          %{"room_id" => "same", "nightly_rate_cents" => 100},
          %{"room_id" => "same", "nightly_rate_cents" => 200}
        ])

      operations = [
        invalid_open,
        %{"operation_id" => "unknown", "type" => "summon_goblin", "occurred_on" => "2026-10-03"},
        open_operation(),
        open_operation("duplicate"),
        payment_operation("bad-payment", 0),
        payment_operation("good-payment", 500)
      ]

      assert %{"results" => results} = submit(conn, operations)

      assert Enum.map(results, &{&1["operation_id"], &1["status"], &1["code"]}) == [
               {"open-1", "rejected", "invalid_rooms"},
               {"unknown", "rejected", "invalid_operation"},
               {"open-1", "applied", nil},
               {"duplicate", "rejected", "group_already_exists"},
               {"bad-payment", "rejected", "invalid_amount"},
               {"good-payment", "applied", nil}
             ]

      conn = get(conn, "/api/v1/groups/group-1")
      group = json_response(conn, 200)["data"]
      assert group["deposit_paid_cents"] == 500
      assert group["revision"] == 2
      assert length(group["rooms"]) == 2
    end

    test "validates opening and rescheduling domain data", %{conn: conn} do
      invalid_stay = %{open_operation("stay") | "departure_on" => "2026-12-10"}
      invalid_plan = %{open_operation("plan") | "rate_plan" => "mystery"}
      invalid_rooms = %{open_operation("rooms") | "rooms" => []}

      move_to_operation_day = %{
        "operation_id" => "bad-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-1",
        "new_arrival_on" => "2026-10-05"
      }

      assert %{"results" => results} =
               submit(conn, [
                 invalid_stay,
                 invalid_plan,
                 invalid_rooms,
                 open_operation(),
                 move_to_operation_day
               ])

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rate_plan",
               "invalid_rooms",
               nil,
               "invalid_stay"
             ]

      conn = get(conn, "/api/v1/groups/missing")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "rounds each flexible room separately", %{conn: conn} do
      operation =
        open_operation()
        |> Map.put("arrival_on", "2026-12-10")
        |> Map.put("departure_on", "2026-12-11")
        |> Map.put("rooms", [
          %{"room_id" => "small-a", "nightly_rate_cents" => 2},
          %{"room_id" => "small-b", "nightly_rate_cents" => 2},
          %{"room_id" => "complimentary", "nightly_rate_cents" => 0}
        ])

      result = only_result(submit(conn, [operation]))
      assert result["deposit_due_cents"] == 0

      conn = get(conn, "/api/v1/groups/group-1")
      assert json_response(conn, 200)["data"]["lodging_total_cents"] == 4
    end

    test "resolves existence and revision before other operation validation", %{conn: conn} do
      submit(conn, [open_operation(), payment_operation("pay", 100)])

      stale_with_bad_date = %{
        "operation_id" => "stale",
        "type" => "cancel_group",
        "occurred_on" => "not-a-date",
        "group_id" => "group-1",
        "expected_revision" => 1
      }

      missing_with_bad_date = %{
        stale_with_bad_date
        | "operation_id" => "missing",
          "group_id" => "absent"
      }

      assert %{"results" => [stale, missing]} =
               submit(conn, [stale_with_bad_date, missing_with_bad_date])

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2
      assert missing["code"] == "group_not_found"
    end
  end

  describe "cancellation and GET /api/v1/ledger" do
    test "starts with zero finance totals", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "refunds early flexible cash and clears outstanding deposit", %{conn: conn} do
      submit(conn, [open_operation(), payment_operation("pay", 10_000)])

      cancel = %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-1",
        "expected_revision" => 2
      }

      assert only_result(submit(conn, [cancel])) == %{
               "operation_id" => "cancel",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 10_000,
               "retained_cents" => 0,
               "revision" => 3
             }

      assert only_result(submit(conn, [payment_operation("late-payment", 1)]))["code"] ==
               "group_not_active"

      conn = get(conn, "/api/v1/groups/group-1")
      group = json_response(conn, 200)["data"]
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      assert group["revision"] == 3

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 10_000,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "retains late flexible and all advance-purchase cash", %{conn: conn} do
      flexible = open_operation() |> Map.put("group_id", "flex")

      advance =
        open_operation("open-advance")
        |> Map.put("group_id", "advance")
        |> Map.put("rate_plan", "advance_purchase")

      operations = [
        flexible,
        %{payment_operation("pay-flex", 1_000) | "group_id" => "flex"},
        advance,
        %{payment_operation("pay-advance", 2_000) | "group_id" => "advance"},
        cancel_operation("cancel-flex", "flex", "2026-11-27"),
        cancel_operation("cancel-advance", "advance", "2026-10-04")
      ]

      assert %{"results" => results} = submit(conn, operations)
      assert Enum.at(results, 4)["retained_cents"] == 1_000
      assert Enum.at(results, 5)["retained_cents"] == 2_000

      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3_000
             }
    end
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(%{"results" => [result]}), do: result

  defp open_operation(operation_id \\ "open-1") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-1",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp payment_operation(operation_id, amount, expected_revision \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }

    if is_nil(expected_revision),
      do: operation,
      else: Map.put(operation, "expected_revision", expected_revision)
  end

  defp cancel_operation(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end
end
