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
        "group_id" => "group-81",
        "occurred_on" => "2026-11-26"
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id \\ "group-81"),
    do: conn |> get(~p"/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn),
    do: conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  defp snapshot, do: Repo.all(Group) |> Enum.sort_by(& &1.group_id)

  defp assert_rejected(conn, operation, code) do
    # Exercise a new domain attempt; durable retry behavior has its own tests.
    operation =
      if is_map(operation) and is_binary(operation["operation_id"]) and
           operation["operation_id"] != "",
         do: Map.put(operation, "operation_id", "rejected-#{System.unique_integer([:positive])}"),
         else: operation

    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code}] = submit(conn, [operation])
    assert snapshot() == before
  end

  test "invalid batches and empty batches", %{conn: conn} do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, %{"operations" => "bad"}] do
      assert conn |> post(~p"/api/v1/partner-batches", body) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    assert submit(conn, []) == []

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

    assert conn |> get(~p"/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "opens and reads a group with identifiers and room order preserved", %{conn: conn} do
    assert submit(conn, [opening(%{"operation_id" => "open-1"})]) == [
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
             "outstanding_deposit_cents" => 19500
           }

    assert_rejected(conn, opening(), "group_already_exists")
    assert ledger(conn)["cash_held_cents"] == 0

    ids = %{
      "operation_id" => " Op Ω ",
      "group_id" => " Group Ω ",
      "guest_id" => " Guest Ω ",
      "property_id" => " Hotel Ω "
    }

    assert [%{"operation_id" => " Op Ω ", "group_id" => " Group Ω "}] =
             submit(conn, [opening(ids)])

    assert Map.take(group(conn, ids["group_id"]), ~w(group_id guest_id property_id)) ==
             Map.drop(ids, ["operation_id"])
  end

  test "rounds each room separately and charges advance purchase in full", %{conn: conn} do
    rooms =
      for {id, rate} <- [{"a", 3}, {"b", 3}, {"c", 2}],
          do: %{"room_id" => id, "nightly_rate_cents" => rate}

    for {plan, due} <- [{"flexible", 2}, {"advance_purchase", 8}] do
      assert [%{"deposit_due_cents" => ^due}] =
               submit(conn, [
                 opening(%{
                   "group_id" => plan,
                   "rate_plan" => plan,
                   "arrival_on" => "2028-02-28",
                   "departure_on" => "2028-02-29",
                   "rooms" => rooms
                 })
               ])

      assert group(conn, plan)["lodging_total_cents"] == 8
    end
  end

  test "opening rejects invalid stays, rooms, plans and missing fields without writes", %{
    conn: conn
  } do
    for fields <- [
          %{"arrival_on" => "bad"},
          %{"departure_on" => "2026-02-30"},
          %{"arrival_on" => nil},
          %{"departure_on" => "2026-12-10"},
          %{"departure_on" => "2026-12-09"}
        ] do
      assert_rejected(conn, opening(fields), "invalid_stay")
    end

    for rooms <- [
          [],
          nil,
          %{},
          [nil],
          [%{}],
          [%{"room_id" => "a", "nightly_rate_cents" => -1}],
          [%{"room_id" => "a", "nightly_rate_cents" => 1.5}],
          [%{"room_id" => "a", "nightly_rate_cents" => "100"}],
          [%{"room_id" => "", "nightly_rate_cents" => 100}],
          [
            %{"room_id" => "a", "nightly_rate_cents" => 1},
            %{"room_id" => "a", "nightly_rate_cents" => 2}
          ]
        ] do
      assert_rejected(conn, opening(%{"rooms" => rooms}), "invalid_rooms")
    end

    for plan <- [nil, "unknown", 3],
        do: assert_rejected(conn, opening(%{"rate_plan" => plan}), "invalid_rate_plan")

    for field <- Map.keys(opening()),
        do: assert_rejected(conn, Map.delete(opening(), field), "invalid_operation")

    for field <- ~w(operation_id group_id guest_id property_id), value <- [nil, "", 3] do
      assert_rejected(conn, opening(%{field => value}), "invalid_operation")
    end

    assert_rejected(conn, opening(%{"occurred_on" => "bad"}), "invalid_operation")
  end

  test "batch continues after invalid elements and domain rejections in array order", %{
    conn: conn
  } do
    results =
      submit(conn, [
        nil,
        1,
        [],
        "bad",
        %{},
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 20000}),
        operation("record_cash_payment", %{"amount_cents" => 5000}),
        operation("unknown"),
        operation("record_cash_payment", %{"amount_cents" => 14500})
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(rejected rejected rejected rejected rejected applied rejected applied rejected applied)

    assert Enum.map(Enum.take(results, 5), & &1["code"]) == List.duplicate("invalid_operation", 5)
    assert Enum.at(results, 7)["outstanding_deposit_cents"] == 14500
    assert List.last(results)["outstanding_deposit_cents"] == 0
    assert group(conn)["revision"] == 3
    assert group(conn)["deposit_paid_cents"] == 19500
    assert ledger(conn)["cash_held_cents"] == 19500
  end

  test "payments require positive integer cents and cannot exceed outstanding", %{conn: conn} do
    submit(conn, [opening()])

    for amount <- [nil, 0, -1, 1.0, "1", true, %{}] do
      assert_rejected(
        conn,
        operation("record_cash_payment", %{"amount_cents" => amount}),
        "invalid_amount"
      )
    end

    assert_rejected(conn, operation("record_cash_payment"), "invalid_operation")

    assert_rejected(
      conn,
      operation("record_cash_payment", %{"amount_cents" => 19501}),
      "payment_exceeds_outstanding"
    )

    assert [%{"amount_cents" => 19500, "outstanding_deposit_cents" => 0, "revision" => 2}] =
             submit(conn, [operation("record_cash_payment", %{"amount_cents" => 19500})])

    assert_rejected(
      conn,
      operation("record_cash_payment", %{"amount_cents" => 1}),
      "payment_exceeds_outstanding"
    )
  end

  test "missing groups resolve before revisions or domain rules", %{conn: conn} do
    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      assert_rejected(conn, operation(type, %{"expected_revision" => 99}), "group_not_found")
    end
  end

  test "revision checks see earlier operations and take precedence over domain validation", %{
    conn: conn
  } do
    results =
      submit(conn, [
        opening(%{"expected_revision" => 99}),
        operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
        operation("reschedule_group", %{
          "operation_id" => "reschedule_group",
          "new_arrival_on" => "bad",
          "expected_revision" => 1
        }),
        operation("reschedule_group", %{
          "new_arrival_on" => "2026-12-10",
          "expected_revision" => 2
        })
      ])

    assert Enum.map(results, & &1["revision"]) == [1, 2, nil, 3]

    assert Enum.at(results, 2) == %{
             "operation_id" => "reschedule_group",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group),
        revision <- [1, nil, "3", 3.0] do
      assert_rejected(conn, operation(type, %{"expected_revision" => revision}), "stale_revision")
    end

    assert [%{"revision" => 4}] =
             submit(conn, [operation("cancel_group", %{"expected_revision" => 3})])

    assert_rejected(
      conn,
      operation("cancel_group", %{"expected_revision" => 3}),
      "stale_revision"
    )

    assert_rejected(
      conn,
      operation("cancel_group", %{"expected_revision" => 4}),
      "group_not_active"
    )
  end

  test "reschedule preserves duration, prices and funding across month and leap boundaries", %{
    conn: conn
  } do
    submit(conn, [opening(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = group(conn)

    assert [
             %{
               "new_arrival_on" => "2028-02-28",
               "new_departure_on" => "2028-03-02",
               "revision" => 3
             }
           ] =
             submit(conn, [operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert Map.drop(group(conn), ~w(arrival_on departure_on revision refundable_until)) ==
             Map.drop(before, ~w(arrival_on departure_on revision refundable_until))

    assert [
             %{
               "new_arrival_on" => "2026-12-31",
               "new_departure_on" => "2027-01-03",
               "revision" => 4
             }
           ] =
             submit(conn, [operation("reschedule_group", %{"new_arrival_on" => "2026-12-31"})])

    for date <- [nil, "bad", "2027-02-29", "2026-11-26", "2026-11-25", "9999-12-31"] do
      assert_rejected(
        conn,
        operation("reschedule_group", %{"new_arrival_on" => date}),
        "invalid_stay"
      )
    end

    assert_rejected(conn, operation("reschedule_group"), "invalid_operation")
  end

  test "cancellation settles only paid cash at the fourteen day boundary", %{conn: conn} do
    cases = [
      {"early", "flexible", "2026-11-25", 1000, 1000, 0},
      {"boundary", "flexible", "2026-11-26", 2000, 2000, 0},
      {"late", "flexible", "2026-11-27", 3000, 0, 3000},
      {"advance", "advance_purchase", "2026-10-04", 4000, 0, 4000},
      {"unpaid", "flexible", "2026-11-27", 0, 0, 0}
    ]

    for {id, plan, date, paid, refunded, retained} <- cases do
      submit(conn, [opening(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0,
        do:
          submit(conn, [
            operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})
          ])

      assert [%{"refunded_cents" => ^refunded, "retained_cents" => ^retained}] =
               submit(conn, [
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => date})
               ])

      cancelled = group(conn, id)
      assert cancelled["status"] == "cancelled"
      assert cancelled["deposit_due_cents"] == 0
      assert cancelled["deposit_paid_cents"] == 0
      assert cancelled["outstanding_deposit_cents"] == 0
      assert cancelled["lodging_total_cents"] == 0
    end

    submit(conn, [opening(), operation("record_cash_payment", %{"amount_cents" => 500})])

    assert ledger(conn) == %{
             "cash_held_cents" => 500,
             "cash_refunded_cents" => 3000,
             "cash_retained_cents" => 7000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cancellation uses rescheduled arrival and later operations cannot change cancelled groups",
       %{conn: conn} do
    results =
      submit(conn, [
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 1000}),
        operation("reschedule_group", %{"new_arrival_on" => "2026-12-01"}),
        operation("cancel_group", %{"operation_id" => "cancel_group"})
      ])

    assert List.last(results) == %{
             "operation_id" => "cancel_group",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 0,
             "retained_cents" => 1000,
             "credit_issued_cents" => 0,
             "revision" => 4
           }

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
          operation("cancel_group")
        ] do
      assert_rejected(conn, op, "group_not_active")
    end

    assert_rejected(conn, opening(), "group_already_exists")
  end

  test "bad common data cannot mutate an existing group", %{conn: conn} do
    submit(conn, [opening()])

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      op = operation(type, %{"amount_cents" => 10, "new_arrival_on" => "2027-01-01"})

      for field <- ~w(operation_id type occurred_on group_id),
          do: assert_rejected(conn, Map.delete(op, field), "invalid_operation")

      assert_rejected(conn, Map.put(op, "occurred_on", "2026-02-30"), "invalid_operation")
    end
  end
end
