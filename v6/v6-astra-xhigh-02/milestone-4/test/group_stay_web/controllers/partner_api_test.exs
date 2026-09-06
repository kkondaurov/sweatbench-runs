defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ReservationFixtures
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  test "invalid batch bodies return 422 without changing the database", %{conn: conn} do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, [], nil, "batch", 123] do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", Jason.encode!(body))

      assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
      assert Repo.all(Group) == []
    end
  end

  test "query parameters cannot supply a missing operations body", %{conn: conn} do
    response = post(conn, "/api/v1/partner-batches?operations[]=anything", %{})
    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_batch"}}
  end

  test "an empty batch and ledger, and a missing group", %{conn: conn} do
    assert batch(conn, []) == []

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}
  end

  test "opens the documented group and returns all public fields", %{conn: conn} do
    assert batch(conn, [open_operation(%{"operation_id" => "op-open"})]) == [
             %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             }
           ]

    assert group(conn) == %{
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
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "status" => "active",
             "rooms" => expected_rooms("active"),
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }

    assert ledger(conn)["cash_held_cents"] == 0
  end

  test "preserves partner identifiers and room order without trimming or coercion", %{conn: conn} do
    rooms = [
      %{"room_id" => " z ", "nightly_rate_cents" => 10},
      %{"room_id" => "Å-001", "nightly_rate_cents" => 20},
      %{"room_id" => "001", "nightly_rate_cents" => 30}
    ]

    attrs = %{
      "operation_id" => " Op-001 ",
      "group_id" => " Grøup-001 ",
      "guest_id" => " Guest-001 ",
      "property_id" => " Property-001 ",
      "rooms" => rooms,
      "expected_revision" => -10
    }

    assert [%{"operation_id" => " Op-001 ", "revision" => 1, "status" => "applied"}] =
             batch(conn, [open_operation(attrs)])

    data = group(conn, attrs["group_id"])

    assert Map.take(data, ~w(group_id guest_id property_id)) ==
             Map.take(attrs, ~w(group_id guest_id property_id))

    assert Enum.map(data["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents))) == rooms
  end

  for {name, rates, nights, plan, lodging, deposit} <- [
        {"rounds down separately for each room", [2, 2], 1, "flexible", 4, 0},
        {"rounds up separately for each room", [3, 3], 1, "flexible", 6, 2},
        {"rounds each room's entire stay, not individual nights", [1, 1], 3, "flexible", 6, 2},
        {"requires full lodging for advance purchase", [101, 204], 3, "advance_purchase", 915,
         915},
        {"allows zero priced rooms", [0], 1, "flexible", 0, 0},
        {"calculates large integer cents without float precision loss", [9_007_199_254_740_993],
         1, "flexible", 9_007_199_254_740_993, 1_801_439_850_948_199}
      ] do
    test name, %{conn: conn} do
      rooms =
        unquote(rates)
        |> Enum.with_index()
        |> Enum.map(fn {rate, i} -> %{"room_id" => "room-#{i}", "nightly_rate_cents" => rate} end)

      opening =
        open_operation(%{
          "rooms" => rooms,
          "departure_on" => Date.to_iso8601(Date.add(~D[2026-12-10], unquote(nights))),
          "rate_plan" => unquote(plan)
        })

      assert [%{"status" => "applied", "deposit_due_cents" => unquote(deposit)}] =
               batch(conn, [opening])

      assert group(conn)["lodging_total_cents"] == unquote(lodging)
    end
  end

  for {field, value, code} <- [
        {"arrival_on", "2026-12-13", "invalid_stay"},
        {"arrival_on", "2026-12-14", "invalid_stay"},
        {"arrival_on", "2026-02-29", "invalid_stay"},
        {"arrival_on", nil, "invalid_stay"},
        {"departure_on", 123, "invalid_stay"},
        {"departure_on", "2026-12-14T00:00:00Z", "invalid_stay"},
        {"rate_plan", "unknown", "invalid_rate_plan"},
        {"rate_plan", nil, "invalid_rate_plan"},
        {"rooms", [], "invalid_rooms"},
        {"rooms", nil, "invalid_rooms"},
        {"rooms", %{}, "invalid_rooms"},
        {"rooms", [nil], "invalid_rooms"},
        {"rooms", [%{"room_id" => "r"}], "invalid_rooms"},
        {"rooms", [%{"room_id" => "", "nightly_rate_cents" => 100}], "invalid_rooms"},
        {"rooms", [%{"room_id" => 1, "nightly_rate_cents" => 100}], "invalid_rooms"},
        {"rooms", [%{"room_id" => "r", "nightly_rate_cents" => -1}], "invalid_rooms"},
        {"rooms", [%{"room_id" => "r", "nightly_rate_cents" => 1.5}], "invalid_rooms"},
        {"rooms", [%{"room_id" => "r", "nightly_rate_cents" => "100"}], "invalid_rooms"},
        {"rooms", [%{"room_id" => "r", "nightly_rate_cents" => 9_223_372_036_854_775_808}],
         "invalid_rooms"},
        {"rooms", [%{"room_id" => "r", "nightly_rate_cents" => 4_000_000_000_000_000_000}],
         "invalid_rooms"},
        {"rooms",
         [
           %{"room_id" => "r", "nightly_rate_cents" => 100},
           %{"room_id" => "r", "nightly_rate_cents" => 200}
         ], "invalid_rooms"}
      ] do
    test "opening rejects #{field}=#{inspect(value)} atomically", %{conn: conn} do
      opening = open_operation(%{unquote(field) => unquote(Macro.escape(value))})
      assert_rejected_unchanged(conn, opening, unquote(code))
      assert [%{"status" => "applied"}] = batch(conn, [open_operation()])
    end
  end

  test "missing required opening fields and invalid identities are invalid operations", %{
    conn: conn
  } do
    for field <- Map.keys(open_operation()) do
      assert_rejected_unchanged(conn, Map.delete(open_operation(), field), "invalid_operation")
    end

    for field <- ~w(operation_id group_id guest_id property_id), value <- [nil, "", 123, %{}] do
      assert_rejected_unchanged(conn, open_operation(%{field => value}), "invalid_operation")
    end
  end

  test "duplicate group IDs cannot replace a group even after cancellation", %{conn: conn} do
    batch(conn, [open_operation()])
    assert_rejected_unchanged(conn, open_operation(), "group_already_exists")
    batch(conn, [operation("cancel_group")])
    assert_rejected_unchanged(conn, open_operation(), "group_already_exists")
  end

  test "unknown and malformed operations do not stop later operations", %{conn: conn} do
    malformed = [nil, [], "operation", 12, true, %{}, operation("unknown")]
    results = batch(conn, malformed ++ [open_operation()])

    assert Enum.map(Enum.take(results, length(malformed)), & &1["code"]) ==
             List.duplicate("invalid_operation", length(malformed))

    assert List.last(results)["status"] == "applied"
    assert group(conn)["revision"] == 1
  end

  test "batches apply in order, reject atomically, and continue", %{conn: conn} do
    results =
      batch(conn, [
        operation("record_cash_payment", %{"operation_id" => "before", "amount_cents" => 10}),
        open_operation(%{"operation_id" => "op-open"}),
        operation("record_cash_payment", %{
          "operation_id" => "partial",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{"operation_id" => "too-much", "amount_cents" => 14_501}),
        operation("record_cash_payment", %{
          "operation_id" => "rest",
          "amount_cents" => 14_500,
          "expected_revision" => 2
        })
      ])

    assert Enum.map(results, & &1["operation_id"]) == [
             "before",
             "op-open",
             "partial",
             "too-much",
             "rest"
           ]

    assert Enum.at(results, 0)["code"] == "group_not_found"

    assert Enum.at(results, 2) == %{
             "operation_id" => "partial",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_500,
             "revision" => 2
           }

    assert Enum.at(results, 3)["code"] == "payment_exceeds_outstanding"
    assert Enum.at(results, 4)["revision"] == 3
    assert Enum.at(results, 4)["outstanding_deposit_cents"] == 0
    assert group(conn)["deposit_paid_cents"] == 19_500
    assert ledger(conn)["cash_held_cents"] == 19_500

    assert_rejected_unchanged(
      conn,
      operation("record_cash_payment", %{"amount_cents" => 1}),
      "payment_exceeds_outstanding"
    )
  end

  test "rejects unusable payment amounts without changing any reservation or cash", %{conn: conn} do
    batch(conn, [open_operation(), operation("record_cash_payment", %{"amount_cents" => 1_000})])

    for amount <- [0, -1, 1.5, 1.0, "100", nil, true, [], %{}] do
      assert_rejected_unchanged(
        conn,
        operation("record_cash_payment", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end

    assert_rejected_unchanged(conn, operation("record_cash_payment"), "invalid_operation")
  end

  test "missing groups are resolved before revision and other domain validation", %{conn: conn} do
    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert_rejected_unchanged(
        conn,
        operation(type, %{"expected_revision" => 100}),
        "group_not_found"
      )
    end
  end

  test "stale revisions precede amounts, dates, missing fields, and inactive status", %{
    conn: conn
  } do
    batch(conn, [open_operation()])

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("record_cash_payment"),
          operation("reschedule_group", %{"new_arrival_on" => "bad-date"}),
          operation("reschedule_group"),
          operation("cancel_group", %{"occurred_on" => "bad-date"})
        ] do
      assert_stale(conn, Map.put(op, "expected_revision", 0), 1)
    end

    batch(conn, [operation("cancel_group", %{"expected_revision" => 1})])

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert_stale(conn, operation(type, %{"expected_revision" => 1}), 2)

      assert_rejected_unchanged(
        conn,
        operation(type, %{"expected_revision" => 2}),
        "group_not_active"
      )

      assert_rejected_unchanged(conn, operation(type), "group_not_active")
    end
  end

  test "expected revision must exactly equal the current integer revision", %{conn: conn} do
    batch(conn, [open_operation()])

    for expected <- [nil, "1", 1.0, -1, 0, 2, true, [], %{}] do
      assert_stale(conn, operation("cancel_group", %{"expected_revision" => expected}), 1)
    end
  end

  test "earlier batch revisions are visible and stale operations leave them unchanged", %{
    conn: conn
  } do
    [_, paid, stale, moved, cancelled] =
      batch(conn, [
        open_operation(%{"expected_revision" => 99}),
        operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
        operation("cancel_group", %{"expected_revision" => 1}),
        operation("reschedule_group", %{
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        }),
        operation("cancel_group", %{"expected_revision" => 3})
      ])

    assert paid["revision"] == 2
    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 2
    assert moved["revision"] == 3
    assert cancelled["revision"] == 4
    assert cancelled["refunded_cents"] == 100
    assert group(conn)["revision"] == 4
  end

  test "rescheduling crosses leap days and years, preserves price, rooms and booking date", %{
    conn: conn
  } do
    batch(conn, [open_operation(), operation("record_cash_payment", %{"amount_cents" => 1_000})])
    before = group(conn)

    assert batch(conn, [
             operation("reschedule_group", %{
               "operation_id" => "op-reschedule_group",
               "new_arrival_on" => "2028-02-28",
               "expected_revision" => 2
             })
           ]) ==
             [
               %{
                 "operation_id" => "op-reschedule_group",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2028-02-28",
                 "new_departure_on" => "2028-03-02",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2028-02-14",
                 "revision" => 3
               }
             ]

    assert Map.drop(group(conn), ~w(arrival_on departure_on revision refundable_until)) ==
             Map.drop(before, ~w(arrival_on departure_on revision refundable_until))

    batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2026-12-30"})])
    assert group(conn)["departure_on"] == "2027-01-02"
    assert group(conn)["revision"] == 4

    batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2026-12-30"})])
    assert group(conn)["revision"] == 5
    assert ledger(conn)["cash_held_cents"] == 1_000
  end

  test "rescheduling requires a usable arrival after the operation date", %{conn: conn} do
    batch(conn, [open_operation()])

    for arrival <- ["2026-10-04", "2026-10-03", "2027-02-29", "bad", nil, 123, "9999-12-31"] do
      assert_rejected_unchanged(
        conn,
        operation("reschedule_group", %{"new_arrival_on" => arrival}),
        "invalid_stay"
      )
    end

    assert_rejected_unchanged(conn, operation("reschedule_group"), "invalid_operation")
  end

  test "all operation types require a valid operation date", %{conn: conn} do
    batch(conn, [open_operation()])

    for op <- [
          open_operation(%{"group_id" => "new-group"}),
          operation("record_cash_payment", %{"amount_cents" => 100}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
          operation("cancel_group")
        ],
        date <- [nil, "bad-date", 123, "2026-02-29"] do
      assert_rejected_unchanged(
        conn,
        Map.merge(op, %{"operation_id" => Ecto.UUID.generate(), "occurred_on" => date}),
        "invalid_operation"
      )

      assert_rejected_unchanged(
        conn,
        Map.delete(Map.put(op, "operation_id", Ecto.UUID.generate()), "occurred_on"),
        "invalid_operation"
      )
    end
  end

  for {plan, cancellation_on, refunded, retained} <- [
        {"flexible", "2026-11-25", 5_000, 0},
        {"flexible", "2026-11-26", 5_000, 0},
        {"flexible", "2026-11-27", 0, 5_000},
        {"flexible", "2026-12-10", 0, 5_000},
        {"flexible", "2026-12-14", 0, 5_000},
        {"advance_purchase", "2026-10-04", 0, 5_000}
      ] do
    test "cancels #{plan} on #{cancellation_on} and settles only paid cash", %{conn: conn} do
      batch(conn, [
        open_operation(%{"rate_plan" => unquote(plan)}),
        operation("record_cash_payment", %{"amount_cents" => 5_000})
      ])

      assert batch(conn, [
               operation("cancel_group", %{
                 "operation_id" => "op-cancel_group",
                 "occurred_on" => unquote(cancellation_on),
                 "expected_revision" => 2
               })
             ]) ==
               [
                 %{
                   "operation_id" => "op-cancel_group",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "refunded_cents" => unquote(refunded),
                   "retained_cents" => unquote(retained),
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]

      cancelled = group(conn)
      assert cancelled["status"] == "cancelled"
      assert cancelled["deposit_due_cents"] == 0
      assert cancelled["deposit_paid_cents"] == 0
      assert cancelled["outstanding_deposit_cents"] == 0
      assert cancelled["lodging_total_cents"] == 0
      assert cancelled["rooms"] == expected_rooms("cancelled")

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

      assert_rejected_unchanged(conn, operation("cancel_group"), "group_not_active")
    end
  end

  test "cancelling an unpaid group still increments revision and forgives the deposit", %{
    conn: conn
  } do
    for plan <- ~w(flexible advance_purchase) do
      [_, result] =
        batch(conn, [
          open_operation(%{"group_id" => plan, "rate_plan" => plan}),
          operation("cancel_group", %{"group_id" => plan})
        ])

      assert result["revision"] == 2
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert group(conn, plan)["outstanding_deposit_cents"] == 0
    end

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cancellation uses the moved arrival and aggregates cash across properties", %{conn: conn} do
    batch(conn, [
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1_000}),
      operation("reschedule_group", %{"new_arrival_on" => "2026-10-10"}),
      operation("cancel_group"),
      open_operation(%{"group_id" => "refunded", "property_id" => "paris"}),
      operation("record_cash_payment", %{"group_id" => "refunded", "amount_cents" => 2_000}),
      operation("cancel_group", %{"group_id" => "refunded"}),
      open_operation(%{"group_id" => "active", "property_id" => "berlin"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 3_000})
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 3_000,
             "cash_refunded_cents" => 2_000,
             "cash_retained_cents" => 1_000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  defp expected_rooms(status) do
    Enum.map(open_operation()["rooms"], fn room ->
      lodging = room["nightly_rate_cents"] * 3

      Map.merge(room, %{
        "status" => status,
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => if(status == "active", do: div(lodging, 5), else: 0),
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  defp batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, group_id \\ "group-81") do
    conn
    |> get("/api/v1/groups/#{URI.encode(group_id, &URI.char_unreserved?/1)}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp assert_rejected_unchanged(conn, operation, code) do
    before = Repo.all(Group)
    ledger_before = ledger(conn)
    assert [%{"status" => "rejected", "code" => ^code} = result] = batch(conn, [operation])
    assert result["operation_id"] == operation["operation_id"]
    assert Repo.all(Group) == before
    assert ledger(conn) == ledger_before
    result
  end

  defp assert_stale(conn, operation, actual_revision) do
    result = assert_rejected_unchanged(conn, operation, "stale_revision")

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => operation["group_id"],
             "expected_revision" => operation["expected_revision"],
             "actual_revision" => actual_revision
           }
  end
end
