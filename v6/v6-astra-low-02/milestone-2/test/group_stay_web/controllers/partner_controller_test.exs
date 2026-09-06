defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "g",
        "guest_id" => "guest",
        "property_id" => "hotel",
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

  defp operation(type, fields \\ %{}) do
    Map.merge(
      %{"operation_id" => type, "type" => type, "occurred_on" => "2026-11-26", "group_id" => "g"},
      fields
    )
  end

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group,
    do: build_conn() |> get("/api/v1/groups/g") |> json_response(200) |> Map.fetch!("data")

  defp ledger,
    do: build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  test "batch and read envelopes", %{conn: conn} do
    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert conn |> post("/api/v1/partner-batches", body) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    assert batch([]) == []

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "opening, funding, moving and refunding see prior operations" do
    results =
      batch([
        opening(),
        operation("record_cash_payment", %{"amount_cents" => 10000, "expected_revision" => 1}),
        operation("reschedule_group", %{
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        })
      ])

    assert Enum.map(results, & &1["revision"]) == [1, 2, 3]
    assert hd(results)["deposit_due_cents"] == 19500
    assert Enum.at(results, 1)["outstanding_deposit_cents"] == 9500
    assert Enum.at(results, 2)["new_departure_on"] == "2027-01-04"

    assert group() == %{
             "group_id" => "g",
             "guest_id" => "guest",
             "property_id" => "hotel",
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
             "cash_paid_cents" => 10000,
             "credit_paid_cents" => 0,
             "policy_version" => "flex-14",
             "refundable_until" => "2026-12-18",
             "outstanding_deposit_cents" => 9500
           }

    assert ledger()["cash_held_cents"] == 10000

    assert [%{"refunded_cents" => 10000, "retained_cents" => 0, "revision" => 4}] =
             batch([operation("cancel_group")])

    assert group()["status"] == "cancelled"
    assert group()["outstanding_deposit_cents"] == 0

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_refunded_cents" => 10000,
             "cash_retained_cents" => 0
           }
  end

  test "per-room rounding and advance purchase" do
    rooms = for id <- ["x", "y"], do: %{"room_id" => id, "nightly_rate_cents" => 3}

    assert [%{"deposit_due_cents" => 2}] =
             batch([opening(%{"rooms" => rooms, "departure_on" => "2026-12-11"})])

    assert [%{"deposit_due_cents" => 97500}] =
             batch([opening(%{"group_id" => "advance", "rate_plan" => "advance_purchase"})])
  end

  test "cancellation threshold, advance purchase, and unpaid cancellations" do
    for {id, plan, day, paid, refund} <- [
          {"early", "flexible", "2026-11-26", 500, 500},
          {"late", "flexible", "2026-11-27", 600, 0},
          {"advance", "advance_purchase", "2026-10-04", 700, 0},
          {"unpaid", "flexible", "2026-11-26", 0, 0}
        ] do
      batch([opening(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0,
        do: batch([operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})])

      assert [%{"refunded_cents" => ^refund, "retained_cents" => retained}] =
               batch([operation("cancel_group", %{"group_id" => id, "occurred_on" => day})])

      assert retained == paid - refund
    end

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_refunded_cents" => 500,
             "cash_retained_cents" => 1300
           }
  end

  test "rejections are isolated and revisions checked before domain rules" do
    batch([opening()])
    before = group()

    assert [
             %{
               "code" => "stale_revision",
               "expected_revision" => 0,
               "actual_revision" => 1,
               "group_id" => "g"
             }
           ] =
             batch([
               operation("record_cash_payment", %{"expected_revision" => 0, "amount_cents" => -1})
             ])

    assert group() == before

    results =
      batch([
        operation("record_cash_payment", %{"amount_cents" => 19501}),
        operation("record_cash_payment", %{"amount_cents" => 19500}),
        operation("record_cash_payment", %{"amount_cents" => 1}),
        operation("cancel_group", %{"expected_revision" => 1}),
        operation("cancel_group", %{"expected_revision" => 2})
      ])

    assert Enum.map(results, &(&1["code"] || &1["status"])) == [
             "payment_exceeds_outstanding",
             "applied",
             "payment_exceeds_outstanding",
             "stale_revision",
             "applied"
           ]

    assert group()["revision"] == 3

    for type <- ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group) do
      fields = %{"amount_cents" => 1, "new_arrival_on" => "2027-01-01"}
      assert [%{"code" => "group_not_active"}] = batch([operation(type, fields)])

      assert [%{"code" => "stale_revision"}] =
               batch([operation(type, Map.put(fields, "expected_revision", 2))])

      assert [%{"code" => "group_not_found"}] =
               batch([
                 operation(
                   type,
                   Map.merge(fields, %{"group_id" => "missing", "expected_revision" => 0})
                 )
               ])
    end

    assert group()["revision"] == 3
  end

  test "invalid openings and malformed operations leave no state" do
    for {fields, code} <- [
          {%{"arrival_on" => "bad"}, "invalid_stay"},
          {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
          {%{"rooms" => []}, "invalid_rooms"},
          {%{"rooms" => [%{"room_id" => "a", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
          {%{"rooms" => [hd(opening()["rooms"]), hd(opening()["rooms"])]}, "invalid_rooms"},
          {%{"rate_plan" => "unknown"}, "invalid_rate_plan"}
        ] do
      assert [%{"code" => ^code}] = batch([opening(fields)])
      assert GroupStay.Repo.aggregate(GroupStay.Group, :count) == 0
    end

    for op <- [
          nil,
          42,
          "bad",
          %{},
          operation("unknown"),
          Map.delete(opening(), "guest_id"),
          opening(%{"occurred_on" => "bad"})
        ] do
      assert [%{"code" => "invalid_operation"}] = batch([op])
    end

    assert [%{"status" => "applied"}, %{"code" => "group_already_exists"}] =
             batch([opening(), opening()])
  end

  test "rescheduling uses calendar days and cancellation uses the moved arrival" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])

    assert [%{"new_departure_on" => "2028-03-02", "revision" => 3}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert [%{"revision" => 4}] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "2028-02-28",
                 "expected_revision" => 3
               })
             ])

    assert group()["deposit_due_cents"] == 19500
    assert group()["deposit_paid_cents"] == 500

    assert [%{"refunded_cents" => 500}] =
             batch([operation("cancel_group", %{"occurred_on" => "2028-02-14"})])
  end

  test "stale rescheduling and cancellation leave both group and ledger untouched" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])
    before_group = group()
    before_ledger = ledger()

    for op <- [
          operation("reschedule_group", %{"new_arrival_on" => "bad", "expected_revision" => 1}),
          operation("cancel_group", %{"expected_revision" => 1})
        ] do
      assert [%{"code" => "stale_revision", "actual_revision" => 2}] = batch([op])
      assert group() == before_group
      assert ledger() == before_ledger
    end
  end

  test "unrepresentable lodging amounts reject and processing continues" do
    rooms = [%{"room_id" => "huge", "nightly_rate_cents" => 9_223_372_036_854_775_807}]

    assert [%{"code" => "invalid_rooms"}, %{"status" => "applied"}] =
             batch([opening(%{"rooms" => rooms}), opening()])
  end

  test "invalid payment amounts and reschedule dates preserve all state" do
    batch([opening()])
    before = group()

    for amount <- [0, -1, 1.5, "10", nil, true] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])
    end

    for date <- [nil, "bad", "2026-02-30", "2026-11-26", "2026-11-25", "9999-12-31"] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => date})])
    end

    assert group() == before
    assert ledger()["cash_held_cents"] == 0
  end

  defp credit(on) do
    build_conn()
    |> get("/api/v1/guests/guest/credit", %{on: on})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger_on(on) do
    build_conn() |> get("/api/v1/ledger", %{on: on}) |> json_response(200) |> Map.fetch!("data")
  end

  defp issue(id, amount, day) do
    batch([
      opening(%{"group_id" => id, "arrival_on" => "2027-12-10", "departure_on" => "2027-12-13"}),
      operation("record_cash_payment", %{"group_id" => id, "amount_cents" => amount}),
      operation("cancel_group", %{
        "group_id" => id,
        "operation_id" => id,
        "occurred_on" => day,
        "refund_method" => "hotel_credit"
      })
    ])
    |> List.last()
  end

  test "policy cutoff is fixed at booking and follows rescheduling" do
    for {booked, policy, cutoff} <- [
          {"2026-12-31", "flex-14", "2027-02-15"},
          {"2027-01-01", "flex-30", "2027-01-30"}
        ] do
      id = booked

      batch([
        opening(%{"group_id" => id, "occurred_on" => booked}),
        operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 100})
      ])

      assert [%{"policy_version" => ^policy, "refundable_until" => ^cutoff}] =
               batch([
                 operation("reschedule_group", %{
                   "group_id" => id,
                   "new_arrival_on" => "2027-03-01"
                 })
               ])

      assert [%{"refunded_cents" => 100}] =
               batch([
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => cutoff})
               ])
    end

    batch([
      opening(%{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      })
    ])

    assert group()["refundable_until"] == "2027-01-30"

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "2027-01-31",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert group()["revision"] == 1
  end

  test "credit bonus rounds half up, lots are ordered and spending restores original lots" do
    assert issue("z", 105, "2026-11-26")["credit_issued_cents"] == 116
    issue("a", 100, "2026-11-26")
    issue("early", 100, "2026-11-25")

    assert Enum.map(credit("2026-11-26")["lots"], & &1["source_operation_id"]) == [
             "early",
             "a",
             "z"
           ]

    batch([
      opening(),
      operation("apply_hotel_credit", %{"amount_cents" => 150}),
      operation("record_cash_payment", %{"amount_cents" => 50})
    ])

    assert group()["credit_paid_cents"] == 150
    assert group()["cash_paid_cents"] == 50
    assert group()["deposit_paid_cents"] == 200
    assert Enum.map(credit("2026-11-26")["lots"], & &1["remaining_cents"]) == [70, 116]
    assert ledger_on("2026-11-26")["credit_liability_cents"] == 336
    assert ledger_on("2026-11-26")["cash_converted_to_credit_cents"] == 305

    assert [%{"refunded_cents" => 50, "credit_issued_cents" => 0, "revision" => 4}] =
             batch([operation("cancel_group")])

    assert credit("2026-11-26")["available_cents"] == 336
    assert ledger_on("2026-11-26")["credit_liability_cents"] == 336
  end

  test "expiry is inclusive and paused while applied; expired restoration removes liability" do
    issue("source", 100, "2026-11-26")
    assert credit("2027-11-26")["available_cents"] == 110
    assert credit("2027-11-27")["available_cents"] == 0

    batch([
      opening(),
      operation("apply_hotel_credit", %{"amount_cents" => 80}),
      operation("reschedule_group", %{"new_arrival_on" => "2028-03-01"})
    ])

    assert ledger_on("2027-11-27")["credit_liability_cents"] == 80

    assert [%{"credit_issued_cents" => 0}] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "2027-11-27",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert ledger_on("2027-11-27")["credit_liability_cents"] == 0
    assert credit("2027-11-27")["lots"] == []
  end

  test "mixed funding converts only cash and nonrefundable cancellation consumes credit" do
    issue("source", 100, "2026-11-26")

    batch([
      opening(),
      operation("apply_hotel_credit", %{"amount_cents" => 100}),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    assert [%{"credit_issued_cents" => 110, "refunded_cents" => 0, "retained_cents" => 0}] =
             batch([operation("cancel_group", %{"refund_method" => "hotel_credit"})])

    assert credit("2026-11-26")["available_cents"] == 220

    batch([
      opening(%{"group_id" => "next", "rate_plan" => "advance_purchase"}),
      operation("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 100}),
      operation("record_cash_payment", %{"group_id" => "next", "amount_cents" => 20})
    ])

    assert [%{"retained_cents" => 20, "credit_issued_cents" => 0}] =
             batch([
               operation("cancel_group", %{"group_id" => "next"})
             ])

    assert ledger_on("2026-11-26")["credit_liability_cents"] == 120
    assert ledger_on("2026-11-26")["cash_retained_cents"] == 20

    assert build_conn()
           |> get("/api/v1/groups/next")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == nil
  end

  test "credit failures preserve state and revision checks precede domain validation" do
    issue("source", 100, "2026-11-26")
    batch([opening()])
    before = group()

    for {fields, code} <- [
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "occurred_on" => "2027-11-27"}, "insufficient_credit"},
          {%{"amount_cents" => 19501}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => 111, "expected_revision" => 0}, "stale_revision"},
          {%{"amount_cents" => 1, "group_id" => "missing", "expected_revision" => 0},
           "group_not_found"}
        ] do
      assert [%{"code" => ^code}] = batch([operation("apply_hotel_credit", fields)])
      assert group() == before
      assert credit("2026-11-26")["available_cents"] == 110
    end

    assert [%{"code" => "stale_revision"}, %{"code" => "invalid_operation"}, %{"revision" => 2}] =
             batch([
               operation("cancel_group", %{"refund_method" => "bad", "expected_revision" => 0}),
               operation("cancel_group", %{"refund_method" => "bad"}),
               operation("apply_hotel_credit", %{"amount_cents" => 110, "expected_revision" => 1})
             ])

    assert credit("2026-11-26")["lots"] == []
    batch([opening(%{"group_id" => "other", "guest_id" => "other"})])

    assert [%{"code" => "insufficient_credit"}] =
             batch([
               operation("apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 1})
             ])
  end

  test "credit read defaults to UTC and rejects invalid dates" do
    assert credit(Date.to_iso8601(Date.utc_today())) ==
             build_conn()
             |> get("/api/v1/guests/guest/credit")
             |> json_response(200)
             |> Map.fetch!("data")

    for path <- ["/api/v1/ledger", "/api/v1/guests/guest/credit"] do
      assert build_conn() |> get(path, %{on: "bad"}) |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end
end
