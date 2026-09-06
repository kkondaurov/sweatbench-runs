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
        "operation_id" => "#{type}-1",
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

  test "empty ledger, missing groups and invalid batch envelopes" do
    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert build_conn() |> post("/api/v1/partner-batches", body) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    assert build_conn()
           |> post("/api/v1/partner-batches?operations[]=query-value", %{})
           |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}

    assert batch([]) == []
  end

  test "opens a group with original identifiers, room order, dates and totals" do
    assert batch([opening(%{"expected_revision" => 77})]) == [
             %{
               "operation_id" => "open-1",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
           ]

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
             "rooms" => opening()["rooms"],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }

    assert ledger()["cash_held_cents"] == 0
  end

  test "rounds flexible deposits per room and charges full advance purchase lodging" do
    rooms = [
      %{"room_id" => "one", "nightly_rate_cents" => 1},
      %{"room_id" => "two", "nightly_rate_cents" => 1}
    ]

    assert [%{"deposit_due_cents" => 2}] = batch([opening(%{"rooms" => rooms})])

    assert [%{"deposit_due_cents" => 6}] =
             batch([
               opening(%{
                 "group_id" => "advance",
                 "rooms" => rooms,
                 "rate_plan" => "advance_purchase"
               })
             ])

    assert [%{"deposit_due_cents" => 0}] =
             batch([
               opening(%{
                 "group_id" => "round-down",
                 "departure_on" => "2026-12-11",
                 "rooms" => rooms
               })
             ])
  end

  test "rejects invalid opening data without reserving the group identifier" do
    cases = [
      {%{"arrival_on" => "bad"}, "invalid_stay"},
      {%{"departure_on" => nil}, "invalid_stay"},
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"rate_plan" => "other"}, "invalid_rate_plan"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "x"}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "x", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "x", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "", "nightly_rate_cents" => 1}]}, "invalid_rooms"},
      {%{"rooms" => [hd(opening()["rooms"]), hd(opening()["rooms"])]}, "invalid_rooms"}
    ]

    for {attrs, code} <- cases do
      assert [%{"status" => "rejected", "code" => ^code}] = batch([opening(attrs)])
      assert GroupStay.Repo.all(GroupStay.Reservations.Group) == []
    end

    assert [%{"status" => "applied"}, %{"code" => "group_already_exists"}] =
             batch([opening(), opening()])

    assert group()["revision"] == 1
  end

  test "missing operation data and unknown types are isolated within a batch" do
    malformed = [
      nil,
      1,
      "oops",
      [],
      %{},
      operation("unknown"),
      Map.delete(opening(), "operation_id"),
      Map.delete(opening(), "occurred_on"),
      opening(%{"occurred_on" => "bad"}),
      opening(%{"group_id" => 12}),
      Map.delete(opening(), "rooms"),
      opening(%{"guest_id" => nil})
    ]

    results =
      batch(
        malformed ++
          [
            opening(),
            Map.delete(operation("record_cash_payment"), "amount_cents"),
            Map.delete(operation("reschedule_group"), "new_arrival_on"),
            operation("record_cash_payment", %{"amount_cents" => 100})
          ]
      )

    assert Enum.all?(Enum.take(results, length(malformed)), &(&1["code"] == "invalid_operation"))

    assert Enum.map(Enum.drop(results, length(malformed)), &(&1["code"] || &1["status"])) == [
             "applied",
             "invalid_operation",
             "invalid_operation",
             "applied"
           ]

    assert group()["revision"] == 2
  end

  test "payments see preceding operations, reject unusable amounts and overpayments, and can fully fund" do
    [_, payment] = batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])

    assert payment == %{
             "operation_id" => "record_cash_payment-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 500,
             "outstanding_deposit_cents" => 19000,
             "revision" => 2
           }

    before = group()

    for amount <- [0, -1, 1.5, "100", nil, true] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])

      assert group() == before
      assert ledger()["cash_held_cents"] == 500
    end

    assert [
             %{"code" => "payment_exceeds_outstanding"},
             %{"revision" => 3, "outstanding_deposit_cents" => 0},
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => 19001}),
               operation("record_cash_payment", %{"amount_cents" => 19000}),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    assert ledger()["cash_held_cents"] == 19500
  end

  test "rescheduling preserves nights, prices, rooms and booking date across a leap day" do
    batch([opening()])
    before = group()

    assert [
             %{
               "new_arrival_on" => "2028-02-28",
               "new_departure_on" => "2028-03-02",
               "revision" => 2
             }
           ] =
             batch([
               operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})
             ])

    assert Map.drop(group(), ~w(arrival_on departure_on revision)) ==
             Map.drop(before, ~w(arrival_on departure_on revision))

    for date <- ["bad", nil, "2026-11-26", "2026-11-25", "9999-12-31"] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => date})])

      assert group()["revision"] == 2
    end

    assert [%{"revision" => 3}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])
  end

  test "cancellation refunds at 14 days, retains at 13, and advance purchase always retains" do
    for {plan, date, refunded, retained} <- [
          {"flexible", "2026-11-26", 500, 0},
          {"flexible", "2026-11-27", 0, 500},
          {"advance_purchase", "2026-10-03", 0, 500}
        ] do
      id = "#{plan}-#{date}"

      assert [
               _,
               _,
               %{"refunded_cents" => ^refunded, "retained_cents" => ^retained, "revision" => 3}
             ] =
               batch([
                 opening(%{"group_id" => id, "rate_plan" => plan}),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 500}),
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => date})
               ])

      cancelled = GroupStay.Reservations.get_group(id)
      assert cancelled.status == "cancelled"
      assert cancelled.outstanding_deposit_cents == 0
    end

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 500,
             "cash_retained_cents" => 1000
           }
  end

  test "cancellation uses the rescheduled arrival and removes unpaid requirements" do
    assert [_, _, _, %{"refunded_cents" => 500, "retained_cents" => 0}] =
             batch([
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 500}),
               operation("reschedule_group", %{"new_arrival_on" => "2027-01-10"}),
               operation("cancel_group", %{"occurred_on" => "2026-12-01"})
             ])

    assert group()["status"] == "cancelled"
    assert group()["outstanding_deposit_cents"] == 0
    assert group()["deposit_due_cents"] == 0
    assert group()["deposit_paid_cents"] == 0
    before = group()

    for op <- [
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-02-01"}),
          operation("cancel_group")
        ] do
      assert [%{"code" => "group_not_active"}] = batch([op])
      assert group() == before

      assert ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 500,
               "cash_retained_cents" => 0
             }
    end

    assert [_, %{"refunded_cents" => 0, "retained_cents" => 0, "revision" => 2}] =
             batch([
               opening(%{"group_id" => "unpaid"}),
               operation("cancel_group", %{"group_id" => "unpaid"})
             ])
  end

  test "revision checks precede domain validation and track every applied operation in order" do
    results =
      batch([
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 1, "expected_revision" => 1}),
        operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 1}),
        operation("reschedule_group", %{"new_arrival_on" => "bad", "expected_revision" => 1}),
        operation("cancel_group", %{"expected_revision" => 1}),
        operation("reschedule_group", %{
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        }),
        operation("cancel_group", %{"expected_revision" => 3}),
        operation("cancel_group", %{"expected_revision" => 3}),
        operation("cancel_group", %{"expected_revision" => 4})
      ])

    for {result, op_id} <-
          Enum.zip(
            Enum.slice(results, 2, 3),
            ~w(record_cash_payment-1 reschedule_group-1 cancel_group-1)
          ) do
      assert result == %{
               "operation_id" => op_id,
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    assert Enum.map(results, &(&1["revision"] || &1["code"])) == [
             1,
             2,
             "stale_revision",
             "stale_revision",
             "stale_revision",
             3,
             4,
             "stale_revision",
             "group_not_active"
           ]

    assert group()["revision"] == 4

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 1,
             "cash_retained_cents" => 0
           }
  end

  test "missing groups precede revision checks and stale operations leave all stored fields unchanged" do
    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, %{"expected_revision" => 99})])
    end

    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 200})])
    before = GroupStay.Repo.all(GroupStay.Reservations.Group)

    for revision <- [1, 3, nil, "2", 2.0] do
      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch([operation("cancel_group", %{"expected_revision" => revision})])

      assert GroupStay.Repo.all(GroupStay.Reservations.Group) == before
    end

    assert ledger()["cash_held_cents"] == 200
  end

  test "large cent amounts stay exact and unusable room totals do not interrupt the batch" do
    amount = 9_223_372_036_854_775_807

    for id <- ["big-one", "big-two"] do
      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               batch([
                 opening(%{
                   "group_id" => id,
                   "departure_on" => "2026-12-11",
                   "rate_plan" => "advance_purchase",
                   "rooms" => [%{"room_id" => "big", "nightly_rate_cents" => amount}]
                 }),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => amount})
               ])
    end

    assert ledger()["cash_held_cents"] == amount * 2

    assert [%{"code" => "invalid_rooms"}, %{"status" => "applied"}] =
             batch([
               opening(%{
                 "rooms" => [%{"room_id" => "overflow", "nightly_rate_cents" => amount}]
               }),
               opening()
             ])
  end
end
