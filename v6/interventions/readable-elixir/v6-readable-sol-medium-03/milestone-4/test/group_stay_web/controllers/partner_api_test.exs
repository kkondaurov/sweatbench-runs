defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  describe "POST /api/v1/partner-batches" do
    test "opens a group and exposes its calculated deposit and ordered rooms", %{conn: conn} do
      operations = [open_group()]

      assert %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             } = post_json(conn, operations)

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "revision" => 1,
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ]
               }
             } = json_response(conn, 200)
    end

    test "processes operations in order and continues after a rejection", %{conn: conn} do
      operations = [
        open_group(),
        payment("payment-1", 10_000),
        payment("too-much", 20_000),
        payment("payment-2", 9_500, 2)
      ]

      assert %{"results" => results} = post_json(conn, operations)

      assert [
               %{"status" => "applied", "revision" => 1},
               %{
                 "status" => "applied",
                 "amount_cents" => 10_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 2
               },
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{
                 "status" => "applied",
                 "amount_cents" => 9_500,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 3
               }
             ] = Enum.map(results, &Map.drop(&1, ["operation_id", "group_id"]))

      assert %{
               "data" => %{
                 "cash_held_cents" => 19_500,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "checks a revision after existence and before domain validation", %{conn: conn} do
      post_json(conn, [open_group(), payment("payment", 1_000)])

      assert %{
               "results" => [
                 %{
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-1",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 },
                 %{"status" => "rejected", "code" => "group_not_found"}
               ]
             } =
               post_json(build_conn(), [
                 payment("stale", -1, 1),
                 payment("missing", 100, 99) |> Map.put("group_id", "missing")
               ])

      assert get(build_conn(), "/api/v1/groups/group-1")
             |> json_response(200)
             |> get_in(["data", "revision"]) == 2
    end

    test "reschedules without changing price and settles refundable cash", %{conn: conn} do
      post_json(conn, [open_group(), payment("payment", 2_000)])

      assert %{
               "results" => [
                 %{
                   "status" => "applied",
                   "new_arrival_on" => "2026-12-20",
                   "new_departure_on" => "2026-12-23",
                   "revision" => 3
                 },
                 %{
                   "status" => "applied",
                   "refunded_cents" => 2_000,
                   "retained_cents" => 0,
                   "revision" => 4
                 },
                 %{"status" => "rejected", "code" => "group_not_active"}
               ]
             } =
               post_json(build_conn(), [
                 %{
                   "operation_id" => "move",
                   "type" => "reschedule_group",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-1",
                   "new_arrival_on" => "2026-12-20",
                   "expected_revision" => 2
                 },
                 %{
                   "operation_id" => "cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-12-06",
                   "group_id" => "group-1",
                   "expected_revision" => 3
                 },
                 payment("late-payment", 100, 4)
               ])

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 2_000,
                 "cash_retained_cents" => 0
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)

      group =
        get(build_conn(), "/api/v1/groups/group-1") |> json_response(200) |> Map.fetch!("data")

      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      assert group["lodging_total_cents"] == 0
    end

    test "retains late flexible and advance-purchase payments", %{conn: conn} do
      advance =
        open_group("advance-group")
        |> Map.put("rate_plan", "advance_purchase")
        |> Map.put("operation_id", "open-advance")

      post_json(conn, [
        open_group(),
        payment("flex-payment", 1_000),
        cancel("flex-cancel", "2026-11-27", 2),
        advance,
        payment("advance-payment", 5_000) |> Map.put("group_id", "advance-group"),
        cancel("advance-cancel", "2026-10-04", 2) |> Map.put("group_id", "advance-group")
      ])

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 6_000
               }
             } = get(build_conn(), "/api/v1/ledger") |> json_response(200)
    end

    test "rejects invalid groups and malformed operations without partial writes", %{conn: conn} do
      invalid_rooms =
        open_group()
        |> Map.put("rooms", [
          %{"room_id" => "same", "nightly_rate_cents" => 1},
          %{"room_id" => "same", "nightly_rate_cents" => 1}
        ])

      assert %{
               "results" => [
                 %{"code" => "invalid_rooms"},
                 %{"code" => "invalid_operation"},
                 %{"code" => "operation_id_conflict"},
                 %{"status" => "applied"}
               ]
             } =
               post_json(conn, [
                 invalid_rooms,
                 %{"operation_id" => "unknown", "type" => "wat"},
                 open_group(),
                 open_group() |> Map.put("operation_id", "duplicate")
               ])
    end

    test "validates stays and rate plans and rounds each flexible room separately", %{conn: conn} do
      one_night =
        open_group()
        |> Map.put("arrival_on", "2026-12-10")
        |> Map.put("departure_on", "2026-12-11")
        |> Map.put("rooms", [
          %{"room_id" => "small-a", "nightly_rate_cents" => 3},
          %{"room_id" => "small-b", "nightly_rate_cents" => 3}
        ])

      invalid_stay =
        open_group("bad-stay")
        |> Map.put("operation_id", "bad-stay")
        |> Map.put("departure_on", "2026-12-10")

      invalid_rate =
        open_group("bad-rate")
        |> Map.put("operation_id", "bad-rate")
        |> Map.put("rate_plan", "mystery")

      advance =
        one_night
        |> Map.put("operation_id", "advance")
        |> Map.put("group_id", "advance")
        |> Map.put("rate_plan", "advance_purchase")

      assert %{
               "results" => [
                 %{"status" => "applied", "deposit_due_cents" => 2},
                 %{"code" => "invalid_stay"},
                 %{"code" => "invalid_rate_plan"},
                 %{"status" => "applied", "deposit_due_cents" => 6}
               ]
             } = post_json(conn, [one_night, invalid_stay, invalid_rate, advance])
    end

    test "rejects a malformed expected revision without applying the operation", %{conn: conn} do
      post_json(conn, [open_group()])

      assert %{"results" => [%{"code" => "invalid_operation", "status" => "rejected"}]} =
               post_json(build_conn(), [payment("bad-revision", 100, 1.0)])

      assert get(build_conn(), "/api/v1/groups/group-1")
             |> json_response(200)
             |> get_in(["data", "revision"]) == 1
    end

    test "returns invalid_batch only when operations is not an array", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{"operations" => %{}})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      assert post(build_conn(), "/api/v1/partner-batches", %{}) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}

      assert post_json(build_conn(), []) == %{"results" => []}
    end
  end

  test "GET /api/v1/groups/:id returns the documented missing-group error", %{conn: conn} do
    assert get(conn, "/api/v1/groups/not-here") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}
  end

  defp post_json(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp open_group(group_id \\ "group-1") do
    %{
      "operation_id" => "open-1",
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
    }
  end

  defp payment(operation_id, amount, expected_revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
    |> maybe_put_revision(expected_revision)
  end

  defp cancel(operation_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-1",
      "expected_revision" => expected_revision
    }
  end

  defp maybe_put_revision(operation, nil), do: operation

  defp maybe_put_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)
end
