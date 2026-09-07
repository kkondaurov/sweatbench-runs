defmodule GroupStayWeb.PartnerAPITest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.Group

  test "empty batches and missing read resources", %{conn: conn} do
    assert batch(conn, []) == []

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }

    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, []] do
      assert conn |> json_post(body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  test "opens a group and returns its complete public representation", %{conn: conn} do
    opening = open_operation(%{"operation_id" => "open-1", "expected_revision" => 900})

    assert batch(conn, [opening]) == [
             %{
               "operation_id" => "open-1",
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
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "status" => "active",
             "revision" => 1,
             "rooms" =>
               Enum.map(opening["rooms"], fn room ->
                 Map.merge(room, %{
                   "status" => "active",
                   "lodging_total_cents" => room["nightly_rate_cents"] * 3,
                   "deposit_due_cents" => div(room["nightly_rate_cents"] * 3, 5),
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 })
               end),
             "lodging_total_cents" => 97_500,
             "deposit_due_cents" => 19_500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_500
           }
  end

  test "prices each room separately using integer rounding and supports advance purchase", %{
    conn: conn
  } do
    rooms = for id <- ["z", "a"], do: %{"room_id" => id, "nightly_rate_cents" => 3}

    batch(conn, [
      open_operation(%{"rooms" => rooms, "departure_on" => "2026-12-11"}),
      open_operation(%{"group_id" => "advance", "rate_plan" => "advance_purchase"})
    ])

    assert group(conn)["deposit_due_cents"] == 2
    assert group(conn)["lodging_total_cents"] == 6
    assert group(conn, "advance")["deposit_due_cents"] == 97_500

    batch(conn, [
      open_operation(%{
        "group_id" => "round-down",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 2}]
      })
    ])

    assert group(conn, "round-down")["deposit_due_cents"] == 0
  end

  test "partner identifiers remain unchanged", %{conn: conn} do
    id = "Grüp 001"

    assert [%{"operation_id" => " Op-é ", "group_id" => ^id}] =
             batch(conn, [
               open_operation(%{
                 "group_id" => id,
                 "operation_id" => " Op-é ",
                 "guest_id" => " Guest 01 ",
                 "property_id" => "Property_A"
               })
             ])

    assert group(conn, URI.encode(id))["guest_id"] == " Guest 01 "
    assert group(conn, URI.encode(id))["property_id"] == "Property_A"
  end

  test "invalid openings leave no group and do not prevent a following valid opening", %{
    conn: conn
  } do
    invalid = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"arrival_on" => "2026-02-30"}, "invalid_stay"},
      {%{"arrival_on" => nil}, "invalid_stay"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => [42]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r"}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "", "nightly_rate_cents" => 100}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => "100"}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 9_223_372_036_854_775_807}]},
       "invalid_rooms"},
      {%{
         "rooms" => [
           %{"room_id" => "r", "nightly_rate_cents" => 100},
           %{"room_id" => "r", "nightly_rate_cents" => 200}
         ]
       }, "invalid_rooms"}
    ]

    for {overrides, code} <- invalid do
      assert [%{"status" => "rejected", "code" => ^code}] =
               batch(conn, [open_operation(overrides)])

      assert Repo.all(Group) == []
    end

    assert [%{"status" => "applied"}, %{"code" => "group_already_exists"}] =
             batch(conn, [open_operation(), open_operation()])

    assert group(conn)["revision"] == 1
  end

  test "malformed operations reject individually and processing continues", %{conn: conn} do
    invalid = [
      nil,
      [],
      "open_group",
      42,
      %{},
      operation("unknown"),
      Map.delete(open_operation(), "operation_id"),
      Map.delete(open_operation(), "group_id"),
      Map.delete(open_operation(), "guest_id"),
      Map.delete(open_operation(), "rooms"),
      open_operation(%{"property_id" => 1}),
      open_operation(%{"occurred_on" => "bad-date"})
    ]

    results = batch(conn, invalid ++ [open_operation()])
    assert length(results) == length(invalid) + 1
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"

    assert [%{"code" => "invalid_operation"}, %{"code" => "invalid_operation"}] =
             batch(conn, [operation("record_cash_payment"), operation("reschedule_group")])

    assert group(conn)["revision"] == 1
  end

  test "payments use the current outstanding balance in array order", %{conn: conn} do
    assert [
             %{"revision" => 1},
             %{
               "revision" => 2,
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 19_000
             },
             %{"code" => "payment_exceeds_outstanding"},
             %{"revision" => 3, "outstanding_deposit_cents" => 0},
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             batch(conn, [
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 500}),
               operation("record_cash_payment", %{"amount_cents" => 19_001}),
               operation("record_cash_payment", %{"amount_cents" => 19_000}),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    assert group(conn)["deposit_paid_cents"] == 19_500
    assert group(conn)["revision"] == 3
    assert ledger(conn)["cash_held_cents"] == 19_500
  end

  test "invalid payments preserve every persisted field", %{conn: conn} do
    batch(conn, [open_operation(), operation("record_cash_payment", %{"amount_cents" => 50})])
    before = Repo.all(Group)

    for amount <- [nil, false, "100", 0, -1, 1.5, %{}, []] do
      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [operation("record_cash_payment", %{"amount_cents" => amount})])

      assert Repo.all(Group) == before
    end
  end

  test "rescheduling shifts departure across calendar boundaries without repricing", %{conn: conn} do
    batch(conn, [open_operation(), operation("record_cash_payment", %{"amount_cents" => 500})])
    before = group(conn)

    assert [
             %{
               "new_arrival_on" => "2028-02-28",
               "new_departure_on" => "2028-03-02",
               "revision" => 3
             }
           ] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert group(conn) ==
             Map.merge(before, %{
               "arrival_on" => "2028-02-28",
               "refundable_until" => "2028-02-14",
               "departure_on" => "2028-03-02",
               "revision" => 3
             })

    assert [%{"revision" => 4}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    for arrival <- ["2026-10-04", "2026-10-03", "2026-02-30", nil, 20_270_101, "9999-12-31"] do
      before = Repo.all(Group)

      assert [%{"code" => "invalid_stay"}] =
               batch(conn, [operation("reschedule_group", %{"new_arrival_on" => arrival})])

      assert Repo.all(Group) == before
    end

    assert ledger(conn)["cash_held_cents"] == 500
  end

  test "cancellation settles only paid cash and clears unpaid deposit", %{conn: conn} do
    scenarios = [
      {"boundary", "flexible", "2026-11-26", 500, 500, 0},
      {"early", "flexible", "2026-11-25", 600, 600, 0},
      {"late", "flexible", "2026-11-27", 700, 0, 700},
      {"advance", "advance_purchase", "2026-10-04", 800, 0, 800},
      {"unpaid", "advance_purchase", "2026-10-04", 0, 0, 0}
    ]

    for {id, plan, occurred_on, paid, refunded, retained} <- scenarios do
      batch(conn, [open_operation(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0 do
        batch(conn, [
          operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})
        ])
      end

      revision = if paid > 0, do: 3, else: 2

      assert [
               %{
                 "status" => "applied",
                 "group_id" => ^id,
                 "refunded_cents" => ^refunded,
                 "retained_cents" => ^retained,
                 "revision" => ^revision
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
      assert cancelled["lodging_total_cents"] == 0

      before = Repo.all(Group)

      for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
        assert [%{"code" => "group_not_active"}] =
                 batch(conn, [operation(type, %{"group_id" => id})])

        assert Repo.all(Group) == before
      end
    end

    batch(conn, [
      open_operation(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 900})
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 900,
             "cash_refunded_cents" => 1_100,
             "cash_retained_cents" => 1_500,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cancellation uses the rescheduled arrival", %{conn: conn} do
    assert [_, _, _, %{"refunded_cents" => 500, "retained_cents" => 0, "revision" => 4}] =
             batch(conn, [
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 500}),
               operation("reschedule_group", %{"new_arrival_on" => "2027-01-10"}),
               operation("cancel_group", %{"occurred_on" => "2026-12-01"})
             ])
  end

  test "revisions follow each successful operation within a batch", %{conn: conn} do
    assert [
             %{"revision" => 1},
             %{"revision" => 2},
             %{
               "operation_id" => "reschedule_group-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             },
             %{"revision" => 3},
             %{"revision" => 4}
           ] =
             batch(conn, [
               open_operation(),
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("reschedule_group", %{
                 "operation_id" => "reschedule_group-1",
                 "new_arrival_on" => "bad",
                 "expected_revision" => 1
               }),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-10",
                 "expected_revision" => 2
               }),
               operation("cancel_group", %{"expected_revision" => 3})
             ])

    assert group(conn)["revision"] == 4
    assert ledger(conn)["cash_refunded_cents"] == 100
  end

  test "existence precedes revision and stale revisions precede other domain validation", %{
    conn: conn
  } do
    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch(conn, [operation(type, %{"expected_revision" => 999})])
    end

    batch(conn, [open_operation()])
    before = Repo.all(Group)

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group),
        revision <- [0, 2, nil, "1", 1.0, false] do
      assert [
               %{
                 "code" => "stale_revision",
                 "actual_revision" => 1,
                 "expected_revision" => ^revision
               }
             ] =
               batch(conn, [operation(type, %{"expected_revision" => revision})])

      assert Repo.all(Group) == before
    end

    batch(conn, [operation("cancel_group")])
    before = Repo.all(Group)

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch(conn, [operation(type, %{"expected_revision" => 1})])

      assert [%{"code" => "group_not_active"}] =
               batch(conn, [operation(type, %{"expected_revision" => 2})])

      assert Repo.all(Group) == before
    end
  end

  test "reads reflect persisted records rather than process state", %{conn: conn} do
    batch(conn, [open_operation(), operation("record_cash_payment", %{"amount_cents" => 123})])
    persisted = Repo.get!(Group, "group-81")
    assert persisted.deposit_paid_cents == 123
    assert persisted.revision == 2
    assert Reservations.get_group("group-81") == persisted
  end

  test "revision checks precede operation date validation", %{conn: conn} do
    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch(conn, [operation(type, %{"occurred_on" => nil, "expected_revision" => 99})])
    end

    batch(conn, [open_operation()])
    before = Repo.all(Group)

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "stale_revision", "actual_revision" => 1}] =
               batch(conn, [operation(type, %{"occurred_on" => nil, "expected_revision" => 99})])

      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [operation(type, %{"occurred_on" => nil, "expected_revision" => 1})])

      assert Repo.all(Group) == before
    end
  end

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp batch(conn, operations) do
    conn |> json_post(%{operations: operations}) |> json_response(200) |> Map.fetch!("results")
  end

  defp group(conn, id \\ "group-81") do
    conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end
end
