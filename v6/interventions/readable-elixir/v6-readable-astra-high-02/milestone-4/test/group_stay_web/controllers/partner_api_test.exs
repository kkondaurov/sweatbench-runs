defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  test "opens a group and returns the complete read model with original room order", %{conn: conn} do
    assert [result] =
             batch(conn, [open_group(%{"operation_id" => "open-1", "expected_revision" => 99})])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19500,
             "revision" => 1
           }

    assert group(conn) == %{
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
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "lodging_total_cents" => 45000,
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 17500,
                 "status" => "active",
                 "lodging_total_cents" => 52500,
                 "deposit_due_cents" => 10500,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             ],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "outstanding_deposit_cents" => 19500
           }

    assert ledger(conn) == zero_ledger()
  end

  test "preserves identifiers verbatim and scopes room identifiers to groups", %{conn: conn} do
    for id <- [" Group-Ä 01 ", "group-other"] do
      assert [%{"status" => "applied", "group_id" => ^id}] =
               batch(conn, [open_group(%{"group_id" => id, "guest_id" => " Guest 01 "})])

      assert {:ok, saved} = GroupStay.Reservations.get_group(id)
      assert saved.group_id == id
      assert saved.guest_id == " Guest 01 "
      assert Enum.map(saved.rooms, & &1.room_id) == ["room-b", "room-a"]
    end
  end

  test "rounds deposits per room with integer arithmetic", %{conn: conn} do
    rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 3},
      %{"room_id" => "b", "nightly_rate_cents" => 3},
      %{"room_id" => "c", "nightly_rate_cents" => 2}
    ]

    assert [%{"deposit_due_cents" => 2}] =
             batch(conn, [
               open_group(%{"rooms" => rooms, "departure_on" => "2026-12-11"})
             ])

    assert group(conn)["lodging_total_cents"] == 8
  end

  test "advance purchase requires the entire lodging amount", %{conn: conn} do
    assert [%{"deposit_due_cents" => 97500}] =
             batch(conn, [open_group(%{"rate_plan" => "advance_purchase"})])
  end

  test "supports a zero-priced room without inventing a cash balance", %{conn: conn} do
    assert [%{"deposit_due_cents" => 0}] =
             batch(conn, [
               open_group(%{"rooms" => [%{"room_id" => "free", "nightly_rate_cents" => 0}]})
             ])

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             batch(conn, [operation("record_cash_payment", %{"amount_cents" => 1})])

    assert ledger(conn) == zero_ledger()
  end

  test "batch shape errors return 422, while an empty batch succeeds", %{conn: conn} do
    for body <- [
          nil,
          1,
          true,
          "bad",
          [],
          %{},
          %{"operations" => nil},
          %{"operations" => %{}},
          %{"operations" => "bad"}
        ] do
      assert conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", Jason.encode!(body))
             |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch(conn, []) == []
  end

  test "malformed operations are individually rejected and processing continues", %{conn: conn} do
    malformed = [
      nil,
      5,
      "open_group",
      [],
      %{},
      operation("unknown"),
      Map.delete(open_group(), "operation_id"),
      open_group(%{"group_id" => 12}),
      open_group(%{"guest_id" => ""}),
      open_group(%{"property_id" => nil}),
      open_group(%{"occurred_on" => "2026-02-30"})
    ]

    results = batch(conn, malformed ++ [open_group()])
    assert length(results) == length(malformed) + 1

    for result <- Enum.drop(results, -1) do
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end

    assert List.last(results)["status"] == "applied"
    assert Repo.aggregate(Group, :count) == 1
    assert Repo.aggregate(Room, :count) == 2
  end

  test "every required operation field is checked without changing the database", %{conn: conn} do
    commands = [
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 10}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      operation("cancel_group")
    ]

    for command <- commands, key <- Map.keys(command) do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [
                 command |> Map.replace("operation_id", unique_operation_id()) |> Map.delete(key)
               ])

      assert snapshot() == {[], []}
    end
  end

  test "missing groups return the documented error on reads and all updates", %{conn: conn} do
    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    for command <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("reschedule_group", %{"new_arrival_on" => "bad"}),
          operation("cancel_group")
        ] do
      assert [%{"code" => "group_not_found"}] =
               batch(conn, [Map.put(command, "expected_revision", 99)])
    end
  end

  test "invalid opening values leave no group or rooms behind", %{conn: conn} do
    cases = [
      {%{"arrival_on" => "bad"}, "invalid_stay"},
      {%{"arrival_on" => nil}, "invalid_stay"},
      {%{"arrival_on" => "2026-02-29"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"departure_on" => 17}, "invalid_stay"},
      {%{"rate_plan" => "Flexible"}, "invalid_rate_plan"},
      {%{"rate_plan" => nil}, "invalid_rate_plan"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => %{}}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a"}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "", "nightly_rate_cents" => 1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => 12, "nightly_rate_cents" => 1}]}, "invalid_rooms"},
      {%{"rooms" => List.duplicate(%{"room_id" => "a", "nightly_rate_cents" => 1}, 2)},
       "invalid_rooms"}
    ]

    cases =
      cases ++
        for rate <- [-1, 1.5, "100", true, nil, 9_223_372_036_854_775_807] do
          {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => rate}]}, "invalid_rooms"}
        end

    for {overrides, code} <- cases do
      assert [%{"code" => ^code, "status" => "rejected"}] = batch(conn, [open_group(overrides)])
      assert snapshot() == {[], []}
    end
  end

  test "duplicate opens leave the existing reservation and ledger intact", %{conn: conn} do
    batch(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 200})])
    before = snapshot()

    assert [%{"code" => "group_already_exists"}] =
             batch(conn, [open_group(%{"rooms" => []})])

    assert snapshot() == before
  end

  test "ordered payments see earlier results and rejection does not halt the batch", %{conn: conn} do
    results =
      batch(conn, [
        open_group(%{"operation_id" => "open-1"}),
        operation("record_cash_payment", %{
          "operation_id" => "pay-a",
          "amount_cents" => 5000,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{"operation_id" => "pay-b", "amount_cents" => 20000}),
        operation("record_cash_payment", %{
          "operation_id" => "pay-c",
          "amount_cents" => 14500,
          "expected_revision" => 2
        })
      ])

    assert Enum.map(results, & &1["operation_id"]) == ["open-1", "pay-a", "pay-b", "pay-c"]
    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected", "applied"]

    assert Enum.at(results, 1) == %{
             "operation_id" => "pay-a",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5000,
             "outstanding_deposit_cents" => 14500,
             "revision" => 2
           }

    assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"
    assert List.last(results)["revision"] == 3
    assert group(conn)["deposit_paid_cents"] == 19500
    assert group(conn)["outstanding_deposit_cents"] == 0
    assert ledger(conn) == %{zero_ledger() | "cash_held_cents" => 19500}
  end

  test "invalid cash amounts never alter balances or revision", %{conn: conn} do
    batch(conn, [open_group()])
    before = snapshot()

    for amount <- [0, -1, 1.5, "100", nil, true, [], %{}, 9_223_372_036_854_775_808] do
      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [operation("record_cash_payment", %{"amount_cents" => amount})])

      assert snapshot() == before
    end
  end

  test "stale revisions precede other domain failures and do not change any records", %{
    conn: conn
  } do
    batch(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = snapshot()

    for command <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("reschedule_group", %{"new_arrival_on" => "bad"}),
          operation("cancel_group", %{"occurred_on" => "bad"})
        ] do
      assert [result] = batch(conn, [Map.put(command, "expected_revision", 1)])

      assert result == %{
               "operation_id" => command["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert snapshot() == before
    end

    batch(conn, [operation("cancel_group", %{"expected_revision" => 2})])
    cancelled = snapshot()

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             batch(conn, [operation("cancel_group", %{"expected_revision" => 2})])

    assert snapshot() == cancelled
  end

  test "only the exact integer revision is accepted when supplied", %{conn: conn} do
    batch(conn, [open_group()])

    for expected <- [0, -1, 1.0, "1", nil, true, %{}, []] do
      assert [
               %{
                 "code" => "stale_revision",
                 "expected_revision" => ^expected,
                 "actual_revision" => 1
               }
             ] =
               batch(conn, [operation("cancel_group", %{"expected_revision" => expected})])
    end

    assert group(conn)["revision"] == 1
  end

  test "a stale operation in a batch leaves the next operation's revision available", %{
    conn: conn
  } do
    assert [opened, paid, stale, cancelled] =
             batch(conn, [
               open_group(),
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 1
               }),
               operation("cancel_group", %{"expected_revision" => 2})
             ])

    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 2
    assert cancelled["revision"] == 3
    assert cancelled["refunded_cents"] == 100
    assert group(conn)["arrival_on"] == "2026-12-10"
    assert ledger(conn) == %{zero_ledger() | "cash_refunded_cents" => 100}
  end

  test "rescheduling preserves length, pricing, rooms and payments across leap day", %{conn: conn} do
    batch(conn, [open_group(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = group(conn)

    assert [result] =
             batch(conn, [
               operation("reschedule_group", %{
                 "operation_id" => "reschedule_group-1",
                 "new_arrival_on" => "2028-02-28",
                 "expected_revision" => 2
               })
             ])

    assert result == %{
             "operation_id" => "reschedule_group-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2028-02-28",
             "new_departure_on" => "2028-03-02",
             "policy_version" => "flex-14",
             "refundable_until" => "2028-02-14",
             "revision" => 3
           }

    assert group(conn) ==
             Map.merge(before, %{
               "arrival_on" => "2028-02-28",
               "departure_on" => "2028-03-02",
               "refundable_until" => "2028-02-14",
               "revision" => 3
             })

    assert ledger(conn)["cash_held_cents"] == 100

    # Moving to the current arrival is still an applied operation.
    assert [%{"revision" => 4}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])
  end

  test "rescheduling requires a usable arrival strictly after the operation date", %{conn: conn} do
    batch(conn, [open_group()])
    before = snapshot()

    for arrival <- [nil, 123, "bad", "2027-02-29", "2026-11-01", "2026-10-31", "9999-12-31"] do
      assert [%{"code" => "invalid_stay"}] =
               batch(conn, [operation("reschedule_group", %{"new_arrival_on" => arrival})])

      assert snapshot() == before
    end

    assert [%{"new_departure_on" => "2026-11-05"}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2026-11-02"})])
  end

  for {rate_plan, date, refunded, retained} <- [
        {"flexible", "2026-11-25", 5000, 0},
        {"flexible", "2026-11-26", 5000, 0},
        {"flexible", "2026-11-27", 0, 5000},
        {"flexible", "2026-12-10", 0, 5000},
        {"advance_purchase", "2026-10-03", 0, 5000}
      ] do
    test "settles #{rate_plan} cancelled on #{date}", %{conn: conn} do
      batch(conn, [
        open_group(%{"rate_plan" => unquote(rate_plan)}),
        operation("record_cash_payment", %{"amount_cents" => 5000})
      ])

      assert [result] =
               batch(conn, [
                 operation("cancel_group", %{
                   "operation_id" => "cancel_group-1",
                   "occurred_on" => unquote(date),
                   "expected_revision" => 2
                 })
               ])

      assert result == %{
               "operation_id" => "cancel_group-1",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => unquote(refunded),
               "retained_cents" => unquote(retained),
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => unquote(refunded),
               "cash_retained_cents" => unquote(retained),
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 0
             }

      saved = group(conn)
      assert saved["status"] == "cancelled"
      assert saved["deposit_due_cents"] == 0
      assert saved["deposit_paid_cents"] == 0
      assert saved["outstanding_deposit_cents"] == 0
      assert saved["lodging_total_cents"] == 0

      assert Enum.map(saved["rooms"], &Map.take(&1, ["room_id", "nightly_rate_cents"])) ==
               open_group()["rooms"]

      assert Enum.all?(saved["rooms"], &(&1["status"] == "cancelled"))
    end
  end

  test "cancellation uses the rescheduled arrival and subsequent operations are rejected", %{
    conn: conn
  } do
    results =
      batch(conn, [
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 5000}),
        operation("reschedule_group", %{"new_arrival_on" => "2026-12-20"}),
        operation("cancel_group", %{"occurred_on" => "2026-12-06", "expected_revision" => 3})
      ])

    assert List.last(results)["refunded_cents"] == 5000
    assert List.last(results)["revision"] == 4
    before = snapshot()

    for command <- [
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
          operation("cancel_group")
        ] do
      assert [%{"code" => "group_not_active"}] =
               batch(conn, [Map.put(command, "expected_revision", 4)])

      assert snapshot() == before
    end
  end

  test "ledger sums active cash and both settlements, excluding unpaid deposits", %{conn: conn} do
    for {id, paid, cancellation} <- [
          {"active", 123, nil},
          {"refund", 456, "2026-11-26"},
          {"retain", 789, "2026-11-27"},
          {"unpaid", 0, "2026-11-27"}
        ] do
      batch(conn, [open_group(%{"group_id" => id})])

      if paid > 0,
        do:
          batch(conn, [
            operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})
          ])

      if cancellation,
        do:
          batch(conn, [
            operation("cancel_group", %{"group_id" => id, "occurred_on" => cancellation})
          ])
    end

    assert ledger(conn) == %{
             "cash_held_cents" => 123,
             "cash_refunded_cents" => 456,
             "cash_retained_cents" => 789,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }

    assert Repo.get!(Group, "unpaid").revision == 2
  end

  defp batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn),
    do: conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn), do: conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  defp zero_ledger,
    do: %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0,
      "cash_reduced_cents" => 0,
      "cash_charged_back_cents" => 0,
      "credit_shortfall_cents" => 0,
      "credit_liability_cents" => 0
    }

  defp snapshot, do: {Repo.all(Group), Repo.all(Room)}
end
