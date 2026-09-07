defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp open(overrides \\ %{}) do
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
        "operation_id" => "#{type}-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => "group-81",
        "occurred_on" => "2026-11-26"
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

  test "batch and read endpoint envelopes" do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert build_conn() |> post("/api/v1/partner-batches", body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch([]) == []

    assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "opens the documented booking and preserves identifiers and room order" do
    assert [%{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19500}] =
             batch([open()])

    assert group() == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "revision" => 1,
             "rooms" => open()["rooms"],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }

    assert [%{"code" => "group_already_exists"}] = batch([open()])
    assert group()["revision"] == 1
  end

  test "per-room rounding, full advance deposit, and zero rate" do
    rooms = for id <- ["a", "b"], do: %{"room_id" => id, "nightly_rate_cents" => 3}

    assert [%{"deposit_due_cents" => 2}, %{"deposit_due_cents" => 6}, %{"deposit_due_cents" => 0}] =
             batch([
               open(%{"departure_on" => "2026-12-11", "rooms" => rooms}),
               open(%{
                 "group_id" => "advance",
                 "departure_on" => "2026-12-11",
                 "rooms" => rooms,
                 "rate_plan" => "advance_purchase"
               }),
               open(%{
                 "group_id" => "free",
                 "rooms" => [%{"room_id" => "free", "nightly_rate_cents" => 0}]
               })
             ])
  end

  test "invalid openings never write and later operations continue" do
    invalid = [
      {%{"arrival_on" => "bad"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{"rooms" => [hd(open()["rooms"]), hd(open()["rooms"])]}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"}
    ]

    for {attrs, code} <- invalid do
      assert [%{"code" => ^code}] = batch([open(attrs)])
      assert GroupStay.Reservations.get_group("group-81") == nil
    end

    assert [
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"code" => "invalid_operation"},
             %{"status" => "applied"}
           ] =
             batch([nil, %{}, Map.delete(open(), "guest_id"), open()])
  end

  test "ordered payments enforce revision before domain rules and preserve state on rejection" do
    batch([open()])

    [paid, stale, invalid, overpaid, paid_again] =
      batch([
        operation("record_cash_payment", %{"amount_cents" => 5000, "expected_revision" => 1}),
        operation("record_cash_payment", %{
          "operation_id" => "stale",
          "amount_cents" => -1,
          "expected_revision" => 1
        }),
        operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 2}),
        operation("record_cash_payment", %{"amount_cents" => 14501}),
        operation("record_cash_payment", %{"amount_cents" => 14500, "expected_revision" => 2})
      ])

    assert paid["revision"] == 2
    assert paid["outstanding_deposit_cents"] == 14500

    assert stale == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert invalid["code"] == "invalid_amount"
    assert overpaid["code"] == "payment_exceeds_outstanding"
    assert paid_again["revision"] == 3
    assert paid_again["outstanding_deposit_cents"] == 0
    assert ledger()["cash_held_cents"] == 19500
    before = group()

    for amount <- [0, -1, 1.5, "1", nil] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])
    end

    assert group() == before
  end

  test "rescheduling preserves price and duration across calendar boundaries" do
    batch([open()])

    assert [
             %{
               "revision" => 2,
               "new_arrival_on" => "2028-02-28",
               "new_departure_on" => "2028-03-02"
             }
           ] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "2028-02-28",
                 "expected_revision" => 1
               })
             ])

    assert group()["deposit_due_cents"] == 19500
    before = group()

    for date <- ["bad", "2026-11-26", "2026-11-25", nil] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => date})])
    end

    assert [%{"code" => "stale_revision"}] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "bad",
                 "expected_revision" => 1
               })
             ])

    assert group() == before
  end

  test "cancellation settlement boundaries and cumulative finance totals" do
    scenarios = [
      {"early", "flexible", "2026-11-25", 100, 0},
      {"boundary", "flexible", "2026-11-26", 100, 0},
      {"late", "flexible", "2026-11-27", 0, 100},
      {"advance", "advance_purchase", "2026-10-03", 0, 100}
    ]

    for {id, plan, day, refunded, retained} <- scenarios do
      assert [
               _,
               _,
               %{"revision" => 3, "refunded_cents" => ^refunded, "retained_cents" => ^retained}
             ] =
               batch([
                 open(%{"group_id" => id, "rate_plan" => plan}),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 100}),
                 operation("cancel_group", %{
                   "group_id" => id,
                   "occurred_on" => day,
                   "expected_revision" => 2
                 })
               ])

      stored = GroupStay.Reservations.get_group(id)
      assert stored.status == "cancelled"
      assert stored.deposit_due_cents == 0
      assert stored.deposit_paid_cents == 0
    end

    batch([open(), operation("record_cash_payment", %{"amount_cents" => 50})])

    assert ledger() == %{
             "cash_held_cents" => 50,
             "cash_refunded_cents" => 200,
             "cash_retained_cents" => 200,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "missing group wins over revision; stale revision wins over inactive and invalid domain data" do
    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, %{"expected_revision" => 99})])
    end

    batch([open(), operation("cancel_group")])
    before = group()

    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch([operation(type, %{"expected_revision" => 1})])

      assert [%{"code" => "group_not_active"}] =
               batch([operation(type, %{"expected_revision" => 2})])
    end

    assert group() == before
    assert ledger()["cash_held_cents"] == 0
  end

  test "cancellation uses the moved arrival and rejects stale cancellations without accounting changes" do
    batch([
      open(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("reschedule_group", %{"new_arrival_on" => "2026-12-01"})
    ])

    before = {group(), ledger()}

    assert [%{"code" => "stale_revision"}] =
             batch([operation("cancel_group", %{"expected_revision" => 2})])

    assert {group(), ledger()} == before

    assert [%{"retained_cents" => 100, "refunded_cents" => 0, "revision" => 4}] =
             batch([operation("cancel_group", %{"expected_revision" => 3})])
  end

  test "malformed operations reject independently and opening ignores expected_revision" do
    malformed = [
      42,
      "payment",
      [],
      %{},
      Map.delete(open(), "operation_id"),
      Map.delete(open(), "occurred_on"),
      open(%{"occurred_on" => "invalid"}),
      open(%{"group_id" => nil}),
      open(%{"type" => "unknown"})
    ]

    for result <- batch(malformed) do
      assert result["code"] == "invalid_operation"
    end

    assert [%{"revision" => 1}] = batch([open(%{"expected_revision" => 99})])
    before = {group(), ledger()}

    for type <- ~w(record_cash_payment reschedule_group) do
      assert [%{"code" => "invalid_operation"}] = batch([operation(type)])
    end

    assert {group(), ledger()} == before

    assert [%{"revision" => 2}] =
             batch([
               operation("reschedule_group", %{"new_arrival_on" => "2026-12-10"})
             ])
  end
end
