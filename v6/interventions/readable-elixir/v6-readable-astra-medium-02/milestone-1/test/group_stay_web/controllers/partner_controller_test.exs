defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
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
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group do
    build_conn() |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger do
    build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp snapshot, do: {GroupStay.Repo.all(GroupStay.Reservations.Group), ledger()}

  test "opens, funds, reschedules and settles a reservation in batch order" do
    assert [
             %{"status" => "applied", "deposit_due_cents" => 19500, "revision" => 1},
             %{
               "status" => "applied",
               "amount_cents" => 10000,
               "outstanding_deposit_cents" => 9500,
               "revision" => 2
             },
             %{
               "status" => "applied",
               "new_arrival_on" => "2027-01-01",
               "new_departure_on" => "2027-01-04",
               "revision" => 3
             }
           ] =
             batch([
               opening(),
               operation("record_cash_payment", %{
                 "amount_cents" => 10000,
                 "expected_revision" => 1
               }),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 2
               })
             ])

    assert group() == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2027-01-01",
             "departure_on" => "2027-01-04",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 3,
             "rooms" => opening()["rooms"],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 10000,
             "outstanding_deposit_cents" => 9500
           }

    assert ledger() == %{
             "cash_held_cents" => 10000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    assert [%{"refunded_cents" => 10000, "retained_cents" => 0, "revision" => 4}] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "2026-12-18",
                 "expected_revision" => 3
               })
             ])

    assert %{"status" => "cancelled", "deposit_due_cents" => 0, "outstanding_deposit_cents" => 0} =
             group()

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 10000,
             "cash_retained_cents" => 0
           }
  end

  test "per-room rounding and full advance purchase deposits" do
    rooms = for id <- ["second", "first"], do: %{"room_id" => id, "nightly_rate_cents" => 1}
    assert [%{"deposit_due_cents" => 2}] = batch([opening(%{"rooms" => rooms})])
    assert group()["rooms"] == rooms

    assert [%{"deposit_due_cents" => 6}] =
             batch([
               opening(%{
                 "group_id" => "advance",
                 "rooms" => rooms,
                 "rate_plan" => "advance_purchase"
               })
             ])
  end

  test "opening failures leave the database unchanged and later operations continue" do
    invalid = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"arrival_on" => "bad"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => [1]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{"rooms" => [hd(opening()["rooms"]), hd(opening()["rooms"])]}, "invalid_rooms"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"guest_id" => nil}, "invalid_operation"}
    ]

    for {changes, code} <- invalid do
      before = snapshot()
      assert [%{"status" => "rejected", "code" => ^code}] = batch([opening(changes)])
      assert snapshot() == before
    end

    assert [%{"revision" => 1}, %{"code" => "group_already_exists"}, %{"revision" => 2}] =
             batch([
               opening(%{"expected_revision" => 99}),
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 19500})
             ])

    assert group()["outstanding_deposit_cents"] == 0
  end

  test "invalid batches and malformed operations return stable errors" do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert build_conn() |> post("/api/v1/partner-batches", body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    assert batch([]) == []

    malformed = [
      nil,
      1,
      "oops",
      [],
      %{},
      operation("unknown"),
      Map.delete(opening(), "rooms"),
      opening(%{"occurred_on" => "bad"}),
      opening(%{"operation_id" => nil}),
      opening(%{"group_id" => 42})
    ]

    assert Enum.all?(batch(malformed), &(&1["code"] == "invalid_operation"))

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}
  end

  test "revision conflicts precede domain validation and never mutate state" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = snapshot()

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => -1}),
          operation("reschedule_group", %{"new_arrival_on" => "bad"}),
          operation("cancel_group")
        ] do
      assert [
               %{
                 "operation_id" => id,
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = batch([Map.put(op, "expected_revision", 1)])

      assert id == op["operation_id"]
      assert snapshot() == before

      assert [%{"code" => "group_not_found"}] =
               batch([Map.merge(op, %{"group_id" => "missing", "expected_revision" => 1})])
    end

    batch([operation("cancel_group")])

    assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
             batch([operation("cancel_group", %{"expected_revision" => 2})])
  end

  test "invalid payments and reschedules do not change the account" do
    batch([opening()])
    before = snapshot()

    for amount <- [0, -1, 1.5, "100", nil, true] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])

      assert snapshot() == before
    end

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19501})])

    for date <- [nil, "bad", "2026-02-30", "2026-10-04", "2026-10-03"] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => date})])

      assert snapshot() == before
    end

    assert [%{"revision" => 2}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2026-12-10"})])
  end

  test "unrepresentable room totals are rejected without interrupting the batch" do
    oversized =
      opening(%{
        "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 9_223_372_036_854_775_807}]
      })

    assert [%{"code" => "invalid_rooms"}, %{"status" => "applied", "revision" => 1}] =
             batch([oversized, opening()])

    assert group()["lodging_total_cents"] == 97500
  end

  test "rescheduling across leap day preserves nights and price" do
    batch([opening(%{"arrival_on" => "2028-02-28", "departure_on" => "2028-03-02"})])

    assert [
             %{
               "new_arrival_on" => "2028-03-01",
               "new_departure_on" => "2028-03-04",
               "revision" => 2
             }
           ] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-03-01"})])

    assert group()["lodging_total_cents"] == 97500
    assert group()["deposit_due_cents"] == 19500
  end

  test "cancellation boundaries, unpaid deposits, and ledger aggregation" do
    for {id, plan, date, paid, refund, retain} <- [
          {"early", "flexible", "2026-11-26", 100, 100, 0},
          {"late", "flexible", "2026-11-27", 200, 0, 200},
          {"advance", "advance_purchase", "2026-10-04", 300, 0, 300},
          {"unpaid", "flexible", "2026-11-27", 0, 0, 0}
        ] do
      batch([opening(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0,
        do: batch([operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})])

      assert [%{"refunded_cents" => ^refund, "retained_cents" => ^retain}] =
               batch([operation("cancel_group", %{"group_id" => id, "occurred_on" => date})])

      before = snapshot()

      for op <- [
            operation("cancel_group"),
            operation("record_cash_payment", %{"amount_cents" => 1}),
            operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"})
          ] do
        assert [%{"code" => "group_not_active"}] = batch([Map.put(op, "group_id", id)])
        assert snapshot() == before
      end
    end

    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 50})])

    assert ledger() == %{
             "cash_held_cents" => 50,
             "cash_refunded_cents" => 100,
             "cash_retained_cents" => 500
           }
  end
end
