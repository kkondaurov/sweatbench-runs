defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/v1/partner-batches" do
    test "applies the documented flexible open_group example", %{conn: conn} do
      {conn, result} = one(conn, example_open())

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }

      assert json_response(get(conn, "/api/v1/groups/group-81"), 200) == %{
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
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500
               }
             }
    end

    test "returns identifiers unchanged and keeps room order", %{conn: conn} do
      op =
        open_op("Group-81", %{
          "operation_id" => "op/1001",
          "guest_id" => "Guest-22",
          "property_id" => "AMS-Canal",
          "rooms" => [
            %{"room_id" => "room-c", "nightly_rate_cents" => 1000, "bed" => "king"},
            %{"room_id" => "room-a", "nightly_rate_cents" => 2000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3000}
          ]
        })

      {conn, result} = one(conn, op)
      assert result["operation_id"] == "op/1001"
      assert result["group_id"] == "Group-81"

      rooms = json_response(get(conn, "/api/v1/groups/Group-81"), 200)["data"]["rooms"]

      assert rooms == [
               %{"room_id" => "room-c", "nightly_rate_cents" => 1000},
               %{"room_id" => "room-a", "nightly_rate_cents" => 2000},
               %{"room_id" => "room-b", "nightly_rate_cents" => 3000}
             ]
    end

    test "charges advance purchase the full lodging amount", %{conn: conn} do
      {_conn, result} =
        one(conn, open_op("ap", %{"rate_plan" => "advance_purchase", "rooms" => one_room(3)}))

      assert result["status"] == "applied"
      assert result["deposit_due_cents"] == 9
      assert result["revision"] == 1
    end

    test "rounds each flexible room deposit separately before summing", %{conn: conn} do
      {_conn, result} =
        one(
          conn,
          open_op("round", %{
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "a", "nightly_rate_cents" => 3},
              %{"room_id" => "b", "nightly_rate_cents" => 3}
            ]
          })
        )

      assert result["deposit_due_cents"] == 2
    end

    test "rounds flexible deposit from lodging, not from the nightly rate", %{conn: conn} do
      op =
        open_op("nights", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-12",
          "rooms" => [room(3)]
        })

      {_conn, result} = one(conn, op)
      assert result["deposit_due_cents"] == 1
    end

    test "accepts a one-night stay and a zero nightly rate", %{conn: conn} do
      op =
        open_op("free", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room(0)]
        })

      {conn, result} = one(conn, op)
      assert result["deposit_due_cents"] == 0

      data = group(conn, "free")
      assert data["lodging_total_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0
    end

    test "ignores expected_revision when opening a group", %{conn: conn} do
      {_conn, created} = one(conn, open_op("new", %{"expected_revision" => 9}))
      assert created["status"] == "applied"
      assert created["revision"] == 1

      {_conn, duplicate} =
        one(conn, open_op("new", %{"operation_id" => "again", "expected_revision" => 1}))

      assert duplicate == %{
               "operation_id" => "again",
               "status" => "rejected",
               "code" => "group_already_exists"
             }
    end

    test "rejects invalid stays, rooms, and rate plans without creating a group", %{conn: conn} do
      before = counts()

      ops = [
        open_op("zero", %{"operation_id" => "zero", "departure_on" => "2026-12-10"}),
        open_op("back", %{"operation_id" => "back", "departure_on" => "2026-12-09"}),
        open_op("bad-date", %{"operation_id" => "bad-date", "arrival_on" => "2026-13-40"}),
        open_op("empty", %{"operation_id" => "empty", "rooms" => []}),
        open_op("dup-rooms", %{
          "operation_id" => "dup-rooms",
          "rooms" => [room(100), room(200)]
        }),
        open_op("neg", %{"operation_id" => "neg", "rooms" => [room(-1)]}),
        open_op("plan", %{"operation_id" => "plan", "rate_plan" => "prepaid"}),
        open_op("case", %{"operation_id" => "case", "rate_plan" => "Flexible"})
      ]

      {conn, results} = batch(conn, ops)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_stay",
               "invalid_stay",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rooms",
               "invalid_rate_plan",
               "invalid_rate_plan"
             ]

      assert counts() == before
      assert get(conn, "/api/v1/groups/zero") |> json_response(404)
    end

    test "rejects incomplete or unknown operations and continues", %{conn: conn} do
      ops = [
        %{"type" => "open_group"},
        %{"operation_id" => 12, "type" => "cancel_group", "occurred_on" => "2026-10-03"},
        %{"operation_id" => "bad", "type" => "mystery", "occurred_on" => "2026-10-03"},
        "not-a-map",
        open_op("after-bad", %{"operation_id" => "after"})
      ]

      {_conn, results} = batch(conn, ops)

      assert results == [
               %{
                 "operation_id" => nil,
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => 12,
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "bad",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => nil,
                 "status" => "rejected",
                 "code" => "invalid_operation"
               },
               %{
                 "operation_id" => "after",
                 "status" => "applied",
                 "group_id" => "after-bad",
                 "deposit_due_cents" => 19500,
                 "revision" => 1
               }
             ]
    end

    test "a rejection does not undo earlier operations or stop later ones", %{conn: conn} do
      {conn, results} =
        batch(conn, [
          open_op("keep"),
          open_op("keep", %{"operation_id" => "dup"}),
          open_op("later"),
          %{"type" => "nope", "operation_id" => "bad", "occurred_on" => "2026-10-03"}
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied", "rejected"]
      assert Enum.at(results, 1)["code"] == "group_already_exists"
      assert group(conn, "keep")["revision"] == 1
      assert group(conn, "later")["group_id"] == "later"
    end

    test "records cash against the outstanding deposit", %{conn: conn} do
      {conn, results} =
        batch(conn, [
          open_op("g"),
          payment_op("g", 5000, %{"operation_id" => "p1"}),
          payment_op("g", 14500, %{"operation_id" => "p2"})
        ])

      assert Enum.at(results, 1) == %{
               "operation_id" => "p1",
               "status" => "applied",
               "group_id" => "g",
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14500,
               "revision" => 2
             }

      assert Enum.at(results, 2)["outstanding_deposit_cents"] == 0
      assert Enum.at(results, 2)["revision"] == 3

      data = group(conn, "g")
      assert data["deposit_paid_cents"] == 19500
      assert data["outstanding_deposit_cents"] == 0
      assert data["deposit_due_cents"] == 19500
      assert ledger(conn)["data"]["cash_held_cents"] == 19500
    end

    test "rejects unusable, excessive, missing, and inactive payments", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      before = snapshot(conn, "g")

      {conn, zero} = one(conn, payment_op("g", 0))
      {conn, negative} = one(conn, payment_op("g", -5, %{"operation_id" => "neg"}))
      {conn, huge} = one(conn, payment_op("g", 19501, %{"operation_id" => "huge"}))

      missing_payment =
        Map.delete(payment_op("g", 1, %{"operation_id" => "missing"}), "amount_cents")

      {conn, missing} = one(conn, missing_payment)

      {conn, text} =
        one(conn, payment_op("g", 1, %{"operation_id" => "text", "amount_cents" => "100"}))

      {conn, gone} = one(conn, payment_op("missing-group", 1))

      assert zero["code"] == "invalid_amount"
      assert negative["code"] == "invalid_amount"
      assert huge["code"] == "payment_exceeds_outstanding"
      assert missing["code"] == "invalid_operation"
      assert text["code"] == "invalid_amount"

      assert gone == %{
               "operation_id" => "pay-missing-group-1",
               "status" => "rejected",
               "code" => "group_not_found"
             }

      assert snapshot(conn, "g") == before

      {conn, _} = one(conn, cancel_op("g", %{"occurred_on" => "2026-11-01"}))
      {conn, inactive} = one(conn, payment_op("g", 1, %{"operation_id" => "late"}))
      assert inactive["code"] == "group_not_active"
      assert group(conn, "g")["deposit_paid_cents"] == 0
    end

    test "shifts departure with the arrival and leaves price unchanged", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))

      {conn, result} = one(conn, reschedule_op("g", "2026-12-20"))

      assert result == %{
               "operation_id" => "move-g",
               "status" => "applied",
               "group_id" => "g",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "revision" => 2
             }

      data = group(conn, "g")
      assert data["arrival_on"] == "2026-12-20"
      assert data["departure_on"] == "2026-12-23"
      assert data["booked_on"] == "2026-10-03"
      assert data["lodging_total_cents"] == 97500
      assert data["deposit_due_cents"] == 19500

      assert ledger(conn)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "moves a stay earlier and across a month boundary without changing length", %{conn: conn} do
      {conn, _} =
        one(conn, open_op("g", %{"arrival_on" => "2026-01-30", "departure_on" => "2026-02-02"}))

      {conn, result} =
        one(conn, reschedule_op("g", "2026-02-27", %{"occurred_on" => "2026-01-01"}))

      assert result["new_arrival_on"] == "2026-02-27"
      assert result["new_departure_on"] == "2026-03-02"

      {conn, earlier} =
        one(
          conn,
          reschedule_op("g", "2026-02-01", %{
            "operation_id" => "back",
            "occurred_on" => "2026-01-15"
          })
        )

      assert earlier["new_arrival_on"] == "2026-02-01"
      assert earlier["new_departure_on"] == "2026-02-04"
      assert earlier["revision"] == 3
      assert group(conn, "g")["lodging_total_cents"] == 3 * (15000 + 17500)
    end

    test "rejects unusable reschedule dates and inactive or missing groups", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      before = snapshot(conn, "g")

      {conn, same_day} =
        one(conn, reschedule_op("g", "2026-10-05", %{"operation_id" => "same"}))

      {conn, before_day} =
        one(conn, reschedule_op("g", "2026-10-04", %{"operation_id" => "before"}))

      {conn, bad_date} =
        one(conn, reschedule_op("g", "2026-02-31", %{"operation_id" => "bad"}))

      missing_arrival =
        reschedule_op("g", "2026-12-20")
        |> Map.delete("new_arrival_on")
        |> Map.put("operation_id", "missing")

      {conn, missing_date} = one(conn, missing_arrival)

      {conn, missing_group} = one(conn, reschedule_op("nope", "2026-12-20"))

      assert same_day["code"] == "invalid_stay"
      assert before_day["code"] == "invalid_stay"
      assert bad_date["code"] == "invalid_stay"
      assert missing_date["code"] == "invalid_operation"
      assert missing_group["code"] == "group_not_found"
      assert snapshot(conn, "g") == before

      {conn, _} = one(conn, cancel_op("g"))
      {_conn, inactive} = one(conn, reschedule_op("g", "2026-12-20", %{"operation_id" => "late"}))
      assert inactive["code"] == "group_not_active"
    end

    test "a no-op reschedule still increments revision", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      {conn, result} = one(conn, reschedule_op("g", "2026-12-10"))
      assert result["new_arrival_on"] == "2026-12-10"
      assert result["new_departure_on"] == "2026-12-13"
      assert result["revision"] == 2
      assert group(conn, "g")["revision"] == 2
    end

    test "refunds flexible cash cancelled at least 14 days before arrival", %{conn: conn} do
      arrival = ~D[2026-12-10]
      refund_on = Date.add(arrival, -14) |> Date.to_iso8601()
      retain_on = Date.add(arrival, -13) |> Date.to_iso8601()
      assert Date.diff(arrival, Date.from_iso8601!(refund_on)) == 14

      {conn, _} = one(conn, open_op("early"))
      {conn, _} = one(conn, payment_op("early", 5000))
      {conn, refunded} = one(conn, cancel_op("early", %{"occurred_on" => refund_on}))

      assert refunded == %{
               "operation_id" => "cancel-early",
               "status" => "applied",
               "group_id" => "early",
               "refunded_cents" => 5000,
               "retained_cents" => 0,
               "revision" => 3
             }

      early = group(conn, "early")
      assert early["status"] == "cancelled"
      assert early["deposit_paid_cents"] == 5000
      assert early["deposit_due_cents"] == 19500
      assert early["outstanding_deposit_cents"] == 0

      {conn, _} = one(conn, open_op("late"))
      {conn, _} = one(conn, payment_op("late", 7000))
      {conn, retained} = one(conn, cancel_op("late", %{"occurred_on" => retain_on}))
      assert retained["refunded_cents"] == 0
      assert retained["retained_cents"] == 7000

      {conn, _} = one(conn, open_op("arrival-day"))
      {conn, _} = one(conn, payment_op("arrival-day", 100))

      {_conn, on_arrival} =
        one(
          conn,
          cancel_op("arrival-day", %{"occurred_on" => "2026-12-10", "operation_id" => "arr"})
        )

      assert on_arrival["retained_cents"] == 100
      assert on_arrival["refunded_cents"] == 0
    end

    test "advance purchase cash is always retained", %{conn: conn} do
      {conn, _} =
        one(conn, open_op("ap", %{"rate_plan" => "advance_purchase", "rooms" => one_room(1000)}))

      {conn, _} = one(conn, payment_op("ap", 400))

      {_conn, result} =
        one(conn, cancel_op("ap", %{"occurred_on" => "2026-10-04"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 400
      assert result["revision"] == 3
    end

    test "cancellation releases unpaid deposit and does not invent cash", %{conn: conn} do
      {conn, _} = one(conn, open_op("unpaid"))
      {conn, result} = one(conn, cancel_op("unpaid", %{"occurred_on" => "2026-11-01"}))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert group(conn, "unpaid")["outstanding_deposit_cents"] == 0

      assert ledger(conn)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }

      {conn, again} = one(conn, cancel_op("unpaid", %{"operation_id" => "again"}))
      {conn, pay} = one(conn, payment_op("unpaid", 1, %{"operation_id" => "pay"}))

      {_conn, move} =
        one(conn, reschedule_op("unpaid", "2026-12-20", %{"operation_id" => "move"}))

      assert again["code"] == "group_not_active"
      assert pay["code"] == "group_not_active"
      assert move["code"] == "group_not_active"
      assert group(conn, "unpaid")["revision"] == 2
    end

    test "uses the rescheduled arrival for the refund window", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      {conn, _} = one(conn, payment_op("g", 800))
      {conn, _} = one(conn, reschedule_op("g", "2026-12-20"))

      {_conn, result} = one(conn, cancel_op("g", %{"occurred_on" => "2026-11-27"}))
      assert result["refunded_cents"] == 800
      assert result["retained_cents"] == 0
    end

    test "later operations see earlier batch changes, including revision", %{conn: conn} do
      {conn, results} =
        batch(conn, [
          open_op("g"),
          payment_op("g", 5000, %{"operation_id" => "p1", "expected_revision" => 1}),
          payment_op("g", 1000, %{"operation_id" => "p2", "expected_revision" => 1}),
          payment_op("g", 1000, %{"operation_id" => "p3", "expected_revision" => 2})
        ])

      assert Enum.at(results, 1)["status"] == "applied"
      assert Enum.at(results, 1)["revision"] == 2
      assert Enum.at(results, 1)["outstanding_deposit_cents"] == 14500

      assert Enum.at(results, 2) == %{
               "operation_id" => "p2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "g",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert Enum.at(results, 3)["status"] == "applied"
      assert Enum.at(results, 3)["revision"] == 3
      assert Enum.at(results, 3)["outstanding_deposit_cents"] == 13500
      assert group(conn, "g")["deposit_paid_cents"] == 6000
      assert group(conn, "g")["revision"] == 3
    end

    test "stale revision is rejected before other domain rules and changes nothing", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      {conn, _} = one(conn, payment_op("g", 100))
      before = snapshot(conn, "g")

      {conn, stale_pay} =
        one(conn, payment_op("g", -5, %{"operation_id" => "stale-pay", "expected_revision" => 1}))

      {conn, stale_move} =
        one(
          conn,
          reschedule_op("g", "2026-10-05", %{
            "operation_id" => "stale-move",
            "expected_revision" => 1
          })
        )

      assert stale_pay["code"] == "stale_revision"
      assert stale_pay["expected_revision"] == 1
      assert stale_pay["actual_revision"] == 2
      assert stale_move["code"] == "stale_revision"
      assert snapshot(conn, "g") == before

      {conn, _} = one(conn, cancel_op("g"))
      cancelled = snapshot(conn, "g")

      {conn, stale_cancel} =
        one(conn, cancel_op("g", %{"operation_id" => "stale-cancel", "expected_revision" => 1}))

      assert stale_cancel["code"] == "stale_revision"
      assert stale_cancel["actual_revision"] == 3
      assert snapshot(conn, "g") == cancelled

      {_conn, missing} =
        one(conn, payment_op("absent", 1, %{"expected_revision" => 1, "amount_cents" => -1}))

      assert missing["code"] == "group_not_found"
      assert group(conn, "g")["deposit_paid_cents"] == before.paid
    end

    test "omitted or null expected_revision stays unconditional", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))
      {conn, _} = one(conn, payment_op("g", 100))

      {_conn, paid} =
        one(conn, payment_op("g", 50, %{"operation_id" => "again", "expected_revision" => nil}))

      assert paid["status"] == "applied"
      assert paid["revision"] == 3
    end

    test "duplicate operation ids are not idempotent", %{conn: conn} do
      {conn, _} = one(conn, open_op("g"))

      {conn, results} =
        batch(conn, [
          payment_op("g", 10, %{"operation_id" => "same"}),
          payment_op("g", 10, %{"operation_id" => "same"})
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
      assert group(conn, "g")["deposit_paid_cents"] == 20
      assert group(conn, "g")["revision"] == 3
    end
  end

  describe "batch envelope" do
    test "rejects a body without an operations array", %{conn: conn} do
      assert invalid_batch(conn, %{}) == %{"error" => %{"code" => "invalid_batch"}}

      assert invalid_batch(conn, %{"operations" => nil}) == %{
               "error" => %{"code" => "invalid_batch"}
             }

      assert invalid_batch(conn, %{"operations" => %{}}) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    test "accepts an empty operations array and ignores extra batch fields", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/v1/partner-batches",
          Jason.encode!(%{"operations" => [], "batch_id" => "b1"})
        )

      assert json_response(conn, 200) == %{"results" => []}
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns 404 for a missing group", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/groups/missing"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero and excludes unpaid deposit requirements", %{conn: conn} do
      assert ledger(conn) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }

      {conn, _} = one(conn, open_op("unpaid"))

      assert ledger(conn)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "moves cash from held to refunded or retained and leaves other groups held", %{
      conn: conn
    } do
      {conn, _} = one(conn, open_op("held"))
      {conn, _} = one(conn, payment_op("held", 1000))

      {conn, _} = one(conn, open_op("refund"))
      {conn, _} = one(conn, payment_op("refund", 500))
      {conn, _} = one(conn, cancel_op("refund", %{"occurred_on" => "2026-11-01"}))

      {conn, _} = one(conn, open_op("retain"))
      {conn, _} = one(conn, payment_op("retain", 700))
      {conn, _} = one(conn, cancel_op("retain", %{"occurred_on" => "2026-12-09"}))

      assert ledger(conn) == %{
               "data" => %{
                 "cash_held_cents" => 1000,
                 "cash_refunded_cents" => 500,
                 "cash_retained_cents" => 700
               }
             }
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp invalid_batch(conn, body) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
    |> json_response(422)
  end

  defp batch(conn, operations) do
    conn = post_batch(conn, operations)
    {conn, json_response(conn, 200)["results"]}
  end

  defp one(conn, operation) do
    {conn, [result]} = batch(conn, [operation])
    {conn, result}
  end

  defp group(conn, group_id) do
    json_response(get(conn, "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp ledger(conn) do
    json_response(get(conn, "/api/v1/ledger"), 200)
  end

  defp counts do
    {Repo.aggregate(Group, :count), Repo.aggregate(Room, :count)}
  end

  defp snapshot(conn, group_id) do
    data = group(conn, group_id)

    %{
      revision: data["revision"],
      paid: data["deposit_paid_cents"],
      arrival: data["arrival_on"],
      departure: data["departure_on"],
      status: data["status"],
      ledger: ledger(conn)["data"]
    }
  end

  defp example_open do
    %{
      "operation_id" => "op-1001",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-#{group_id}-#{amount}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reschedule_op(group_id, new_arrival, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "move-#{group_id}",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp room(rate), do: %{"room_id" => "room-a", "nightly_rate_cents" => rate}
  defp one_room(rate), do: [room(rate)]
end
