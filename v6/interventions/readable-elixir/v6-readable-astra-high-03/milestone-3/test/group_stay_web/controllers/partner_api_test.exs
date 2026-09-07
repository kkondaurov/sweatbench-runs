defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  test "opens, reads, funds and moves a group in array order", %{conn: conn} do
    results =
      batch(conn, [
        open_group(%{"expected_revision" => 99, "operation_id" => "open-1"}),
        operation("record_cash_payment", %{
          "amount_cents" => 5_000,
          "expected_revision" => 1,
          "operation_id" => "record_cash_payment-1"
        }),
        operation("reschedule_group", %{
          "operation_id" => "reschedule_group-1",
          "new_arrival_on" => "2027-01-30",
          "expected_revision" => 2
        })
      ])

    assert results == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             },
             %{
               "operation_id" => "record_cash_payment-1",
               "status" => "applied",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             },
             %{
               "operation_id" => "reschedule_group-1",
               "status" => "applied",
               "group_id" => "group-81",
               "new_arrival_on" => "2027-01-30",
               "new_departure_on" => "2027-02-02",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-16",
               "revision" => 3
             }
           ]

    assert read_group(conn) == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "revision" => 3,
             "booked_on" => "2026-10-03",
             "arrival_on" => "2027-01-30",
             "departure_on" => "2027-02-02",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2027-01-16",
             "status" => "active",
             "rooms" => open_group()["rooms"],
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 5_000,
             "cash_paid_cents" => 5_000,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 14_500
           }

    assert ledger(conn) == cash(5_000, 0, 0)
  end

  test "rounds flexible deposits per room and charges full advance purchase lodging", %{
    conn: conn
  } do
    rooms = [
      %{"room_id" => "one", "nightly_rate_cents" => 3},
      %{"room_id" => "two", "nightly_rate_cents" => 3},
      %{"room_id" => "three", "nightly_rate_cents" => 2}
    ]

    assert [%{"deposit_due_cents" => 2}, %{"deposit_due_cents" => 8}] =
             batch(conn, [
               open_group(%{"departure_on" => "2026-12-11", "rooms" => rooms}),
               open_group(%{
                 "group_id" => "advance",
                 "rate_plan" => "advance_purchase",
                 "departure_on" => "2026-12-11",
                 "rooms" => rooms
               })
             ])

    assert ledger(conn) == cash(0, 0, 0)
  end

  test "preserves partner identifiers exactly", %{conn: conn} do
    identifiers = %{
      "operation_id" => " Op-Ä ",
      "group_id" => " Group-Ä ",
      "guest_id" => " Guest-Ä ",
      "property_id" => " Property-Ä "
    }

    assert [%{"operation_id" => " Op-Ä ", "group_id" => " Group-Ä "}] =
             batch(conn, [open_group(identifiers)])

    group = Repo.get!(Group, identifiers["group_id"])
    assert group.guest_id == identifiers["guest_id"]
    assert group.property_id == identifiers["property_id"]
  end

  for {label, changes, code} <- [
        {"zero nights", %{"departure_on" => "2026-12-10"}, "invalid_stay"},
        {"negative nights", %{"departure_on" => "2026-12-09"}, "invalid_stay"},
        {"bad arrival", %{"arrival_on" => "2026-02-30"}, "invalid_stay"},
        {"non-date departure", %{"departure_on" => 12}, "invalid_stay"},
        {"empty rooms", %{"rooms" => []}, "invalid_rooms"},
        {"non-list rooms", %{"rooms" => %{}}, "invalid_rooms"},
        {"malformed room", %{"rooms" => [nil]}, "invalid_rooms"},
        {"missing room rate", %{"rooms" => [%{"room_id" => "r"}]}, "invalid_rooms"},
        {"negative rate", %{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => -1}]},
         "invalid_rooms"},
        {"float rate", %{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 1.5}]},
         "invalid_rooms"},
        {"duplicate rooms",
         %{
           "rooms" => [
             %{"room_id" => "r", "nightly_rate_cents" => 10},
             %{"room_id" => "r", "nightly_rate_cents" => 20}
           ]
         }, "invalid_rooms"},
        {"unknown plan", %{"rate_plan" => "other"}, "invalid_rate_plan"}
      ] do
    test "rejects #{label} without creating a group and continues", %{conn: conn} do
      assert [%{"code" => code}, %{"status" => "applied", "revision" => 1}] =
               batch(conn, [open_group(unquote(Macro.escape(changes))), open_group()])

      assert code == unquote(code)
      assert Repo.aggregate(Group, :count) == 1
      assert ledger(conn) == cash(0, 0, 0)
    end
  end

  test "duplicate opening cannot replace an existing group", %{conn: conn} do
    batch(conn, [open_group()])
    before = snapshot()

    assert [%{"code" => "group_already_exists"}] =
             batch(conn, [open_group(%{"guest_id" => "replacement"})])

    assert snapshot() == before
  end

  test "malformed operations are rejected individually, including missing required fields", %{
    conn: conn
  } do
    malformed = [nil, [], "bad", 3, %{}, operation("unknown")]

    missing_fields =
      for key <- Map.keys(open_group()), do: Map.delete(open_group(), key)

    results = batch(conn, malformed ++ missing_fields ++ [open_group()])
    assert List.last(results)["status"] == "applied"
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))

    for op <- [
          operation("record_cash_payment"),
          operation("reschedule_group"),
          operation("cancel_group", %{"occurred_on" => "not-a-date"})
        ] do
      before = snapshot()
      assert [%{"code" => "invalid_operation"}] = batch(conn, [op])
      assert snapshot() == before
    end
  end

  test "invalid batch envelopes return 422, while an empty batch is valid", %{conn: conn} do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, [], "bad"] do
      response = conn |> post_json(body) |> json_response(422)
      assert response == %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch(conn, []) == []
  end

  test "missing groups return 404 and missing-group operations take precedence over revisions", %{
    conn: conn
  } do
    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch(conn, [operation(type, %{"expected_revision" => 9})])
    end

    assert ledger(conn) == cash(0, 0, 0)
  end

  test "unusable and excessive payments leave the account unchanged; exact funding succeeds", %{
    conn: conn
  } do
    batch(conn, [open_group()])

    for amount <- [nil, 0, -1, 1.5, "100", true, %{}] do
      before = snapshot()

      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [operation("record_cash_payment", %{"amount_cents" => amount})])

      assert snapshot() == before
    end

    assert [
             %{"revision" => 2, "outstanding_deposit_cents" => 14_500},
             %{"code" => "payment_exceeds_outstanding"},
             %{"revision" => 3, "outstanding_deposit_cents" => 0},
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             batch(conn, [
               operation("record_cash_payment", %{"amount_cents" => 5_000}),
               operation("record_cash_payment", %{"amount_cents" => 14_501}),
               operation("record_cash_payment", %{"amount_cents" => 14_500}),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    assert ledger(conn) == cash(19_500, 0, 0)
  end

  test "stale revisions win over other validation and never mutate persisted data", %{conn: conn} do
    batch(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 1_000})])

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("reschedule_group", %{"new_arrival_on" => "invalid"}),
          operation("cancel_group")
        ] do
      before = snapshot()

      assert batch(conn, [Map.put(op, "expected_revision", 1)]) == [
               %{
                 "operation_id" => op["operation_id"],
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ]

      assert snapshot() == before
    end

    assert [%{"revision" => 3}, %{"code" => "stale_revision", "actual_revision" => 3}] =
             batch(conn, [
               operation("cancel_group", %{"expected_revision" => 2}),
               operation("cancel_group", %{"expected_revision" => 2})
             ])
  end

  test "rescheduling validates dates, preserves prices and handles leap days", %{conn: conn} do
    batch(conn, [open_group()])

    for arrival <- [nil, "2026-02-29", "2026-10-04", "2026-10-03", 123, "9999-12-31"] do
      before = snapshot()

      assert [%{"code" => "invalid_stay"}] =
               batch(conn, [operation("reschedule_group", %{"new_arrival_on" => arrival})])

      assert snapshot() == before
    end

    assert [%{"new_departure_on" => "2028-03-02", "revision" => 2}, %{"revision" => 3}] =
             batch(conn, [
               operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2028-02-28",
                 "expected_revision" => 2
               })
             ])

    assert read_group(conn)["deposit_due_cents"] == 19_500
    assert read_group(conn)["lodging_total_cents"] == 97_500
  end

  for {plan, date, refunded, retained} <- [
        {"flexible", "2026-11-25", 5_000, 0},
        {"flexible", "2026-11-26", 5_000, 0},
        {"flexible", "2026-11-27", 0, 5_000},
        {"advance_purchase", "2026-10-04", 0, 5_000}
      ] do
    test "settles #{plan} cancellation on #{date} using only paid cash", %{conn: conn} do
      assert [
               _,
               _,
               %{"refunded_cents" => refunded, "retained_cents" => retained, "revision" => 3}
             ] =
               batch(conn, [
                 open_group(%{"rate_plan" => unquote(plan)}),
                 operation("record_cash_payment", %{"amount_cents" => 5_000}),
                 operation("cancel_group", %{"occurred_on" => unquote(date)})
               ])

      assert {refunded, retained} == {unquote(refunded), unquote(retained)}
      assert ledger(conn) == cash(0, refunded, retained)

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = read_group(conn)

      for op <- [
            operation("record_cash_payment", %{"amount_cents" => 1}),
            operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
            operation("cancel_group")
          ] do
        before = snapshot()
        assert [%{"code" => "group_not_active"}] = batch(conn, [op])
        assert snapshot() == before
      end
    end
  end

  test "cancellation uses the moved arrival and unpaid cancellation creates no cash", %{
    conn: conn
  } do
    assert [_, _, _, %{"refunded_cents" => 100}, _, %{"retained_cents" => 0}] =
             batch(conn, [
               open_group(),
               operation("record_cash_payment", %{"amount_cents" => 100}),
               operation("reschedule_group", %{"new_arrival_on" => "2026-12-20"}),
               operation("cancel_group", %{"occurred_on" => "2026-12-01"}),
               open_group(%{"group_id" => "unpaid", "rate_plan" => "advance_purchase"}),
               operation("cancel_group", %{"group_id" => "unpaid"})
             ])

    assert ledger(conn) == cash(0, 100, 0)
  end

  test "ledger aggregates held cash and both settlement types across properties", %{conn: conn} do
    for {id, date} <- [{"held", nil}, {"refunded", "2026-11-26"}, {"retained", "2026-11-27"}] do
      batch(conn, [
        open_group(%{"group_id" => id, "property_id" => id}),
        operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 100})
      ])

      if date,
        do: batch(conn, [operation("cancel_group", %{"group_id" => id, "occurred_on" => date})])
    end

    assert ledger(conn) == cash(100, 100, 100)
  end

  defp batch(conn, operations) do
    conn
    |> post_json(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp post_json(conn, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp read_group(conn),
    do: conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn), do: conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  defp snapshot, do: Repo.all(Group)

  defp cash(held, refunded, retained) do
    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => 0,
      "credit_liability_cents" => 0
    }
  end
end
