defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  describe "submit operations" do
    test "opens a group and returns the applied result", %{conn: conn} do
      conn = submit(conn, [open_group()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }
    end

    test "an empty operations array is a syntactically valid batch", %{conn: conn} do
      assert json_response(submit(conn, []), 200) == %{"results" => []}
    end

    test "a body without an operations array is an invalid batch", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => "nope"})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "operations are processed in order and see earlier changes", %{conn: conn} do
      operations = [
        open_group(),
        payment(%{"operation_id" => "op-pay-1", "amount_cents" => 10_000}),
        payment(%{"operation_id" => "op-pay-2", "amount_cents" => 9_500})
      ]

      assert json_response(submit(conn, operations), 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 },
                 %{
                   "operation_id" => "op-pay-1",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_500,
                   "revision" => 2
                 },
                 %{
                   "operation_id" => "op-pay-2",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 9_500,
                   "outstanding_deposit_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert json_response(get(conn, groups_path("group-81")), 200) ==
               %{
                 "data" => %{
                   "group_id" => "group-81",
                   "guest_id" => "guest-22",
                   "property_id" => "ams-canal",
                   "revision" => 3,
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
                   "deposit_paid_cents" => 19_500,
                   "outstanding_deposit_cents" => 0
                 }
               }
    end

    test "a rejected operation does not undo earlier successes or stop later ones", %{conn: conn} do
      operations = [
        open_group(),
        payment(%{"operation_id" => "pay-too-much", "amount_cents" => 99_999}),
        payment(%{"operation_id" => "pay-ok", "amount_cents" => 5_000})
      ]

      assert [
               %{"operation_id" => "op-open", "status" => "applied"},
               %{
                 "operation_id" => "pay-too-much",
                 "status" => "rejected",
                 "code" => "payment_exceeds_outstanding"
               },
               %{
                 "operation_id" => "pay-ok",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ] = json_response(submit(conn, operations), 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 2, "deposit_paid_cents" => 5_000} = data
    end

    test "unknown operation types are rejected with invalid_operation", %{conn: conn} do
      operations = [
        open_group(),
        %{
          "operation_id" => "op-mystery",
          "type" => "teleport_group",
          "occurred_on" => "2026-11-01"
        },
        payment(%{"operation_id" => "op-pay", "amount_cents" => 5_000})
      ]

      assert [
               %{"operation_id" => "op-open", "status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-mystery",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{"operation_id" => "op-pay", "status" => "applied", "revision" => 2}
             ] = json_response(submit(conn, operations), 200)["results"]
    end

    test "an operation missing its type or data to identify it is invalid_operation", %{
      conn: conn
    } do
      open_group!(conn)

      operations = [
        %{"operation_id" => "no-type", "occurred_on" => "2026-11-01"},
        payment(%{"group_id" => 123}),
        Map.delete(payment(), "group_id"),
        "not-an-operation"
      ]

      results = json_response(submit(conn, operations), 200)["results"]

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end

      assert Enum.at(results, 3)["operation_id"] == nil
      assert Enum.at(results, 0)["operation_id"] == "no-type"
    end
  end

  describe "open_group" do
    test "computes the flexible deposit by rounding each room separately", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 19_111},
        %{"room_id" => "room-b", "nightly_rate_cents" => 23_111}
      ]

      # room-a: 57_333 * 20% = 11_466.6 -> 11_467
      # room-b: 69_333 * 20% = 13_866.6 -> 13_867
      # Per-room rounding yields 25_334; rounding after summing yields 25_333.
      conn = submit(conn, [open_group(%{"rooms" => rooms})])

      assert [%{"status" => "applied", "deposit_due_cents" => 25_334}] =
               json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["lodging_total_cents"] == 126_666
      assert data["deposit_due_cents"] == 25_334
    end

    test "an advance purchase deposit is the full lodging amount", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "op-advance",
            "group_id" => "group-advance",
            "rate_plan" => "advance_purchase"
          })
        ])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-advance",
                   "status" => "applied",
                   "group_id" => "group-advance",
                   "deposit_due_cents" => 97_500,
                   "revision" => 1
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-advance")), 200)["data"]

      assert %{
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 97_500,
               "outstanding_deposit_cents" => 97_500
             } = data
    end

    test "the occurred_on date is the group's booked_on date", %{conn: conn} do
      submit(conn, [open_group(%{"occurred_on" => "2026-09-01"})])
      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["booked_on"] == "2026-09-01"
    end

    test "a one-night, one-room stay is valid", %{conn: conn} do
      op =
        open_group(%{
          "operation_id" => "op-min",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "solo", "nightly_rate_cents" => 20_000}]
        })

      assert [%{"status" => "applied", "deposit_due_cents" => 4_000}] =
               json_response(submit(conn, [op]), 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"lodging_total_cents" => 20_000, "deposit_due_cents" => 4_000} = data
    end

    test "the group identifier is returned unchanged and used for reads", %{conn: conn} do
      group_id = "group-42-x"

      conn = submit(conn, [open_group(%{"operation_id" => "op-x", "group_id" => group_id})])

      assert [%{"group_id" => ^group_id}] = json_response(conn, 200)["results"]
      assert json_response(get(conn, groups_path(group_id)), 200)["data"]["group_id"] == group_id
    end

    test "opening an existing group is rejected with group_already_exists", %{conn: conn} do
      open_group!(conn)

      conn = submit(conn, [open_group(%{"operation_id" => "op-dup"})])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-dup",
                   "status" => "rejected",
                   "code" => "group_already_exists"
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert data["revision"] == 1
      assert data["deposit_due_cents"] == 19_500
    end

    test "open_group does not use expected_revision", %{conn: conn} do
      conn = submit(conn, [open_group(%{"expected_revision" => 42})])

      assert [%{"status" => "applied", "revision" => 1}] = json_response(conn, 200)["results"]
    end

    test "a stay with no nights is invalid", %{conn: conn} do
      for op <- [
            open_group(%{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-13"}),
            open_group(%{"arrival_on" => "2026-12-14", "departure_on" => "2026-12-13"}),
            open_group(%{"arrival_on" => "sometime"})
          ] do
        [result] = json_response(submit(conn, [op]), 200)["results"]
        assert result["code"] == "invalid_stay"
      end

      assert json_response(get(conn, groups_path("group-81")), 404)
    end

    test "a stay missing its dates has no data to apply", %{conn: conn} do
      for op <- [
            Map.delete(open_group(), "arrival_on"),
            Map.delete(open_group(), "departure_on")
          ] do
        [result] = json_response(submit(conn, [op]), 200)["results"]
        assert result["code"] == "invalid_operation"
      end

      assert json_response(get(conn, groups_path("group-81")), 404)
    end

    test "unusable rooms are rejected without creating a group", %{conn: conn} do
      bad_rooms = [
        [],
        [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 11_000}
        ],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 0}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => -100}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 10.5}],
        [%{"room_id" => "room-a"}],
        [%{"room_id" => 7, "nightly_rate_cents" => 100}],
        [%{"nightly_rate_cents" => 100}]
      ]

      Enum.with_index(bad_rooms, fn rooms, index ->
        op = open_group(%{"operation_id" => "op-#{index}", "rooms" => rooms})
        [result] = json_response(submit(conn, [op]), 200)["results"]
        assert result["code"] == "invalid_rooms"
      end)

      assert json_response(get(conn, groups_path("group-81")), 404)
    end

    test "rooms that are not a list or are missing are rejected", %{conn: conn} do
      conn = submit(conn, [open_group(%{"rooms" => "not-a-list"})])
      assert [%{"code" => "invalid_rooms"}] = json_response(conn, 200)["results"]

      conn = submit(conn, [Map.delete(open_group(), "rooms")])
      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]
    end

    test "an unknown rate plan is rejected with invalid_rate_plan", %{conn: conn} do
      conn = submit(conn, [open_group(%{"rate_plan" => "refundable"})])
      assert [%{"code" => "invalid_rate_plan"}] = json_response(conn, 200)["results"]

      conn = submit(conn, [Map.delete(open_group(), "rate_plan")])
      assert [%{"code" => "invalid_operation"}] = json_response(conn, 200)["results"]
    end

    test "identity fields must be present and usable", %{conn: conn} do
      for op <- [
            Map.delete(open_group(), "group_id"),
            open_group(%{"group_id" => 81}),
            Map.delete(open_group(), "guest_id"),
            Map.delete(open_group(), "property_id")
          ] do
        [result] = json_response(submit(conn, [op]), 200)["results"]
        assert result["code"] == "invalid_operation"
      end

      assert json_response(get(conn, groups_path("group-81")), 404)
    end

    test "room order is preserved in reads", %{conn: conn} do
      rooms = [
        %{"room_id" => "zulu", "nightly_rate_cents" => 10_000},
        %{"room_id" => "alpha", "nightly_rate_cents" => 12_000},
        %{"room_id" => "mike", "nightly_rate_cents" => 14_000}
      ]

      submit(conn, [open_group(%{"rooms" => rooms})])

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert Enum.map(data["rooms"], & &1["room_id"]) == ~w(zulu alpha mike)
    end
  end

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, payment(%{"amount_cents" => 10_000}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "amount_cents" => 10_000,
                   "outstanding_deposit_cents" => 9_500,
                   "revision" => 2
                 }
               ]
             }
    end

    test "a payment over the outstanding deposit is rejected and changes nothing", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, payment(%{"amount_cents" => 20_000}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "payment_exceeds_outstanding"
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]

      assert %{"revision" => 1, "deposit_paid_cents" => 0, "outstanding_deposit_cents" => 19_500} =
               data
    end

    test "an unusable amount is rejected with invalid_amount", %{conn: conn} do
      open_group!(conn)

      for amount <- [0, -1, 10.5, "1000", 0.0] do
        op = payment(%{"operation_id" => "pay-#{inspect(amount)}", "amount_cents" => amount})
        [result] = json_response(submit(conn, [op]), 200)["results"]
        assert result["code"] == "invalid_amount"
      end

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = data
    end

    test "a payment operation missing its amount has no data to apply", %{conn: conn} do
      open_group!(conn)

      op = Map.delete(payment(), "amount_cents")

      assert [%{"code" => "invalid_operation"}] =
               json_response(submit(conn, [op]), 200)["results"]
    end

    test "paying a group that does not exist is group_not_found", %{conn: conn} do
      conn = json_post(conn, payment(%{"group_id" => "ghost-group"}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "group_not_found"
                 }
               ]
             }
    end

    test "paying an inactive group is group_not_active", %{conn: conn} do
      open_group!(conn)
      json_post(conn, cancel())

      conn = json_post(conn, payment(%{"amount_cents" => 1_000}))

      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end

    test "occurred_on is not used by payments", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, Map.delete(payment(%{"amount_cents" => 5_000}), "occurred_on"))

      assert [%{"status" => "applied", "amount_cents" => 5_000}] =
               json_response(conn, 200)["results"]
    end
  end

  describe "expected_revision" do
    test "an operation with a matching expected_revision is applied", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, payment(%{"expected_revision" => 1, "amount_cents" => 5_000}))
      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]
    end

    test "a stale expected_revision is rejected with the prescribed fields", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 5_000}))

      conn = json_post(conn, payment(%{"expected_revision" => 1, "amount_cents" => 5_000}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-pay",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-81",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 2, "deposit_paid_cents" => 5_000} = data
    end

    test "the same payment can be retried without expected_revision", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 5_000}))
      json_post(conn, payment(%{"expected_revision" => 1, "amount_cents" => 9_000}))

      conn = json_post(conn, payment(%{"amount_cents" => 9_000}))

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 5_500, "revision" => 3}] =
               json_response(conn, 200)["results"]
    end

    test "group existence is resolved before revisions", %{conn: conn} do
      conn = json_post(conn, payment(%{"group_id" => "ghost", "expected_revision" => 1}))
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]
    end

    test "a stale revision wins over other domain failures", %{conn: conn} do
      open_group!(conn)
      json_post(conn, cancel())

      conn =
        json_post(conn, payment(%{"expected_revision" => 1, "amount_cents" => 99_999}))

      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               json_response(conn, 200)["results"]
    end

    test "rejections never increment the revision", %{conn: conn} do
      open_group!(conn)

      for op <- [
            payment(%{"amount_cents" => 999_999}),
            payment(%{"amount_cents" => -5}),
            payment(%{"expected_revision" => 7, "amount_cents" => 100})
          ] do
        json_post(conn, op)
      end

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"revision" => 1, "deposit_paid_cents" => 0} = data
    end
  end
end
