defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{System.unique_integer([:positive])}",
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
        "operation_id" => "#{type}-#{System.unique_integer([:positive])}",
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
             "rooms" => [
               %{
                 "room_id" => "b",
                 "nightly_rate_cents" => 15001,
                 "lodging_total_cents" => 45003,
                 "deposit_due_cents" => 9001,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "status" => "active"
               },
               %{
                 "room_id" => "a",
                 "nightly_rate_cents" => 17501,
                 "lodging_total_cents" => 52503,
                 "deposit_due_cents" => 10501,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "status" => "active"
               }
             ],
             "lodging_total_cents" => 97506,
             "deposit_due_cents" => 19502,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "outstanding_deposit_cents" => 19502
           }

    assert ledger() == %{
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0,
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

    assert Map.delete(Enum.at(results, 2), "operation_id") == %{
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
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0,
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
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "credit_liability_cents" => 0,
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
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0,
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

  defp credit(on, guest \\ "guest"),
    do:
      build_conn()
      |> get("/api/v1/guests/#{guest}/credit", %{"on" => on})
      |> json_response(200)
      |> Map.fetch!("data")

  defp ledger_on(on),
    do:
      build_conn()
      |> get("/api/v1/ledger", %{"on" => on})
      |> json_response(200)
      |> Map.fetch!("data")

  defp issue(id, cash, date \\ "2026-11-26") do
    batch([
      opening(%{"group_id" => id}),
      operation("record_cash_payment", %{"group_id" => id, "amount_cents" => cash}),
      operation("cancel_group", %{
        "group_id" => id,
        "operation_id" => id,
        "occurred_on" => date,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  test "booking cutoff fixes policy while rescheduling recomputes inclusive deadline" do
    for {booked, policy, deadline} <- [
          {"2026-12-31", "flex-14", "2027-02-15"},
          {"2027-01-01", "flex-30", "2027-01-30"}
        ] do
      id = booked
      batch([opening(%{"group_id" => id, "occurred_on" => booked})])

      [moved] =
        batch([
          operation("reschedule_group", %{
            "group_id" => id,
            "occurred_on" => "2027-01-01",
            "new_arrival_on" => "2027-03-01"
          })
        ])

      assert moved["policy_version"] == policy
      assert moved["refundable_until"] == deadline
      assert moved["new_departure_on"] == "2027-03-04"

      [_, cancelled] =
        batch([
          operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 10}),
          operation("cancel_group", %{"group_id" => id, "occurred_on" => deadline})
        ])

      assert cancelled["refunded_cents"] == 10
    end

    batch([opening(%{"rate_plan" => "advance_purchase"})])
    assert group()["policy_version"] == "advance-nonrefundable"
    assert group()["refundable_until"] == nil
  end

  test "credit bonus rounds half up and expires the day after its inclusive expiry" do
    [_, _, cancelled] = issue("source", 105)
    assert cancelled["credit_issued_cents"] == 116
    assert cancelled["refunded_cents"] == 0
    assert cancelled["retained_cents"] == 0

    assert credit("2027-11-26") == %{
             "guest_id" => "guest",
             "available_cents" => 116,
             "lots" => [
               %{
                 "source_operation_id" => "source",
                 "remaining_cents" => 116,
                 "expires_on" => "2027-11-26"
               }
             ]
           }

    assert credit("2027-11-27")["lots"] == []
    assert credit("2027-11-26", "other")["available_cents"] == 0
    assert ledger_on("2027-11-26")["credit_liability_cents"] == 116
    assert ledger_on("2027-11-27")["credit_liability_cents"] == 0
    assert ledger_on("2027-11-27")["cash_converted_to_credit_cents"] == 105
  end

  test "credit consumes earliest expiry then source id and restores original lots without bonus" do
    issue("z", 100)
    issue("a", 100)
    issue("early", 100, "2026-11-25")
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 50})])

    assert [%{"revision" => 3, "outstanding_deposit_cents" => 19282}] =
             batch([
               operation("apply_hotel_credit", %{"amount_cents" => 170, "expected_revision" => 2})
             ])

    assert group()["cash_paid_cents"] == 50
    assert group()["credit_paid_cents"] == 170
    assert group()["deposit_paid_cents"] == 220

    assert Enum.map(
             credit("2026-11-26")["lots"],
             &{&1["source_operation_id"], &1["remaining_cents"]}
           ) == [{"a", 50}, {"z", 110}]

    assert ledger_on("2026-11-26")["credit_liability_cents"] == 330
    assert ledger_on("2026-11-26")["cash_held_cents"] == 50
    [cancelled] = batch([operation("cancel_group", %{"refund_method" => "hotel_credit"})])
    assert cancelled["credit_issued_cents"] == 55
    assert credit("2026-11-26")["available_cents"] == 385
    assert ledger_on("2026-11-26")["credit_liability_cents"] == 385
    assert ledger_on("2026-11-26")["cash_converted_to_credit_cents"] == 350
  end

  for {cancel_date, refunded, liability} <- [
        {"2027-11-26", 25, 110},
        {"2027-11-27", 25, 0},
        {"2027-12-20", 0, 0}
      ] do
    test "redeemed expiry is paused and cancellation on #{cancel_date} settles correctly" do
      issue("source", 100)

      batch([
        opening(%{"arrival_on" => "2027-12-20", "departure_on" => "2027-12-23"}),
        operation("apply_hotel_credit", %{"amount_cents" => 110}),
        operation("record_cash_payment", %{"amount_cents" => 25})
      ])

      assert ledger_on("2027-11-27")["credit_liability_cents"] == 110
      assert credit("2027-11-27")["available_cents"] == 0
      [cancelled] = batch([operation("cancel_group", %{"occurred_on" => unquote(cancel_date)})])
      assert cancelled["refunded_cents"] == unquote(refunded)
      assert cancelled["retained_cents"] == 25 - unquote(refunded)
      assert cancelled["credit_issued_cents"] == 0
      assert ledger_on(unquote(cancel_date))["credit_liability_cents"] == unquote(liability)
      assert credit(unquote(cancel_date))["available_cents"] == unquote(liability)
    end
  end

  test "credit and method failures preserve groups lots and ledger with revision precedence" do
    issue("source", 100)
    batch([opening()])

    for {op, code} <- [
          {operation("apply_hotel_credit", %{"amount_cents" => 111}), "insufficient_credit"},
          {operation("apply_hotel_credit", %{"amount_cents" => 1, "occurred_on" => "2027-11-27"}),
           "insufficient_credit"},
          {operation("apply_hotel_credit", %{"amount_cents" => 0}), "invalid_amount"},
          {operation("apply_hotel_credit", %{"amount_cents" => 20000}),
           "payment_exceeds_outstanding"},
          {operation("apply_hotel_credit", %{"amount_cents" => 111, "expected_revision" => 0}),
           "stale_revision"},
          {operation("cancel_group", %{"refund_method" => "other"}), "invalid_operation"},
          {operation("cancel_group", %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2026-11-27"
           }), "refund_method_not_available"},
          {operation("cancel_group", %{
             "refund_method" => "hotel_credit",
             "occurred_on" => "2026-11-27",
             "expected_revision" => 0
           }), "stale_revision"},
          {operation("apply_hotel_credit", %{"group_id" => "missing", "expected_revision" => 0}),
           "group_not_found"}
        ] do
      before =
        {GroupStay.Repo.all(GroupStay.Group), GroupStay.Repo.all(GroupStay.CreditLot), ledger()}

      assert [%{"code" => ^code}] = batch([op])

      assert {GroupStay.Repo.all(GroupStay.Group), GroupStay.Repo.all(GroupStay.CreditLot),
              ledger()} == before
    end

    assert [%{"revision" => 2}] =
             batch([operation("apply_hotel_credit", %{"amount_cents" => 110})])
  end

  test "read dates default to UTC and invalid dates return a client error" do
    assert credit(Date.to_iso8601(Date.utc_today())) ==
             build_conn()
             |> get("/api/v1/guests/guest/credit")
             |> json_response(200)
             |> Map.fetch!("data")

    assert ledger() == ledger_on(Date.to_iso8601(Date.utc_today()))

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest/credit"] do
      assert build_conn() |> get(path, %{"on" => "invalid"}) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  test "new flexible policy rejects credit after thirty-day deadline and cash settles mixed funding" do
    issue("source", 100)

    batch([
      opening(%{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      }),
      operation("apply_hotel_credit", %{"amount_cents" => 50, "occurred_on" => "2027-01-01"}),
      operation("apply_hotel_credit", %{"amount_cents" => 60, "occurred_on" => "2027-01-01"}),
      operation("record_cash_payment", %{"amount_cents" => 25})
    ])

    assert [
             %{"code" => "refund_method_not_available"},
             %{"retained_cents" => 25, "revision" => 5}
           ] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "2027-01-31",
                 "refund_method" => "hotel_credit"
               }),
               operation("cancel_group", %{"occurred_on" => "2027-01-31"})
             ])

    assert ledger_on("2027-01-31")["credit_liability_cents"] == 0
  end

  test "guest isolation and repeated redemption restore cash and original credit independently" do
    issue("source", 100)
    batch([opening(%{"group_id" => "other", "guest_id" => "other"})])

    assert [%{"code" => "insufficient_credit"}] =
             batch([
               operation("apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 1})
             ])

    batch([
      opening(),
      operation("apply_hotel_credit", %{"amount_cents" => 50}),
      operation("apply_hotel_credit", %{"amount_cents" => 60}),
      operation("record_cash_payment", %{"amount_cents" => 25})
    ])

    assert [%{"refunded_cents" => 25, "credit_issued_cents" => 0, "revision" => 5}] =
             batch([operation("cancel_group")])

    assert credit("2026-11-26")["available_cents"] == 110
    assert ledger_on("2026-11-26")["cash_refunded_cents"] == 25

    assert [%{"code" => "group_not_active"}] =
             batch([operation("apply_hotel_credit", %{"amount_cents" => 1})])
  end
end
