defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(attrs \\ %{}) do
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
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
        ]
      },
      attrs
    )
  end

  defp operation(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => type,
        "type" => type,
        "group_id" => "group-81",
        "occurred_on" => "2026-11-26"
      },
      attrs
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

  test "batch and missing group response contracts" do
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
             "cash_retained_cents" => 0
           }
  end

  test "ordered operations, revision checks and rescheduling preserve prices and room order" do
    assert [opened, paid, stale, moved] =
             batch([
               opening(),
               operation("record_cash_payment", %{
                 "amount_cents" => 10000,
                 "expected_revision" => 1
               }),
               operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 1}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-02",
                 "expected_revision" => 2
               })
             ])

    assert opened == %{
             "operation_id" => "open",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19500,
             "revision" => 1
           }

    assert paid["outstanding_deposit_cents"] == 9500
    assert paid["revision"] == 2

    assert stale == %{
             "operation_id" => "record_cash_payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert moved["revision"] == 3
    assert moved["new_departure_on"] == "2027-01-05"

    assert group() == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2027-01-02",
             "departure_on" => "2027-01-05",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 3,
             "rooms" => opening()["rooms"],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 10000,
             "outstanding_deposit_cents" => 9500
           }

    assert ledger()["cash_held_cents"] == 10000
  end

  test "flexible deposits round each room separately and advance purchase requires full lodging" do
    rooms = for id <- ["a", "b"], do: %{"room_id" => id, "nightly_rate_cents" => 3}

    assert [flex, advance] =
             batch([
               opening(%{"rooms" => rooms, "departure_on" => "2026-12-11"}),
               opening(%{
                 "group_id" => "advance",
                 "rooms" => rooms,
                 "rate_plan" => "advance_purchase"
               })
             ])

    assert flex["deposit_due_cents"] == 2
    assert advance["deposit_due_cents"] == 18
  end

  test "invalid opens create nothing and processing continues" do
    cases = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"arrival_on" => "bad"}, "invalid_stay"},
      {%{"arrival_on" => nil}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "x", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "x", "nightly_rate_cents" => 1.2}]}, "invalid_rooms"},
      {%{"rooms" => List.duplicate(%{"room_id" => "x", "nightly_rate_cents" => 1}, 2)},
       "invalid_rooms"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"occurred_on" => "bad"}, "invalid_operation"}
    ]

    for {attrs, code} <- cases do
      assert [%{"code" => ^code, "status" => "rejected"}] = batch([opening(attrs)])
      assert GroupStay.Repo.aggregate(GroupStay.Reservations.Group, :count) == 0
    end

    assert [%{"status" => "applied"}, %{"code" => "group_already_exists"}] =
             batch([opening(), opening()])

    assert group()["revision"] == 1
  end

  test "malformed operations never stop the batch" do
    bad = [
      nil,
      3,
      "oops",
      [],
      %{},
      operation("unknown"),
      Map.delete(opening(), "rooms"),
      Map.delete(opening(), "operation_id"),
      opening(%{"guest_id" => nil})
    ]

    results = batch(bad ++ [opening()])
    assert Enum.all?(Enum.drop(results, -1), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"
  end

  test "payment and move rejections leave all persisted state unchanged" do
    batch([opening()])
    before = group()

    for amount <- [0, -1, nil, "100", 1.5, true] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])
    end

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19501})])

    for arrival <- [nil, "bad", "2026-11-26", "2026-11-25"] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => arrival})])
    end

    assert group() == before
    assert ledger()["cash_held_cents"] == 0

    assert [%{"outstanding_deposit_cents" => 0, "revision" => 2}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19500})])
  end

  for {plan, cancelled_on, refunded, retained} <- [
        {"flexible", "2026-11-26", 1000, 0},
        {"flexible", "2026-11-27", 0, 1000},
        {"advance_purchase", "2026-10-04", 0, 1000}
      ] do
    test "cancellation settlement for #{plan} on #{cancelled_on}" do
      batch([
        opening(%{"rate_plan" => unquote(plan)}),
        operation("record_cash_payment", %{"amount_cents" => 1000})
      ])

      assert [
               %{
                 "revision" => 3,
                 "refunded_cents" => unquote(refunded),
                 "retained_cents" => unquote(retained)
               }
             ] =
               batch([
                 operation("cancel_group", %{
                   "occurred_on" => unquote(cancelled_on),
                   "expected_revision" => 2
                 })
               ])

      assert group()["status"] == "cancelled"
      assert group()["outstanding_deposit_cents"] == 0

      assert ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => unquote(refunded),
               "cash_retained_cents" => unquote(retained)
             }

      for type <- ~w(record_cash_payment reschedule_group cancel_group) do
        assert [%{"code" => "group_not_active"}] = batch([operation(type)])

        assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
                 batch([operation(type, %{"expected_revision" => 2})])
      end

      assert group()["revision"] == 3
    end
  end

  test "existence precedes revision, and revision precedes all other domain rules" do
    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, %{"expected_revision" => 99})])
    end

    batch([opening(%{"expected_revision" => 100})])

    for type <- ~w(record_cash_payment reschedule_group cancel_group),
        revision <- [0, 2, nil, "1", 1.0] do
      assert [%{"code" => "stale_revision", "actual_revision" => 1}] =
               batch([operation(type, %{"expected_revision" => revision, "occurred_on" => nil})])
    end

    assert group()["revision"] == 1
  end

  test "finance aggregates groups and never includes unpaid requirements" do
    batch([
      opening(),
      opening(%{"group_id" => "second"}),
      operation("record_cash_payment", %{"amount_cents" => 800}),
      operation("record_cash_payment", %{"group_id" => "second", "amount_cents" => 300}),
      operation("cancel_group")
    ])

    assert ledger() == %{
             "cash_held_cents" => 300,
             "cash_refunded_cents" => 800,
             "cash_retained_cents" => 0
           }
  end

  test "missing update fields reject without changing the group" do
    batch([opening()])
    before = group()

    for op <- [
          operation("record_cash_payment"),
          operation("reschedule_group"),
          Map.delete(operation("cancel_group"), "occurred_on")
        ] do
      assert [%{"code" => "invalid_operation"}] = batch([op])
      assert group() == before
    end
  end

  test "cancellation uses the rescheduled arrival and unpaid cancellation moves no cash" do
    results =
      batch([
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("reschedule_group", %{"new_arrival_on" => "2026-11-30"}),
        operation("cancel_group"),
        opening(%{"group_id" => "unpaid"}),
        operation("cancel_group", %{"group_id" => "unpaid"})
      ])

    assert Enum.at(results, 3)["retained_cents"] == 100
    assert Enum.at(results, 5)["retained_cents"] == 0
    assert Enum.at(results, 5)["refunded_cents"] == 0

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_retained_cents" => 100,
             "cash_refunded_cents" => 0
           }
  end
end
