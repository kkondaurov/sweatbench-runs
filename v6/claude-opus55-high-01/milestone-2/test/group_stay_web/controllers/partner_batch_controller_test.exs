defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  describe "batch envelope" do
    test "rejects a body without an operations array", %{conn: conn} do
      for body <- [%{}, %{"operations" => %{}}, %{"operations" => "op-1"}, %{"operations" => nil}] do
        conn = post_json(conn, "/api/v1/partner-batches", body)
        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      end
    end

    test "rejects a top-level JSON array", %{conn: conn} do
      conn = post_json(conn, "/api/v1/partner-batches", [open_group_op()])
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects malformed JSON as an invalid batch", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", ~s({"operations": [))

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
      assert db_snapshot()["groups"] == []
    end

    test "accepts an empty batch" do
      assert submit([]) == []
    end

    test "returns one result per operation in order and continues after rejections" do
      results =
        submit([
          open_group_op(%{"operation_id" => "op-1"}),
          payment_op(%{"operation_id" => "op-2", "amount_cents" => 0}),
          payment_op(%{"operation_id" => "op-3", "amount_cents" => 1000}),
          %{"operation_id" => "op-4", "type" => "teleport_group", "occurred_on" => "2026-10-04"},
          cancel_op(%{"operation_id" => "op-5"})
        ])

      assert Enum.map(results, &{&1["operation_id"], &1["status"]}) == [
               {"op-1", "applied"},
               {"op-2", "rejected"},
               {"op-3", "applied"},
               {"op-4", "rejected"},
               {"op-5", "applied"}
             ]

      assert Enum.map(results, & &1["revision"]) == [1, nil, 2, nil, 3]
    end

    test "a rejection does not undo earlier operations in the batch" do
      [opened, rejected] =
        submit([open_group_op(), open_group_op(%{"operation_id" => "op-dup"})])

      assert opened["status"] == "applied"
      assert rejected["code"] == "group_already_exists"
      assert get_group("group-81")["revision"] == 1
    end
  end

  describe "invalid operations" do
    test "rejects unknown, untyped, and non-object operations" do
      results =
        submit([
          %{
            "operation_id" => "op-1",
            "type" => "refund_everything",
            "occurred_on" => "2026-10-03"
          },
          %{"operation_id" => "op-2", "occurred_on" => "2026-10-03", "group_id" => "group-81"},
          %{"operation_id" => "op-3", "type" => 7, "occurred_on" => "2026-10-03"},
          "open_group",
          nil,
          [open_group_op()]
        ])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1", "op-2", "op-3", nil, nil, nil]
      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
      assert db_snapshot()["groups"] == []
    end

    test "rejects operations missing the data needed to identify or apply them" do
      invalid = [
        Map.delete(open_group_op(), "operation_id"),
        open_group_op(%{"operation_id" => ""}),
        open_group_op(%{"operation_id" => 1001}),
        Map.delete(open_group_op(), "occurred_on"),
        open_group_op(%{"occurred_on" => "2026-13-03"}),
        open_group_op(%{"occurred_on" => 20_261_003}),
        Map.delete(open_group_op(), "group_id"),
        open_group_op(%{"group_id" => ""}),
        open_group_op(%{"group_id" => 81}),
        Map.delete(open_group_op(), "guest_id"),
        Map.delete(open_group_op(), "property_id"),
        Map.delete(open_group_op(), "arrival_on"),
        Map.delete(open_group_op(), "departure_on"),
        Map.delete(open_group_op(), "rate_plan"),
        Map.delete(open_group_op(), "rooms"),
        open_group_op(%{"rooms" => nil})
      ]

      for op <- invalid do
        result = submit_one(op)
        assert result["status"] == "rejected", "expected rejection for #{inspect(op)}"
        assert result["code"] == "invalid_operation", "wrong code for #{inspect(op)}"
        assert result["operation_id"] == op["operation_id"]
      end

      assert db_snapshot()["groups"] == []
    end

    test "rejects group operations missing their group or data" do
      submit_one(open_group_op())
      before = db_snapshot()

      invalid = [
        Map.delete(payment_op(), "group_id"),
        Map.delete(payment_op(), "amount_cents"),
        payment_op(%{"amount_cents" => nil}),
        Map.delete(payment_op(), "occurred_on"),
        Map.delete(reschedule_op(), "group_id"),
        Map.delete(reschedule_op(), "new_arrival_on"),
        Map.delete(cancel_op(), "group_id"),
        cancel_op(%{"group_id" => ["group-81"]}),
        cancel_op(%{"expected_revision" => "1"}),
        cancel_op(%{"expected_revision" => 0}),
        cancel_op(%{"expected_revision" => 1.0})
      ]

      for op <- invalid do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = submit_one(op),
               "expected invalid_operation for #{inspect(op)}"
      end

      assert db_snapshot() == before
    end
  end

  describe "open_group" do
    test "opens the API example with per-room flexible deposits" do
      assert submit_one(open_group_op(%{"operation_id" => "op-1001"})) == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }

      assert get_group("group-81") == %{
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

    test "rounds each flexible room's deposit before summing" do
      # Each room's 20% is 2000.6 cents and rounds to 2001; rounding the 4001.2 total would give 4001.
      result =
        submit_one(
          open_group_op(%{
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "r1", "nightly_rate_cents" => 10_003},
              %{"room_id" => "r2", "nightly_rate_cents" => 10_003}
            ]
          })
        )

      assert result["deposit_due_cents"] == 4002
      assert get_group("group-81")["lodging_total_cents"] == 20_006
    end

    test "rounds a flexible room's deposit down when below the half-cent" do
      result =
        submit_one(
          open_group_op(%{
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_001}]
          })
        )

      assert result["deposit_due_cents"] == 2000
    end

    test "requires the full lodging amount for advance purchase" do
      result = submit_one(open_group_op(%{"rate_plan" => "advance_purchase"}))

      assert result["deposit_due_cents"] == 97_500
      group = get_group("group-81")
      assert group["rate_plan"] == "advance_purchase"
      assert group["outstanding_deposit_cents"] == 97_500
    end

    test "keeps rooms in their original order" do
      rooms =
        for id <- ~w(z-room a-room m-room),
            do: %{"room_id" => id, "nightly_rate_cents" => 10_000}

      submit_one(open_group_op(%{"rooms" => rooms}))

      assert Enum.map(get_group("group-81")["rooms"], & &1["room_id"]) == ~w(z-room a-room m-room)
    end

    test "returns partner identifiers unchanged" do
      submit_one(open_group_op(%{"group_id" => "Grp/81 ü", "guest_id" => "G 22"}))

      group = get_group("Grp/81 ü")
      assert group["group_id"] == "Grp/81 ü"
      assert group["guest_id"] == "G 22"
    end

    test "ignores expected_revision" do
      assert %{"status" => "applied", "revision" => 1} =
               submit_one(open_group_op(%{"expected_revision" => 5}))
    end

    test "rejects a duplicate group identifier without changing the existing group" do
      submit_one(open_group_op())
      before = db_snapshot()

      assert submit_one(
               open_group_op(%{
                 "operation_id" => "op-again",
                 "rate_plan" => "advance_purchase",
                 "guest_id" => "someone-else"
               })
             ) == %{
               "operation_id" => "op-again",
               "status" => "rejected",
               "code" => "group_already_exists"
             }

      assert db_snapshot() == before
    end

    test "rejects stays without at least one night after the booking date" do
      cases = [
        %{"departure_on" => "2026-12-10"},
        %{"departure_on" => "2026-12-09"},
        %{"arrival_on" => "2026-12-32"},
        %{"arrival_on" => "10/12/2026"},
        %{"departure_on" => 3},
        %{"arrival_on" => "2026-10-03", "departure_on" => "2026-10-05"},
        %{"arrival_on" => "2026-10-01", "departure_on" => "2026-10-05"}
      ]

      for overrides <- cases do
        assert %{"status" => "rejected", "code" => "invalid_stay"} =
                 submit_one(open_group_op(overrides)),
               "expected invalid_stay for #{inspect(overrides)}"
      end

      assert db_snapshot()["groups"] == []
    end

    test "rejects unknown rate plans" do
      for plan <- ["nonrefundable", "FLEXIBLE", "", 1] do
        assert %{"status" => "rejected", "code" => "invalid_rate_plan"} =
                 submit_one(open_group_op(%{"rate_plan" => plan}))
      end

      assert db_snapshot()["groups"] == []
    end

    test "rejects unusable rooms" do
      cases = [
        [],
        "room-a",
        %{"room_id" => "room-a", "nightly_rate_cents" => 100},
        [
          %{"room_id" => "a", "nightly_rate_cents" => 100},
          %{"room_id" => "a", "nightly_rate_cents" => 200}
        ],
        [%{"room_id" => "a", "nightly_rate_cents" => 0}],
        [%{"room_id" => "a", "nightly_rate_cents" => -100}],
        [%{"room_id" => "a", "nightly_rate_cents" => 100.5}],
        [%{"room_id" => "a", "nightly_rate_cents" => "100"}],
        [%{"room_id" => "a"}],
        [%{"nightly_rate_cents" => 100}],
        [%{"room_id" => "", "nightly_rate_cents" => 100}],
        [%{"room_id" => 1, "nightly_rate_cents" => 100}],
        ["a"],
        [%{"room_id" => "a", "nightly_rate_cents" => 9_000_000_000_000_000}]
      ]

      for rooms <- cases do
        assert %{"status" => "rejected", "code" => "invalid_rooms"} =
                 submit_one(open_group_op(%{"rooms" => rooms})),
               "expected invalid_rooms for #{inspect(rooms)}"
      end

      assert Enum.all?(db_snapshot(), fn {_table, rows} -> rows == [] end)
    end
  end

  describe "record_cash_payment" do
    setup do
      submit_one(open_group_op())
      :ok
    end

    test "applies cash to the outstanding deposit" do
      assert submit_one(payment_op(%{"operation_id" => "op-pay-1"})) == %{
               "operation_id" => "op-pay-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      group = get_group("group-81")
      assert group["deposit_paid_cents"] == 5000
      assert group["outstanding_deposit_cents"] == 14_500
      assert group["revision"] == 2
      assert get_ledger()["cash_held_cents"] == 5000
    end

    test "accepts payments up to exactly the outstanding deposit" do
      [first, second, third] =
        submit([
          payment_op(%{"amount_cents" => 19_000}),
          payment_op(%{"amount_cents" => 500}),
          payment_op(%{"amount_cents" => 1})
        ])

      assert first["outstanding_deposit_cents"] == 500
      assert second["outstanding_deposit_cents"] == 0
      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} = third
      assert get_group("group-81")["deposit_paid_cents"] == 19_500
    end

    test "rejects a payment above the outstanding deposit" do
      before = db_snapshot()

      assert %{"status" => "rejected", "code" => "payment_exceeds_outstanding"} =
               submit_one(payment_op(%{"amount_cents" => 19_501}))

      assert db_snapshot() == before
    end

    test "rejects amounts that are not usable as a payment" do
      before = db_snapshot()

      for amount <- [0, -100, 50.5, 5000.0, "5000", true, %{"cents" => 5}] do
        assert %{"status" => "rejected", "code" => "invalid_amount"} =
                 submit_one(payment_op(%{"amount_cents" => amount})),
               "expected invalid_amount for #{inspect(amount)}"
      end

      assert db_snapshot() == before
    end

    test "rejects a payment for a missing group" do
      before = db_snapshot()

      assert submit_one(payment_op(%{"group_id" => "group-404", "amount_cents" => -1})) == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found"
             }

      assert db_snapshot() == before
    end

    test "rejects a payment for a cancelled group before checking the amount" do
      submit_one(cancel_op())
      before = db_snapshot()

      for amount <- [100, 0, 1_000_000] do
        assert %{"status" => "rejected", "code" => "group_not_active"} =
                 submit_one(payment_op(%{"amount_cents" => amount}))
      end

      assert db_snapshot() == before
    end
  end

  describe "reschedule_group" do
    setup do
      submit_one(open_group_op())
      :ok
    end

    test "moves the stay without changing its length or price" do
      assert submit_one(reschedule_op(%{"operation_id" => "op-move-1"})) == %{
               "operation_id" => "op-move-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      group = get_group("group-81")
      assert group["arrival_on"] == "2026-12-20"
      assert group["departure_on"] == "2026-12-23"
      assert group["booked_on"] == "2026-10-03"
      assert group["lodging_total_cents"] == 97_500
      assert group["deposit_due_cents"] == 19_500
    end

    test "moves a stay earlier across a month boundary" do
      result = submit_one(reschedule_op(%{"new_arrival_on" => "2026-11-29"}))

      assert result["new_arrival_on"] == "2026-11-29"
      assert result["new_departure_on"] == "2026-12-02"
    end

    test "increments the revision even when the dates do not change" do
      result = submit_one(reschedule_op(%{"new_arrival_on" => "2026-12-10"}))

      assert %{"status" => "applied", "revision" => 2, "new_departure_on" => "2026-12-13"} =
               result

      assert get_group("group-81")["revision"] == 2
    end

    test "requires the new arrival to be after the operation date" do
      before = db_snapshot()

      for date <- ["2026-10-05", "2026-10-04", "2026-02-30", "soon", 20_261_220] do
        assert %{"status" => "rejected", "code" => "invalid_stay"} =
                 submit_one(reschedule_op(%{"new_arrival_on" => date})),
               "expected invalid_stay for #{inspect(date)}"
      end

      assert db_snapshot() == before

      assert %{"status" => "applied", "new_departure_on" => "2026-10-09"} =
               submit_one(reschedule_op(%{"new_arrival_on" => "2026-10-06"}))
    end

    test "rejects missing and inactive groups" do
      assert %{"code" => "group_not_found"} =
               submit_one(reschedule_op(%{"group_id" => "group-404"}))

      submit_one(cancel_op())
      before = db_snapshot()

      assert %{"code" => "group_not_active"} = submit_one(reschedule_op())

      assert %{"code" => "group_not_active"} =
               submit_one(reschedule_op(%{"new_arrival_on" => "not-a-date"}))

      assert db_snapshot() == before
    end
  end

  describe "cancel_group" do
    test "refunds paid cash on a flexible group cancelled 14 days before arrival" do
      submit([open_group_op(), payment_op(%{"amount_cents" => 5000})])

      assert submit_one(cancel_op(%{"operation_id" => "op-c", "occurred_on" => "2026-11-26"})) ==
               %{
                 "operation_id" => "op-c",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 5000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }

      group = get_group("group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0

      assert get_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "retains paid cash on a flexible group cancelled 13 days before arrival" do
      submit([open_group_op(), payment_op(%{"amount_cents" => 5000})])

      assert %{"refunded_cents" => 0, "retained_cents" => 5000, "revision" => 3} =
               submit_one(cancel_op(%{"occurred_on" => "2026-11-27"}))

      assert get_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "retains paid cash on a flexible group cancelled after arrival" do
      submit([open_group_op(), payment_op(%{"amount_cents" => 2500})])

      assert %{"refunded_cents" => 0, "retained_cents" => 2500} =
               submit_one(cancel_op(%{"occurred_on" => "2026-12-11"}))
    end

    test "never refunds advance purchase groups" do
      submit([
        open_group_op(%{"rate_plan" => "advance_purchase"}),
        payment_op(%{"amount_cents" => 97_500})
      ])

      assert %{"refunded_cents" => 0, "retained_cents" => 97_500} =
               submit_one(cancel_op(%{"occurred_on" => "2026-10-04"}))

      assert get_ledger()["cash_retained_cents"] == 97_500
    end

    test "unpaid deposit is no longer due and is not cash" do
      submit_one(open_group_op())

      assert %{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0} =
               submit_one(cancel_op(%{"occurred_on" => "2026-12-01"}))

      group = get_group("group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0

      assert get_ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "uses the rescheduled arrival to decide refundability" do
      submit([open_group_op(), payment_op(%{"amount_cents" => 1000})])

      # Originally 13 days' notice; after moving arrival a week later there are 20 days.
      submit_one(
        reschedule_op(%{"occurred_on" => "2026-11-20", "new_arrival_on" => "2026-12-17"})
      )

      assert %{"refunded_cents" => 1000, "retained_cents" => 0, "revision" => 4} =
               submit_one(cancel_op(%{"occurred_on" => "2026-11-27"}))
    end

    test "rejects every later operation on a cancelled group" do
      submit([open_group_op(), cancel_op()])
      before = db_snapshot()

      results =
        submit([
          payment_op(%{"operation_id" => "p"}),
          reschedule_op(%{"operation_id" => "r"}),
          cancel_op(%{"operation_id" => "c"})
        ])

      assert Enum.map(results, &{&1["operation_id"], &1["code"]}) == [
               {"p", "group_not_active"},
               {"r", "group_not_active"},
               {"c", "group_not_active"}
             ]

      assert db_snapshot() == before
      assert get_group("group-81")["revision"] == 2
    end

    test "rejects a missing group" do
      assert %{"status" => "rejected", "code" => "group_not_found"} = submit_one(cancel_op())
    end
  end

  describe "revisions" do
    setup do
      submit_one(open_group_op())
      :ok
    end

    test "each applied group operation increments the revision once" do
      results =
        submit([
          payment_op(%{"amount_cents" => 100}),
          reschedule_op(),
          payment_op(%{"amount_cents" => 100}),
          cancel_op()
        ])

      assert Enum.map(results, & &1["revision"]) == [2, 3, 4, 5]
      assert get_group("group-81")["revision"] == 5
    end

    test "rejections do not increment the revision" do
      submit([
        payment_op(%{"amount_cents" => 0}),
        payment_op(%{"amount_cents" => 1_000_000}),
        reschedule_op(%{"new_arrival_on" => "2026-01-01"}),
        payment_op(%{"expected_revision" => 9})
      ])

      assert get_group("group-81")["revision"] == 1
    end

    test "applies an operation whose expected revision matches" do
      [pay, move, cancel] =
        submit([
          payment_op(%{"expected_revision" => 1}),
          reschedule_op(%{"expected_revision" => 2}),
          cancel_op(%{"expected_revision" => 3})
        ])

      assert %{"status" => "applied", "revision" => 2} = pay
      assert %{"status" => "applied", "revision" => 3} = move
      assert %{"status" => "applied", "revision" => 4} = cancel
    end

    test "rejects a stale revision with the current revision and leaves everything unchanged" do
      submit_one(payment_op(%{"amount_cents" => 1000}))
      before = db_snapshot()
      ledger = get_ledger()

      for op <- [payment_op(), reschedule_op(), cancel_op()] do
        op = Map.merge(op, %{"operation_id" => "op-1002", "expected_revision" => 1})

        assert submit_one(op) == %{
                 "operation_id" => "op-1002",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
      end

      assert db_snapshot() == before
      assert get_ledger() == ledger
    end

    test "rejects a revision ahead of the group as stale" do
      assert %{"code" => "stale_revision", "expected_revision" => 3, "actual_revision" => 1} =
               submit_one(cancel_op(%{"expected_revision" => 3}))
    end

    test "checks the revision before other domain rules" do
      results =
        submit([
          payment_op(%{"amount_cents" => 0, "expected_revision" => 2}),
          payment_op(%{"amount_cents" => 1_000_000, "expected_revision" => 2}),
          reschedule_op(%{"new_arrival_on" => "2020-01-01", "expected_revision" => 2})
        ])

      assert Enum.all?(results, &(&1["code"] == "stale_revision"))

      submit_one(cancel_op())

      assert %{"code" => "stale_revision", "actual_revision" => 2} =
               submit_one(payment_op(%{"expected_revision" => 1}))
    end

    test "resolves group existence before the revision" do
      assert %{"code" => "group_not_found"} =
               submit_one(payment_op(%{"group_id" => "group-404", "expected_revision" => 1}))

      assert %{"code" => "group_not_found"} =
               submit_one(cancel_op(%{"group_id" => "group-404", "expected_revision" => 7}))
    end

    test "sees revisions produced earlier in the same batch" do
      [_, stale, fresh] =
        submit([
          payment_op(%{"amount_cents" => 100, "expected_revision" => 1}),
          payment_op(%{
            "operation_id" => "late",
            "amount_cents" => 100,
            "expected_revision" => 1
          }),
          payment_op(%{"amount_cents" => 100, "expected_revision" => 2})
        ])

      assert %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2} =
               stale

      assert %{"status" => "applied", "revision" => 3} = fresh
    end

    test "omitting expected_revision applies unconditionally" do
      submit([payment_op(%{"amount_cents" => 100}), payment_op(%{"amount_cents" => 100})])

      assert %{"status" => "applied", "revision" => 4} =
               submit_one(payment_op(%{"amount_cents" => 100, "expected_revision" => nil}))
    end
  end
end
