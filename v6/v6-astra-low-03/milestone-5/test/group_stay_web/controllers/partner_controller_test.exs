defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  # Each domain scenario is a new gateway operation; retries have dedicated tests.
  defp next_id(prefix) do
    count = Process.get({:operation_sequence, prefix}, 0)
    Process.put({:operation_sequence, prefix}, count + 1)
    if count == 0, do: prefix, else: "#{prefix}-#{count}"
  end

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id("open-1"),
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

  defp operation(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(type),
        "type" => type,
        "group_id" => "group-81",
        "occurred_on" => "2026-11-01"
      },
      attrs
    )
  end

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group do
    build_conn() |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger do
    build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  test "batch shape and missing reads", %{conn: conn} do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert conn |> post("/api/v1/partner-batches", body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch([]) == []

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "opening preserves identifiers and room order and computes totals" do
    assert [result] = batch([opening(%{"expected_revision" => 99})])

    assert result == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19500,
             "revision" => 1
           }

    assert group() == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
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
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "outstanding_deposit_cents" => 19500
           }
  end

  test "deposits round per room and advance purchase requires full lodging" do
    rooms = for id <- ["a", "b"], do: %{"room_id" => id, "nightly_rate_cents" => 1}

    [flex, advance] =
      batch([
        opening(%{"rooms" => rooms}),
        opening(%{"group_id" => "advance", "rate_plan" => "advance_purchase", "rooms" => rooms})
      ])

    assert flex["deposit_due_cents"] == 2
    assert advance["deposit_due_cents"] == 6
  end

  test "invalid openings leave no group and later operations continue" do
    bad = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"arrival_on" => "not-a-date"}, "invalid_stay"},
      {%{"departure_on" => nil}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => List.duplicate(hd(opening()["rooms"]), 2)}, "invalid_rooms"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"}
    ]

    results = batch(Enum.map(bad, fn {attrs, _} -> opening(attrs) end) ++ [opening(), opening()])
    assert Enum.map(Enum.take(results, length(bad)), & &1["code"]) == Enum.map(bad, &elem(&1, 1))
    assert Enum.at(results, -2)["status"] == "applied"
    assert List.last(results)["code"] == "group_already_exists"
    assert group()["revision"] == 1
  end

  test "malformed operations are isolated" do
    invalid = [
      nil,
      4,
      [],
      %{},
      operation("unknown"),
      Map.delete(opening(), "rooms"),
      Map.delete(opening(), "operation_id"),
      opening(%{"guest_id" => nil})
    ]

    results = batch(invalid ++ [opening()])
    assert Enum.all?(Enum.take(results, length(invalid)), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"
    assert hd(results)["operation_id"] == nil
  end

  test "payments validate amounts and outstanding and increment once per application" do
    batch([opening()])
    before = group()

    for amount <- [0, -1, 1.5, "100", nil, true, 19501] do
      [result] = batch([operation("record_cash_payment", %{"amount_cents" => amount})])

      assert result["code"] ==
               if(amount == 19501, do: "payment_exceeds_outstanding", else: "invalid_amount")

      assert group() == before
      assert ledger()["cash_held_cents"] == 0
    end

    [first, second] =
      batch([
        operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1}),
        operation("record_cash_payment", %{"amount_cents" => 19000, "expected_revision" => 2})
      ])

    assert first["revision"] == 2
    assert first["amount_cents"] == 500
    assert first["outstanding_deposit_cents"] == 19000
    assert second["revision"] == 3
    assert second["outstanding_deposit_cents"] == 0
    assert group()["deposit_paid_cents"] == 19500
    assert ledger()["cash_held_cents"] == 19500
  end

  test "rescheduling preserves stay length, money and booking date across leap day" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = group()

    [result] =
      batch([
        operation("reschedule_group", %{
          "new_arrival_on" => "2028-02-28",
          "expected_revision" => 2
        })
      ])

    assert result["new_departure_on"] == "2028-03-02"
    assert result["new_arrival_on"] == "2028-02-28"
    assert result["revision"] == 3

    assert Map.drop(group(), ~w(arrival_on departure_on revision refundable_until)) ==
             Map.drop(before, ~w(arrival_on departure_on revision refundable_until))

    for arrival <- ["2026-11-01", "2026-10-31", "bad", nil, 123] do
      snapshot = group()
      assert [result] = batch([operation("reschedule_group", %{"new_arrival_on" => arrival})])
      assert result["code"] == "invalid_stay"
      assert group() == snapshot
    end
  end

  test "cancellation boundary and rate plan determine settlement, including unpaid groups" do
    scenarios = [
      {"flexible", "2026-11-26", 700, 700, 0},
      {"flexible", "2026-11-27", 700, 0, 700},
      {"advance_purchase", "2026-11-01", 700, 0, 700},
      {"flexible", "2026-11-01", 0, 0, 0}
    ]

    for {{plan, date, paid, refund, retain}, index} <- Enum.with_index(scenarios) do
      id = "group-#{index}"
      batch([opening(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0,
        do: batch([operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})])

      [result] = batch([operation("cancel_group", %{"group_id" => id, "occurred_on" => date})])
      assert result["refunded_cents"] == refund
      assert result["retained_cents"] == retain
      assert result["revision"] == if(paid > 0, do: 3, else: 2)

      data =
        build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

      assert data["status"] == "cancelled"
      assert data["outstanding_deposit_cents"] == 0
    end

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_refunded_cents" => 700,
             "cash_retained_cents" => 1400
           }
  end

  test "cancellation uses rescheduled arrival and inactive groups reject further operations" do
    results =
      batch([
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 500}),
        operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
        operation("cancel_group", %{"occurred_on" => "2026-12-10", "expected_revision" => 3})
      ])

    assert List.last(results)["refunded_cents"] == 500
    snapshot = group()
    money = ledger()

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-02-01"}),
          operation("cancel_group")
        ] do
      assert [result] = batch([op])
      assert result["code"] == "group_not_active"
      assert group() == snapshot
      assert ledger() == money
    end
  end

  test "existence and stale revisions precede other validation and rejections preserve all state" do
    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      [missing] = batch([operation(type, %{"expected_revision" => 99})])
      assert missing["code"] == "group_not_found"
    end

    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])

    for type <- ~w(record_cash_payment reschedule_group cancel_group),
        revision <- [1, 3, nil, "2", 2.0] do
      snapshot = group()
      money = ledger()
      op = operation(type, %{"expected_revision" => revision})
      [result] = batch([op])

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => revision,
               "actual_revision" => 2
             }

      assert group() == snapshot
      assert ledger() == money
    end

    batch([operation("cancel_group")])
    [stale] = batch([operation("cancel_group", %{"expected_revision" => 2})])
    assert stale["code"] == "stale_revision"
    assert group()["revision"] == 3
  end

  test "later batch operations observe successes but not rejected changes" do
    results =
      batch([
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
        operation("cancel_group", %{"expected_revision" => 1}),
        operation("record_cash_payment", %{"amount_cents" => 100_000, "expected_revision" => 2}),
        operation("reschedule_group", %{
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        }),
        operation("cancel_group", %{"expected_revision" => 3})
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied rejected rejected applied applied)

    assert group()["revision"] == 4
    assert ledger()["cash_refunded_cents"] == 100
  end
end
