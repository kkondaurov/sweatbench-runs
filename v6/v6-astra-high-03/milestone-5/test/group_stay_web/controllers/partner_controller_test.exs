defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Group, Repo}

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{System.unique_integer([:positive])}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp operation(type, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "#{type}-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id \\ "group-81") do
    conn |> get("/api/v1/groups/#{URI.encode(id)}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp snapshot do
    Repo.all(Group) |> Enum.sort_by(& &1.group_id)
  end

  test "batch envelope validation and empty reads", %{conn: conn} do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, %{"operations" => "bad"}] do
      assert conn |> post("/api/v1/partner-batches", body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    for body <- ["null", "[]", "123", "true", ~s("invalid")] do
      assert conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches", body)
             |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch(conn, []) == []

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

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

  test "opens and reads the complete group, preserving identifiers and room order", %{conn: conn} do
    assert batch(conn, [opening(%{"expected_revision" => 99, "operation_id" => "open-1"})]) == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
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
               Enum.map(opening()["rooms"], fn room ->
                 Map.merge(room, %{
                   "status" => "active",
                   "lodging_total_cents" => room["nightly_rate_cents"] * 3,
                   "deposit_due_cents" => div(room["nightly_rate_cents"] * 3, 5),
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 })
               end),
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }

    ids = %{
      "group_id" => " Group-É 001 ",
      "guest_id" => " Guest-001 ",
      "property_id" => " AMS ",
      "rooms" => [%{"room_id" => " Room-β ", "nightly_rate_cents" => 10}]
    }

    assert [%{"group_id" => " Group-É 001 ", "status" => "applied"}] = batch(conn, [opening(ids)])
    actual = Map.take(group(conn, ids["group_id"]), Map.keys(ids))

    assert Map.update!(actual, "rooms", fn rooms ->
             Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))
           end) == ids
  end

  test "prices each room separately using exact integer rounding", %{conn: conn} do
    rooms =
      for {id, rate} <- [{"a", 2}, {"b", 2}, {"c", 3}, {"d", 3}],
          do: %{"room_id" => id, "nightly_rate_cents" => rate}

    assert [%{"deposit_due_cents" => 2}] =
             batch(conn, [
               opening(%{
                 "rooms" => rooms,
                 "departure_on" => "2026-12-11"
               })
             ])

    assert group(conn)["lodging_total_cents"] == 10

    assert [%{"deposit_due_cents" => 97500}] =
             batch(conn, [
               opening(%{
                 "group_id" => "advance",
                 "rate_plan" => "advance_purchase"
               })
             ])

    # The two rooms each round down; rounding their combined lodging would yield one cent.
    assert [%{"deposit_due_cents" => 0}] =
             batch(conn, [
               opening(%{
                 "group_id" => "rounding",
                 "rooms" => Enum.take(rooms, 2),
                 "departure_on" => "2026-12-11"
               })
             ])
  end

  test "opening domain failures leave domain state unchanged", %{conn: conn} do
    cases = [
      {%{"arrival_on" => "invalid"}, "invalid_stay"},
      {%{"arrival_on" => nil}, "invalid_stay"},
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"departure_on" => "2026-02-30"}, "invalid_stay"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"rate_plan" => nil}, "invalid_rate_plan"}
    ]

    invalid_rooms = [
      nil,
      [],
      %{},
      [nil],
      [%{}],
      [%{"room_id" => "a", "nightly_rate_cents" => -1}],
      [%{"room_id" => "a", "nightly_rate_cents" => 1.5}],
      [%{"room_id" => "a", "nightly_rate_cents" => "100"}],
      [%{"room_id" => "", "nightly_rate_cents" => 100}],
      [%{"room_id" => 12, "nightly_rate_cents" => 100}],
      [%{"room_id" => "a", "nightly_rate_cents" => 9_223_372_036_854_775_807}],
      [
        %{"room_id" => "a", "nightly_rate_cents" => 1},
        %{"room_id" => "a", "nightly_rate_cents" => 2}
      ]
    ]

    for {changes, code} <- cases ++ Enum.map(invalid_rooms, &{%{"rooms" => &1}, "invalid_rooms"}) do
      before = snapshot()
      assert [%{"status" => "rejected", "code" => ^code}] = batch(conn, [opening(changes)])
      assert snapshot() == before
    end
  end

  test "duplicate opening cannot replace an existing group", %{conn: conn} do
    batch(conn, [opening()])
    before = snapshot()

    assert [%{"code" => "group_already_exists"}] =
             batch(conn, [opening(%{"guest_id" => "other"})])

    assert snapshot() == before
  end

  test "malformed operations reject individually and later operations still run", %{conn: conn} do
    invalid =
      [
        nil,
        42,
        [],
        "bad",
        %{},
        operation("unknown"),
        Map.delete(opening(), "operation_id"),
        Map.delete(opening(), "occurred_on"),
        opening(%{"occurred_on" => "2026-02-30"}),
        opening(%{"group_id" => 5})
      ] ++
        Enum.map(
          ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
          &Map.delete(opening(), &1)
        )

    results = batch(conn, invalid ++ [opening()])
    assert length(results) == length(invalid) + 1
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"
    before = snapshot()

    for op <- [operation("record_cash_payment"), operation("reschedule_group")] do
      assert [%{"code" => "invalid_operation"}] = batch(conn, [op])
      assert snapshot() == before
    end
  end

  test "ordered payments see prior changes and failures neither undo nor stop the batch", %{
    conn: conn
  } do
    results =
      batch(conn, [
        opening(),
        operation("record_cash_payment", %{
          "operation_id" => "record_cash_payment-1",
          "amount_cents" => 5000,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{"amount_cents" => 14501}),
        operation("record_cash_payment", %{"amount_cents" => 14500, "expected_revision" => 2})
      ])

    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "rejected", "applied"]

    assert Enum.at(results, 1) == %{
             "operation_id" => "record_cash_payment-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5000,
             "outstanding_deposit_cents" => 14500,
             "revision" => 2
           }

    assert Enum.at(results, 2)["code"] == "payment_exceeds_outstanding"
    assert List.last(results)["revision"] == 3
    assert group(conn)["outstanding_deposit_cents"] == 0
    assert group(conn)["deposit_paid_cents"] == 19500
    assert ledger(conn)["cash_held_cents"] == 19500
  end

  test "invalid payments are atomic", %{conn: conn} do
    batch(conn, [opening()])

    for amount <- [0, -1, 1.0, "1", nil, true, [], %{}] do
      before = snapshot()

      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [operation("record_cash_payment", %{"amount_cents" => amount})])

      assert snapshot() == before
    end
  end

  test "group existence precedes revision comparison for every update", %{conn: conn} do
    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch(conn, [operation(type, %{"expected_revision" => 99})])
    end
  end

  test "stale revisions precede all other update domain validation and leave accounting unchanged",
       %{conn: conn} do
    batch(conn, [opening(), operation("record_cash_payment", %{"amount_cents" => 100})])

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group),
        expected <- [1, 3, nil, "2", 2.0] do
      before = snapshot()

      assert batch(conn, [
               operation(type, %{
                 "operation_id" => "#{type}-#{inspect(expected)}",
                 "expected_revision" => expected,
                 "amount_cents" => -1,
                 "new_arrival_on" => "bad"
               })
             ]) == [
               %{
                 "operation_id" => "#{type}-#{inspect(expected)}",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => expected,
                 "actual_revision" => 2
               }
             ]

      assert snapshot() == before
    end

    batch(conn, [operation("cancel_group", %{"expected_revision" => 2})])
    before = snapshot()

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
               batch(conn, [operation(type, %{"expected_revision" => 2})])

      assert snapshot() == before
    end
  end

  test "rescheduling preserves duration, prices, funding and booked date across leap days", %{
    conn: conn
  } do
    batch(conn, [opening(), operation("record_cash_payment", %{"amount_cents" => 1000})])
    before = group(conn)

    assert [
             %{
               "new_arrival_on" => "2028-02-28",
               "new_departure_on" => "2028-03-02",
               "revision" => 3
             }
           ] =
             batch(conn, [
               operation("reschedule_group", %{
                 "new_arrival_on" => "2028-02-28",
                 "expected_revision" => 2
               })
             ])

    assert Map.drop(group(conn), ~w(arrival_on departure_on revision refundable_until)) ==
             Map.drop(before, ~w(arrival_on departure_on revision refundable_until))

    assert ledger(conn)["cash_held_cents"] == 1000

    assert [%{"revision" => 4}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert [%{"new_departure_on" => "2027-01-02", "revision" => 5}] =
             batch(conn, [operation("reschedule_group", %{"new_arrival_on" => "2026-12-30"})])
  end

  test "invalid reschedules do not change the reservation", %{conn: conn} do
    batch(conn, [opening()])

    for date <- [nil, 42, "bad", "2026-02-29", "2026-11-26", "2026-11-25", "9999-12-31"] do
      before = snapshot()

      assert [%{"code" => "invalid_stay"}] =
               batch(conn, [operation("reschedule_group", %{"new_arrival_on" => date})])

      assert snapshot() == before
    end
  end

  test "cancellation settles only paid cash at the exact 14-day boundary", %{conn: conn} do
    for {id, plan, date, refunded, retained} <- [
          {"early", "flexible", "2026-11-25", 1000, 0},
          {"boundary", "flexible", "2026-11-26", 1000, 0},
          {"late", "flexible", "2026-11-27", 0, 1000},
          {"advance", "advance_purchase", "2026-10-04", 0, 1000},
          {"after", "flexible", "2026-12-11", 0, 1000}
        ] do
      batch(conn, [
        opening(%{"group_id" => id, "rate_plan" => plan}),
        operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 1000})
      ])

      assert [%{"refunded_cents" => ^refunded, "retained_cents" => ^retained, "revision" => 3}] =
               batch(conn, [
                 operation("cancel_group", %{
                   "group_id" => id,
                   "occurred_on" => date,
                   "expected_revision" => 2
                 })
               ])

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0,
               "lodging_total_cents" => 0
             } = group(conn, id)
    end

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 2000,
             "cash_retained_cents" => 3000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "unfunded cancellation adds no cash and cancelled groups reject all subsequent updates", %{
    conn: conn
  } do
    assert [_, %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}] =
             batch(conn, [opening(), operation("cancel_group")])

    before = snapshot()

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert [%{"code" => "group_not_active"}] =
               batch(conn, [
                 operation(type, %{
                   "expected_revision" => 2,
                   "amount_cents" => 100,
                   "new_arrival_on" => "2027-01-01"
                 })
               ])

      assert snapshot() == before
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

  test "cancellation uses rescheduled arrival and ledger totals aggregate active and settled groups",
       %{conn: conn} do
    batch(conn, [
      opening(),
      operation("record_cash_payment", %{"amount_cents" => 2000}),
      operation("reschedule_group", %{"new_arrival_on" => "2026-12-30"}),
      operation("cancel_group", %{"occurred_on" => "2026-12-10"}),
      opening(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 3000})
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 3000,
             "cash_refunded_cents" => 2000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "group and revision resolution precede unusable operation dates", %{conn: conn} do
    batch(conn, [opening()])

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      op = operation(type, %{"occurred_on" => "bad", "expected_revision" => 99})
      before = snapshot()
      assert [%{"code" => "stale_revision", "actual_revision" => 1}] = batch(conn, [op])

      assert [%{"code" => "group_not_found"}] =
               batch(conn, [
                 Map.merge(op, %{"group_id" => "missing", "operation_id" => "missing-#{type}"})
               ])

      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [
                 Map.merge(op, %{
                   "operation_id" => "invalid-date-#{type}",
                   "expected_revision" => 1,
                   "amount_cents" => 1,
                   "new_arrival_on" => "2027-01-01"
                 })
               ])

      assert snapshot() == before
    end
  end
end
