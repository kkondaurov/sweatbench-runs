defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "b", "nightly_rate_cents" => 15000},
          %{"room_id" => "a", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp operation(type, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => type,
        "type" => type,
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
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

  test "opening, funding, moving and settling are ordered and persisted" do
    assert [%{"deposit_due_cents" => 19500, "revision" => 1}] = batch([opening()])

    assert %{
             "rooms" => [%{"room_id" => "b"}, %{"room_id" => "a"}],
             "lodging_total_cents" => 97500,
             "booked_on" => "2026-10-03",
             "outstanding_deposit_cents" => 19500
           } = group()

    assert [
             %{"revision" => 2, "outstanding_deposit_cents" => 18500},
             %{"revision" => 3, "new_departure_on" => "2026-12-14"}
           ] =
             batch([
               operation("record_cash_payment", %{
                 "amount_cents" => 1000,
                 "expected_revision" => 1
               }),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2026-12-11",
                 "expected_revision" => 2
               })
             ])

    assert ledger()["cash_held_cents"] == 1000

    assert [%{"revision" => 4, "refunded_cents" => 1000, "retained_cents" => 0}] =
             batch([operation("cancel_group", %{"expected_revision" => 3})])

    assert %{
             "status" => "cancelled",
             "deposit_due_cents" => 0,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 0
           } = group()

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 1000,
             "cash_retained_cents" => 0
           }
  end

  test "revision conflicts precede domain validation and rejected operations have no effects" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = group()
    cash = ledger()

    assert [
             %{
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             },
             %{"code" => "stale_revision"},
             %{"code" => "stale_revision"},
             %{"code" => "group_not_found"}
           ] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 1}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "bad",
                 "expected_revision" => 1
               }),
               operation("cancel_group", %{"expected_revision" => 1}),
               operation("cancel_group", %{"group_id" => "missing", "expected_revision" => 1})
             ])

    assert group() == before
    assert ledger() == cash

    assert [%{"revision" => 3}, %{"code" => "stale_revision"}, %{"code" => "group_not_active"}] =
             batch([
               operation("cancel_group"),
               operation("cancel_group", %{"expected_revision" => 2}),
               operation("cancel_group", %{"expected_revision" => 3})
             ])
  end

  test "cancellation policy uses calendar boundary and only paid cash" do
    for {plan, date, refunded, retained} <- [
          {"flexible", "2026-11-26", 500, 0},
          {"flexible", "2026-11-27", 0, 500},
          {"advance_purchase", "2026-10-04", 0, 500}
        ] do
      id = plan <> date

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"refunded_cents" => ^refunded, "retained_cents" => ^retained}
             ] =
               batch([
                 opening(%{"group_id" => id, "rate_plan" => plan}),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 500}),
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => date})
               ])
    end

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 500,
             "cash_retained_cents" => 1000
           }
  end

  test "room deposits round independently and advance purchase requires full lodging" do
    rooms = for id <- ["one", "two"], do: %{"room_id" => id, "nightly_rate_cents" => 1}

    assert [%{"deposit_due_cents" => 2}, %{"deposit_due_cents" => 6}] =
             batch([
               opening(%{"rooms" => rooms}),
               opening(%{
                 "group_id" => "advance",
                 "rooms" => rooms,
                 "rate_plan" => "advance_purchase"
               })
             ])
  end

  test "invalid openings never create groups and batches continue after rejection" do
    for {override, code} <- [
          {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
          {%{"arrival_on" => "bad"}, "invalid_stay"},
          {%{"rooms" => []}, "invalid_rooms"},
          {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
          {%{
             "rooms" => [
               %{"room_id" => "a", "nightly_rate_cents" => 1},
               %{"room_id" => "a", "nightly_rate_cents" => 2}
             ]
           }, "invalid_rooms"},
          {%{"rate_plan" => "unknown"}, "invalid_rate_plan"}
        ] do
      assert [%{"code" => ^code}] = batch([opening(override)])

      assert build_conn() |> get("/api/v1/groups/group-81") |> json_response(404) ==
               %{"error" => %{"code" => "group_not_found"}}
    end

    assert [
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"revision" => 1},
             %{"code" => "group_already_exists"}
           ] =
             batch([nil, %{}, operation("unknown"), opening(), opening()])
  end

  test "payment and reschedule validation preserve state and allow subsequent operations" do
    batch([opening()])
    before = group()

    for amount <- [0, -1, 1.5, "100", nil] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])
    end

    assert [
             %{"code" => "payment_exceeds_outstanding"},
             %{"code" => "invalid_stay"},
             %{"code" => "invalid_operation"}
           ] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => 19501}),
               operation("reschedule_group", %{"new_arrival_on" => "2026-11-26"}),
               operation("record_cash_payment")
             ])

    assert group() == before

    assert [%{"revision" => 2, "outstanding_deposit_cents" => 0}, %{"revision" => 3}] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => 19500}),
               operation("cancel_group")
             ])

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"})
        ] do
      assert [%{"code" => "group_not_active"}] = batch([op])
    end
  end

  test "unpaid cancellation settles no cash and opening ignores expected revision" do
    assert [%{"revision" => 1}, %{"revision" => 2, "refunded_cents" => 0, "retained_cents" => 0}] =
             batch([opening(%{"expected_revision" => 99}), operation("cancel_group")])

    assert group()["outstanding_deposit_cents"] == 0

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "rescheduling to the existing arrival still increments revision" do
    batch([opening()])
    before = group()

    assert [%{"revision" => 2}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2026-12-10"})])

    assert group() == Map.put(before, "revision", 2)
  end

  test "batch envelope and empty ledger", %{conn: conn} do
    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert conn |> post("/api/v1/partner-batches", body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch([]) == []
  end
end
