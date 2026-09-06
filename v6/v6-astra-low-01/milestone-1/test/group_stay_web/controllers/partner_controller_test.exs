defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group",
        "guest_id" => "guest",
        "property_id" => "hotel",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "b", "nightly_rate_cents" => 15001},
          %{"room_id" => "a", "nightly_rate_cents" => 17501}
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
        "group_id" => "group",
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

  defp group,
    do: build_conn() |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

  defp ledger,
    do: build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  test "opens with per-room rounding, original identifiers/order, dates and totals" do
    assert [%{"status" => "applied", "revision" => 1, "deposit_due_cents" => 19502}] =
             batch([opening()])

    assert group() == %{
             "group_id" => "group",
             "guest_id" => "guest",
             "property_id" => "hotel",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 1,
             "rooms" => opening()["rooms"],
             "lodging_total_cents" => 97506,
             "deposit_due_cents" => 19502,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19502
           }

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "ordered operations continue after failure and revision checks precede domain rules" do
    results =
      batch([
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 1000, "expected_revision" => 1}),
        operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 1}),
        operation("reschedule_group", %{
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        }),
        operation("cancel_group", %{"expected_revision" => 3}),
        operation("cancel_group", %{"expected_revision" => 3}),
        operation("cancel_group")
      ])

    assert Enum.map(results, & &1["status"]) == [
             "applied",
             "applied",
             "rejected",
             "applied",
             "applied",
             "rejected",
             "rejected"
           ]

    assert Enum.at(results, 2) == %{
             "operation_id" => "record_cash_payment",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert Enum.at(results, 3)["new_departure_on"] == "2027-01-04"
    assert Enum.at(results, 4)["revision"] == 4
    assert Enum.at(results, 5)["code"] == "stale_revision"
    assert Enum.at(results, 6)["code"] == "group_not_active"
    assert group()["outstanding_deposit_cents"] == 0

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 1000,
             "cash_retained_cents" => 0
           }
  end

  for {plan, date, refunded, retained} <- [
        {"flexible", "2026-11-26", 1000, 0},
        {"flexible", "2026-11-27", 0, 1000},
        {"advance_purchase", "2026-10-04", 0, 1000}
      ] do
    test "settles #{plan} cancellation on #{date}" do
      [opened, paid, cancelled] =
        batch([
          opening(%{"rate_plan" => unquote(plan)}),
          operation("record_cash_payment", %{"amount_cents" => 1000}),
          operation("cancel_group", %{"occurred_on" => unquote(date)})
        ])

      assert opened["deposit_due_cents"] ==
               if(unquote(plan) == "flexible", do: 19502, else: 97506)

      assert paid["revision"] == 2
      assert cancelled["refunded_cents"] == unquote(refunded)
      assert cancelled["retained_cents"] == unquote(retained)

      assert ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => unquote(refunded),
               "cash_retained_cents" => unquote(retained)
             }

      before = group()

      for type <- ["record_cash_payment", "reschedule_group", "cancel_group"] do
        assert [%{"code" => "group_not_active"}] = batch([operation(type)])
      end

      assert group() == before
    end
  end

  test "invalid opening data never creates a group" do
    cases = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"arrival_on" => "no date"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{
         "rooms" => [
           %{"room_id" => "a", "nightly_rate_cents" => 1},
           %{"room_id" => "a", "nightly_rate_cents" => 2}
         ]
       }, "invalid_rooms"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"}
    ]

    for {overrides, code} <- cases do
      assert [%{"code" => ^code}] = batch([opening(overrides)])
      assert GroupStay.Repo.aggregate(GroupStay.Group, :count) == 0
    end

    assert [%{"status" => "applied"}, %{"code" => "group_already_exists"}] =
             batch([opening(), opening()])
  end

  test "rejected mutations leave all persisted fields and finance unchanged" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])
    before = GroupStay.Repo.all(GroupStay.Group)
    totals = ledger()

    cases = [
      {operation("record_cash_payment", %{"amount_cents" => 0}), "invalid_amount"},
      {operation("record_cash_payment", %{"amount_cents" => -1}), "invalid_amount"},
      {operation("record_cash_payment", %{"amount_cents" => "10"}), "invalid_amount"},
      {operation("record_cash_payment", %{"amount_cents" => 1.5}), "invalid_amount"},
      {operation("record_cash_payment", %{"amount_cents" => 19503}),
       "payment_exceeds_outstanding"},
      {operation("reschedule_group", %{"new_arrival_on" => "2026-11-26"}), "invalid_stay"},
      {operation("reschedule_group", %{"new_arrival_on" => "2026-02-30"}), "invalid_stay"},
      {operation("cancel_group", %{"occurred_on" => false}), "invalid_operation"},
      {operation("cancel_group", %{"expected_revision" => 1}), "stale_revision"}
    ]

    for {op, code} <- cases do
      assert [%{"code" => ^code}] = batch([op])
      assert GroupStay.Repo.all(GroupStay.Group) == before
      assert ledger() == totals
    end

    assert [%{"outstanding_deposit_cents" => 0, "revision" => 3}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19002})])

    assert ledger()["cash_held_cents"] == 19502
  end

  test "batch structure, missing operations, and missing groups" do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert build_conn() |> post("/api/v1/partner-batches", body) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    assert batch([]) == []

    for op <- [
          nil,
          1,
          [],
          %{},
          operation("unknown"),
          Map.delete(opening(), "rooms"),
          Map.delete(opening(), "occurred_on")
        ] do
      assert [%{"code" => "invalid_operation"}] = batch([op])
    end

    for type <- ["record_cash_payment", "reschedule_group", "cancel_group"] do
      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, %{"expected_revision" => 99})])
    end

    assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "same-date moves increment revision without changing money and opening ignores expected revision" do
    batch([opening(%{"expected_revision" => 999})])
    before = group()

    assert [
             %{
               "revision" => 2,
               "new_arrival_on" => "2026-12-10",
               "new_departure_on" => "2026-12-13"
             }
           ] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "2026-12-10",
                 "expected_revision" => 1
               })
             ])

    assert group() == Map.put(before, "revision", 2)

    assert [%{"code" => "invalid_operation"}, %{"code" => "invalid_operation"}] =
             batch([operation("record_cash_payment"), operation("reschedule_group")])

    assert group()["revision"] == 2
  end

  test "ledger aggregates active, refunded, and retained cash independently" do
    for {id, plan} <- [
          {"group", "flexible"},
          {"refunded", "flexible"},
          {"retained", "advance_purchase"}
        ] do
      batch([
        opening(%{"group_id" => id, "rate_plan" => plan}),
        operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 123})
      ])
    end

    batch([
      operation("cancel_group", %{"group_id" => "refunded"}),
      operation("cancel_group", %{"group_id" => "retained"})
    ])

    assert ledger() == %{
             "cash_held_cents" => 123,
             "cash_refunded_cents" => 123,
             "cash_retained_cents" => 123
           }
  end

  test "unrepresentable prices and shifted dates reject without stopping the batch" do
    too_large =
      opening(%{
        "rooms" => [%{"room_id" => "huge", "nightly_rate_cents" => 9_223_372_036_854_775_807}]
      })

    assert [%{"code" => "invalid_rooms"}, %{"status" => "applied"}] =
             batch([too_large, opening()])

    before = group()

    assert [%{"code" => "invalid_stay"}, %{"status" => "applied", "revision" => 2}] =
             batch([
               operation("reschedule_group", %{"new_arrival_on" => "9999-12-31"}),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    assert group()["arrival_on"] == before["arrival_on"]
  end
end
