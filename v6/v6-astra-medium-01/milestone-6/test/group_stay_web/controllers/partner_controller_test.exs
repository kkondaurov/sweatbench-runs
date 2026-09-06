defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  # Earlier scenarios describe distinct attempts, each now needs its own identifier.
  defp fresh_id(base) do
    count = Process.get({:operation_sequence, base}, 0)
    Process.put({:operation_sequence, base}, count + 1)
    if count == 0, do: base, else: "#{base}-#{count}"
  end

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => fresh_id("open-1"),
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
        "operation_id" => fresh_id(type),
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

  defp group,
    do: build_conn() |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

  defp ledger,
    do: build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  test "batch envelope and missing group" do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert build_conn() |> post("/api/v1/partner-batches", body) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    assert batch([]) == []

    assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "open and fund in array order, preserving identifiers and room order" do
    assert [opened, paid] =
             batch([
               opening(),
               operation("record_cash_payment", %{
                 "amount_cents" => 5000,
                 "expected_revision" => 1
               })
             ])

    assert opened == %{
             "operation_id" => "open-1",
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19500,
             "revision" => 1
           }

    assert paid["outstanding_deposit_cents"] == 14500
    assert paid["revision"] == 2

    assert group() == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 2,
             "rooms" => [
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "lodging_total_cents" => 45000,
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 5000,
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
             "deposit_paid_cents" => 5000,
             "cash_paid_cents" => 5000,
             "credit_paid_cents" => 0,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "outstanding_deposit_cents" => 14500
           }

    assert ledger()["cash_held_cents"] == 5000
  end

  test "rounds deposits per room and supports full advance purchase deposits" do
    rooms = for id <- ["a", "b"], do: %{"room_id" => id, "nightly_rate_cents" => 1}

    assert [a, b] =
             batch([
               opening(%{"rooms" => rooms}),
               opening(%{
                 "group_id" => "advance",
                 "rooms" => rooms,
                 "rate_plan" => "advance_purchase"
               })
             ])

    assert a["deposit_due_cents"] == 2
    assert b["deposit_due_cents"] == 6
  end

  test "opening ignores expected revision and a same-date move still advances it" do
    assert [%{"revision" => 1}] = batch([opening(%{"expected_revision" => 99})])

    assert [%{"revision" => 2}] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "2026-12-10",
                 "expected_revision" => 1
               })
             ])

    assert group()["arrival_on"] == "2026-12-10"
    assert group()["departure_on"] == "2026-12-13"

    for revision <- [nil, "2", 2.0, false] do
      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch([
                 operation("cancel_group", %{"expected_revision" => revision})
               ])
    end

    assert group()["revision"] == 2
  end

  test "ledger combines active cash with completed settlements" do
    batch([
      opening(),
      operation("record_cash_payment", %{"amount_cents" => 50}),
      operation("cancel_group"),
      opening(%{"group_id" => "Grüp / 002", "guest_id" => " Guest 002 "}),
      operation("record_cash_payment", %{"group_id" => "Grüp / 002", "amount_cents" => 75})
    ])

    assert GroupStay.Reservations.get_group("Grüp / 002").guest_id == " Guest 002 "

    assert ledger() == %{
             "cash_held_cents" => 75,
             "cash_refunded_cents" => 50,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "invalid openings create nothing and later operations continue" do
    cases = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"arrival_on" => "2026-02-30"}, "invalid_stay"},
      {%{"departure_on" => 123}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => 1.5}]}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => List.duplicate(%{"room_id" => "a", "nightly_rate_cents" => 1}, 2)},
       "invalid_rooms"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"}
    ]

    for {attrs, code} <- cases do
      assert [%{"code" => ^code}] = batch([opening(attrs)])
      assert GroupStay.Repo.aggregate(GroupStay.Group, :count) == 0
    end

    assert [%{"status" => "applied"}, %{"code" => "group_already_exists"}] =
             batch([opening(), opening()])

    assert group()["revision"] == 1
  end

  test "malformed and incomplete operations are isolated" do
    invalid = [
      nil,
      42,
      "bad",
      [],
      %{},
      operation("unknown"),
      Map.delete(opening(), "guest_id"),
      Map.delete(operation("cancel_group"), "operation_id"),
      operation("record_cash_payment"),
      operation("reschedule_group"),
      operation("cancel_group", %{"occurred_on" => nil})
    ]

    results =
      batch([opening()] ++ invalid ++ [operation("record_cash_payment", %{"amount_cents" => 1})])

    assert hd(results)["status"] == "applied"

    assert Enum.all?(
             Enum.slice(results, 1, length(invalid)),
             &(&1["code"] == "invalid_operation")
           )

    assert List.last(results)["revision"] == 2
  end

  test "revisions precede domain validation and rejected operations leave all state untouched" do
    batch([opening()])
    before = {group(), ledger()}

    for type <- ["record_cash_payment", "reschedule_group", "cancel_group"] do
      attrs = %{"amount_cents" => -1, "new_arrival_on" => "bad", "expected_revision" => 0}
      assert [result] = batch([operation(type, attrs)])

      assert result == %{
               "operation_id" => type,
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 0,
               "actual_revision" => 1
             }

      assert {group(), ledger()} == before

      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, Map.put(attrs, "group_id", "missing"))])
    end

    assert [a, b, c] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => 1, "expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 1}),
               operation("record_cash_payment", %{"amount_cents" => 1, "expected_revision" => 2})
             ])

    assert a["revision"] == 2
    assert b["code"] == "stale_revision"
    assert c["revision"] == 3
  end

  test "payments reject unusable amounts and overpayments without mutation" do
    batch([opening()])
    before = {group(), ledger()}

    for amount <- [nil, 0, -1, 1.0, "100", true] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])

      assert {group(), ledger()} == before
    end

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19501})])

    assert {group(), ledger()} == before

    assert [%{"outstanding_deposit_cents" => 0}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19500})])
  end

  test "rescheduling shifts departure across calendar boundaries and changes the refund cutoff" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])

    for date <- [nil, "bad", "2026-11-26", "2026-11-25"] do
      before = {group(), ledger()}

      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => date})])

      assert {group(), ledger()} == before
    end

    assert [moved] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "2026-12-31",
                 "expected_revision" => 2
               })
             ])

    assert moved["new_departure_on"] == "2027-01-03"
    assert moved["revision"] == 3
    assert group()["lodging_total_cents"] == 97500
    assert group()["deposit_due_cents"] == 19500

    assert [%{"refunded_cents" => 500, "revision" => 4}] =
             batch([operation("cancel_group", %{"occurred_on" => "2026-12-17"})])
  end

  test "cancellation boundaries settle only paid cash and inactive operations reject" do
    for {id, plan, date, refund, retain} <- [
          {"early", "flexible", "2026-11-25", 500, 0},
          {"boundary", "flexible", "2026-11-26", 500, 0},
          {"late", "flexible", "2026-11-27", 0, 500},
          {"advance", "advance_purchase", "2026-11-01", 0, 500}
        ] do
      assert [_, _, cancelled] =
               batch([
                 opening(%{"group_id" => id, "rate_plan" => plan}),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 500}),
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => date})
               ])

      assert cancelled["refunded_cents"] == refund
      assert cancelled["retained_cents"] == retain
      assert cancelled["revision"] == 3
    end

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 1000,
             "cash_retained_cents" => 1000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    batch([opening(), operation("cancel_group")])
    assert group()["status"] == "cancelled"
    assert group()["outstanding_deposit_cents"] == 0
    before = {group(), ledger()}

    for op <- [
          operation("cancel_group"),
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"})
        ] do
      assert [%{"code" => "group_not_active"}] = batch([op])

      assert [%{"code" => "stale_revision"}] =
               batch([
                 Map.merge(op, %{
                   "expected_revision" => 1,
                   "operation_id" => op["operation_id"] <> "-stale"
                 })
               ])

      assert {group(), ledger()} == before
    end
  end
end
