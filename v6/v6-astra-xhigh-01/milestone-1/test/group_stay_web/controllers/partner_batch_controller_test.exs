defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  test "empty batches, invalid envelopes, and missing read resources", %{conn: conn} do
    assert batch(conn, []) == []

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, [], nil, 1, "batch"] do
      response = post_json(conn, "/api/v1/partner-batches", body)
      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    response = post_json(conn, "/api/v1/partner-batches?operations[]=fake", %{})
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}
  end

  test "opens and reads a group with exact partner identifiers and original room order", %{
    conn: conn
  } do
    opening =
      open_operation(%{
        "operation_id" => " OP-Ä 01 ",
        "group_id" => "Group-Ä 01",
        "guest_id" => " Guest-01 ",
        "property_id" => "AMS-01",
        "expected_revision" => 999
      })

    assert batch(conn, [opening]) == [
             %{
               "operation_id" => " OP-Ä 01 ",
               "status" => "applied",
               "group_id" => "Group-Ä 01",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
           ]

    assert group(conn, opening["group_id"]) == %{
             "group_id" => "Group-Ä 01",
             "guest_id" => " Guest-01 ",
             "property_id" => "AMS-01",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 1,
             "rooms" => opening["rooms"],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }

    assert ledger(conn)["cash_held_cents"] == 0
  end

  test "rounds each flexible room's deposit independently using integer arithmetic", %{conn: conn} do
    for {rates, expected} <- [{[1, 1, 1], 0}, {[3, 3], 2}, {[2, 3, 7, 8], 4}, {[0], 0}] do
      rooms =
        rates
        |> Enum.with_index()
        |> Enum.map(fn {rate, index} ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => rate}
        end)

      id = "rounding-#{expected}-#{length(rates)}"

      assert [%{"deposit_due_cents" => ^expected, "status" => "applied"}] =
               batch(conn, [
                 open_operation(%{
                   "group_id" => id,
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11",
                   "rooms" => rooms
                 })
               ])

      assert group(conn, id)["lodging_total_cents"] == Enum.sum(rates)
    end
  end

  test "advance purchase requires the entire lodging amount and rooms are unique per group", %{
    conn: conn
  } do
    assert [%{"deposit_due_cents" => 97500}, %{"deposit_due_cents" => 19500}] =
             batch(conn, [
               open_operation(%{"rate_plan" => "advance_purchase"}),
               open_operation(%{"group_id" => "second"})
             ])
  end

  test "large integer amounts retain exact cents and ledger sums do not overflow", %{conn: conn} do
    amount = 9_223_372_036_854_775_807

    for id <- ["large-a", "large-b"] do
      assert [%{"deposit_due_cents" => ^amount}, %{"outstanding_deposit_cents" => 0}] =
               batch(conn, [
                 open_operation(%{
                   "group_id" => id,
                   "rate_plan" => "advance_purchase",
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "a", "nightly_rate_cents" => amount}]
                 }),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => amount})
               ])
    end

    assert ledger(conn)["cash_held_cents"] == amount * 2

    batch(conn, [
      operation("cancel_group", %{"group_id" => "large-a"}),
      operation("cancel_group", %{"group_id" => "large-b"})
    ])

    assert ledger(conn)["cash_held_cents"] == 0
    assert ledger(conn)["cash_retained_cents"] == amount * 2
  end

  test "opening validation leaves no partial group or rooms and permits a later valid opening", %{
    conn: conn
  } do
    invalid = [
      {%{"arrival_on" => "2026-12-13"}, "invalid_stay"},
      {%{"arrival_on" => "2026-12-14"}, "invalid_stay"},
      {%{"arrival_on" => "2026-02-30"}, "invalid_stay"},
      {%{"departure_on" => 123}, "invalid_stay"},
      {%{"departure_on" => nil}, "invalid_stay"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"rate_plan" => nil}, "invalid_rate_plan"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => %{}}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a"}]}, "invalid_rooms"},
      {%{
         "rooms" => [
           %{"room_id" => "a", "nightly_rate_cents" => 100},
           %{"room_id" => "a", "nightly_rate_cents" => 200}
         ]
       }, "invalid_rooms"}
    ]

    for {overrides, code} <- invalid do
      assert_rejected_without_changes(conn, open_operation(overrides), code)
    end

    for rate <- [-1, 1.5, "100", true, nil, 9_223_372_036_854_775_808] do
      opening =
        open_operation(%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => rate}]})

      assert_rejected_without_changes(conn, opening, "invalid_rooms")
    end

    for room_id <- [nil, "", 1] do
      opening =
        open_operation(%{"rooms" => [%{"room_id" => room_id, "nightly_rate_cents" => 100}]})

      assert_rejected_without_changes(conn, opening, "invalid_rooms")
    end

    assert [%{"status" => "applied"}] = batch(conn, [open_operation()])
    assert_rejected_without_changes(conn, open_operation(), "group_already_exists")
  end

  test "missing operation data and unknown types are rejected and later operations still run", %{
    conn: conn
  } do
    for field <-
          ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms) do
      assert_rejected_without_changes(
        conn,
        Map.delete(open_operation(), field),
        "invalid_operation"
      )
    end

    for bad <- [
          nil,
          [],
          3,
          "open",
          %{},
          operation("unknown"),
          open_operation(%{"occurred_on" => "bad"})
        ] do
      assert_rejected_without_changes(conn, bad, "invalid_operation")
    end

    for field <- ~w(operation_id group_id guest_id property_id), value <- [nil, "", 123] do
      assert_rejected_without_changes(
        conn,
        open_operation(%{field => value}),
        "invalid_operation"
      )
    end

    assert [%{"status" => "rejected"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             batch(conn, [
               nil,
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    for incomplete <- [
          operation("record_cash_payment"),
          operation("reschedule_group"),
          Map.delete(operation("cancel_group"), "occurred_on")
        ] do
      assert_rejected_without_changes(conn, incomplete, "invalid_operation")
    end
  end

  test "payments use current outstanding cash and failed operations do not stop a batch", %{
    conn: conn
  } do
    assert [
             %{"revision" => 1},
             %{"amount_cents" => 5000, "outstanding_deposit_cents" => 14500, "revision" => 2},
             %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
             %{"amount_cents" => 14500, "outstanding_deposit_cents" => 0, "revision" => 3}
           ] =
             batch(conn, [
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 5000}),
               operation("record_cash_payment", %{"amount_cents" => 14501}),
               operation("record_cash_payment", %{
                 "amount_cents" => 14500,
                 "expected_revision" => 2
               })
             ])

    assert group(conn)["deposit_paid_cents"] == 19500
    assert group(conn)["outstanding_deposit_cents"] == 0
    assert ledger(conn)["cash_held_cents"] == 19500

    assert_rejected_without_changes(
      conn,
      operation("record_cash_payment", %{"amount_cents" => 1}),
      "payment_exceeds_outstanding"
    )
  end

  test "unusable payments are rejected without touching balances or revisions", %{conn: conn} do
    batch(conn, [open_operation()])

    for amount <- [0, -1, 1.1, "100", nil, true, [], %{}, 9_223_372_036_854_775_808] do
      assert_rejected_without_changes(
        conn,
        operation("record_cash_payment", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end
  end

  test "rescheduling preserves nights, prices, booked date and cash across leap days and years",
       %{conn: conn} do
    batch(conn, [
      open_operation(%{"arrival_on" => "2028-02-28", "departure_on" => "2028-03-02"}),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    before_move = group(conn)

    assert [
             %{
               "new_arrival_on" => "2029-12-30",
               "new_departure_on" => "2030-01-02",
               "revision" => 3
             }
           ] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2029-12-30"})])

    assert Map.drop(group(conn), ~w(arrival_on departure_on revision)) ==
             Map.drop(before_move, ~w(arrival_on departure_on revision))

    assert [%{"revision" => 4, "new_departure_on" => "2028-03-03"}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-29"})])

    assert [%{"revision" => 5}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-29"})])

    assert ledger(conn)["cash_held_cents"] == 100

    for arrival <- ["2026-11-01", "2026-10-31", "2027-02-29", "bad", nil, 1, "9999-12-31"] do
      assert_rejected_without_changes(
        conn,
        operation("reschedule_group", %{"new_arrival_on" => arrival}),
        "invalid_stay"
      )
    end
  end

  test "cancellation settlement respects the 14-day boundary, rate plan and unpaid deposits", %{
    conn: conn
  } do
    cases = [
      {"early", "flexible", "2026-11-25", 5000, 5000, 0},
      {"boundary", "flexible", "2026-11-26", 5000, 5000, 0},
      {"late", "flexible", "2026-11-27", 5000, 0, 5000},
      {"arrival", "flexible", "2026-12-10", 5000, 0, 5000},
      {"advance", "advance_purchase", "2026-10-03", 5000, 0, 5000},
      {"unpaid", "flexible", "2026-11-26", 0, 0, 0},
      {"unpaid-advance", "advance_purchase", "2026-10-03", 0, 0, 0}
    ]

    for {id, plan, occurred_on, paid, refunded, retained} <- cases do
      batch(conn, [open_operation(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0 do
        batch(conn, [
          operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})
        ])
      end

      expected_revision = if paid > 0, do: 3, else: 2

      assert [
               %{
                 "refunded_cents" => ^refunded,
                 "retained_cents" => ^retained,
                 "revision" => ^expected_revision
               }
             ] =
               batch(conn, [
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => occurred_on})
               ])

      cancelled = group(conn, id)
      assert cancelled["status"] == "cancelled"
      assert cancelled["deposit_due_cents"] == 0
      assert cancelled["deposit_paid_cents"] == 0
      assert cancelled["outstanding_deposit_cents"] == 0
      assert cancelled["lodging_total_cents"] == 97500

      for later <- [
            operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 1}),
            operation("reschedule_group", %{"group_id" => id, "new_arrival_on" => "2027-01-01"}),
            operation("cancel_group", %{"group_id" => id})
          ] do
        assert_rejected_without_changes(conn, later, "group_not_active")
      end
    end

    batch(conn, [
      open_operation(%{"group_id" => "still-active"}),
      operation("record_cash_payment", %{"group_id" => "still-active", "amount_cents" => 123})
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 123,
             "cash_refunded_cents" => 10000,
             "cash_retained_cents" => 15000
           }
  end

  test "cancellation uses the current arrival after rescheduling", %{conn: conn} do
    assert [_, _, _, %{"refunded_cents" => 100, "retained_cents" => 0, "revision" => 4}] =
             batch(conn, [
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100}),
               operation("reschedule_group", %{"new_arrival_on" => "2026-12-20"}),
               operation("cancel_group", %{"occurred_on" => "2026-12-01"})
             ])
  end

  test "revision guards observe earlier batch operations, reject stale writes, and increment once",
       %{conn: conn} do
    assert [
             %{"revision" => 1},
             %{"revision" => 2},
             %{"code" => "stale_revision", "expected_revision" => 1, "actual_revision" => 2},
             %{"revision" => 3},
             %{"revision" => 4},
             %{"code" => "stale_revision", "expected_revision" => 3, "actual_revision" => 4}
           ] =
             batch(conn, [
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 1}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2026-12-10",
                 "expected_revision" => 2
               }),
               operation("cancel_group", %{"expected_revision" => 3}),
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 3})
             ])

    assert group(conn)["revision"] == 4
    assert ledger(conn)["cash_refunded_cents"] == 100
  end

  test "missing groups precede revision checks, and stale revisions precede all other domain rules",
       %{conn: conn} do
    bad_operations = [
      operation("record_cash_payment", %{"amount_cents" => -1}),
      operation("record_cash_payment", %{"amount_cents" => 99999}),
      operation("reschedule_group", %{"new_arrival_on" => "bad"}),
      operation("cancel_group", %{"occurred_on" => "bad"})
    ]

    for op <- bad_operations do
      assert_rejected_without_changes(
        conn,
        Map.put(op, "expected_revision", 10),
        "group_not_found"
      )
    end

    batch(conn, [open_operation()])

    for op <- bad_operations, expected <- [0, 2, nil, "1", 1.0] do
      result =
        assert_rejected_without_changes(
          conn,
          Map.put(op, "expected_revision", expected),
          "stale_revision"
        )

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => expected,
               "actual_revision" => 1
             }
    end

    batch(conn, [operation("cancel_group")])

    for op <- bad_operations do
      assert_rejected_without_changes(conn, Map.put(op, "expected_revision", 1), "stale_revision")
    end
  end

  defp assert_rejected_without_changes(conn, operation, code) do
    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code} = result] = batch(conn, [operation])
    assert snapshot() == before
    result
  end

  defp snapshot, do: {Repo.all(Group), Repo.all(Room)}

  defp batch(conn, operations) do
    conn
    |> post_json("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp post_json(conn, path, body) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp group(conn, id \\ "group-81") do
    conn |> get("/api/v1/groups/#{URI.encode(id)}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end
end
