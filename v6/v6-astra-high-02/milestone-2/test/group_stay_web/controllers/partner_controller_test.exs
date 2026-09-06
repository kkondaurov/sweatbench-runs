defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Group, Repo}
  import Ecto.Query

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
        "group_id" => "group-81",
        "occurred_on" => "2026-11-26"
      },
      overrides
    )
  end

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(id \\ "group-81") do
    build_conn() |> get(~p"/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger do
    build_conn() |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp snapshot, do: Repo.all(from g in Group, order_by: g.group_id)

  test "empty batches, invalid envelopes, missing groups and initial finance totals" do
    assert batch([]) == []

    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}, %{"operations" => "bad"}] do
      assert build_conn() |> post(~p"/api/v1/partner-batches", body) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_batch"}}
    end

    assert build_conn() |> get(~p"/api/v1/groups/missing") |> json_response(404) ==
             %{"error" => %{"code" => "group_not_found"}}

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "opens and reads the documented group with original room order and identifiers" do
    assert batch([opening(%{"expected_revision" => 99})]) == [
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
             "policy_version" => "flex-14",
             "refundable_until" => "2026-11-26",
             "status" => "active",
             "revision" => 1,
             "rooms" => opening()["rooms"],
             "lodging_total_cents" => 97500,
             "deposit_due_cents" => 19500,
             "deposit_paid_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19500
           }

    assert ledger()["cash_held_cents"] == 0
  end

  test "invalid JSON envelopes cannot supply operations through query parameters" do
    for body <- [[], nil, true, 12, "operations", %{}] do
      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/partner-batches?operations[]=invalid", Jason.encode!(body))
             |> json_response(422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    assert snapshot() == []
  end

  test "rounds each flexible room independently and charges full lodging for advance purchase" do
    rooms =
      for {id, rate} <- [{"Z", 2}, {"a", 2}, {"third", 3}],
          do: %{"room_id" => id, "nightly_rate_cents" => rate}

    base = %{"departure_on" => "2026-12-11", "rooms" => rooms}

    assert [%{"deposit_due_cents" => 1}, %{"deposit_due_cents" => 7}] =
             batch([
               opening(base),
               opening(
                 Map.merge(base, %{"group_id" => "advance", "rate_plan" => "advance_purchase"})
               )
             ])

    assert group()["rooms"] == rooms
    assert group()["lodging_total_cents"] == 7
  end

  test "rejects invalid openings without persisting any partial data" do
    cases = [
      {%{"arrival_on" => "2026-12-13"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"arrival_on" => "2026-02-30"}, "invalid_stay"},
      {%{"departure_on" => 123}, "invalid_stay"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
      {%{"rate_plan" => nil}, "invalid_rate_plan"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => [%{}]}, "invalid_rooms"},
      {%{"rooms" => [false]}, "invalid_rooms"},
      {%{"rooms" => List.duplicate(%{"room_id" => "dup", "nightly_rate_cents" => 100}, 2)},
       "invalid_rooms"},
      {%{"guest_id" => nil}, "invalid_operation"},
      {%{"occurred_on" => "bad"}, "invalid_operation"}
    ]

    bad_rates =
      for rate <- [-1, 1.5, "100", nil, true, 9_223_372_036_854_775_808],
          do: {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => rate}]}, "invalid_rooms"}

    for {attrs, code} <- cases ++ bad_rates do
      assert [%{"status" => "rejected", "code" => ^code}] = batch([opening(attrs)])
      assert snapshot() == []
    end

    for field <- Map.keys(opening()) do
      assert [%{"code" => "invalid_operation"}] = batch([Map.delete(opening(), field)])
      assert snapshot() == []
    end
  end

  test "duplicate groups reject without overwriting their booking or money" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 500})])
    before = snapshot()
    assert [%{"code" => "group_already_exists"}] = batch([opening(%{"guest_id" => "another"})])
    assert snapshot() == before
  end

  test "batch ordering, partial and full payments, and failure isolation" do
    assert [
             %{"revision" => 1},
             %{"amount_cents" => 500, "outstanding_deposit_cents" => 19000, "revision" => 2},
             %{"code" => "payment_exceeds_outstanding"},
             %{"code" => "invalid_operation"},
             %{"amount_cents" => 19000, "outstanding_deposit_cents" => 0, "revision" => 3},
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             batch([
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 500}),
               operation("record_cash_payment", %{"amount_cents" => 19001}),
               operation("unknown"),
               operation("record_cash_payment", %{
                 "amount_cents" => 19000,
                 "expected_revision" => 2
               }),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])

    assert group()["deposit_paid_cents"] == 19500
    assert ledger()["cash_held_cents"] == 19500
  end

  test "invalid payments and malformed operations leave all stored state unchanged" do
    batch([opening()])
    before = snapshot()

    for amount <- [0, -1, 1.5, "1", nil, true, %{}, []] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])

      assert snapshot() == before
    end

    for bad <- [
          nil,
          true,
          3,
          "bad",
          [],
          %{},
          operation("record_cash_payment"),
          operation("reschedule_group"),
          operation("bogus")
        ] do
      assert [%{"code" => "invalid_operation"}] = batch([bad])
      assert snapshot() == before
    end
  end

  test "moves across leap day preserving duration, price, cash and booking date" do
    batch([
      opening(%{"arrival_on" => "2028-02-27", "departure_on" => "2028-03-01"}),
      operation("record_cash_payment", %{"amount_cents" => 300})
    ])

    before = group()

    assert [
             %{
               "new_arrival_on" => "2028-02-29",
               "new_departure_on" => "2028-03-03",
               "revision" => 3
             }
           ] =
             batch([
               operation("reschedule_group", %{
                 "new_arrival_on" => "2028-02-29",
                 "expected_revision" => 2
               })
             ])

    assert Map.drop(group(), ~w(arrival_on departure_on revision refundable_until)) ==
             Map.drop(before, ~w(arrival_on departure_on revision refundable_until))

    assert ledger()["cash_held_cents"] == 300
  end

  test "reschedule validates dates and increments revision even for the same arrival" do
    batch([opening()])
    before = snapshot()

    for arrival <- ["2026-11-26", "2026-11-25", "2026-02-30", "bad", nil, 3, "9999-12-31"] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => arrival})])

      assert snapshot() == before
    end

    assert [%{"revision" => 2}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2026-12-10"})])
  end

  test "cancellation settles only paid cash at the exact fourteen-day boundary" do
    for {id, plan, cancelled_on, paid, refund, retain} <- [
          {"early", "flexible", "2026-11-25", 800, 800, 0},
          {"boundary", "flexible", "2026-11-26", 900, 900, 0},
          {"late", "flexible", "2026-11-27", 1000, 0, 1000},
          {"advance", "advance_purchase", "2026-10-03", 1100, 0, 1100},
          {"unpaid", "flexible", "2026-11-27", 0, 0, 0}
        ] do
      batch([opening(%{"group_id" => id, "rate_plan" => plan})])

      if paid > 0,
        do: batch([operation("record_cash_payment", %{"group_id" => id, "amount_cents" => paid})])

      revision = if paid > 0, do: 3, else: 2

      assert [
               %{
                 "refunded_cents" => ^refund,
                 "retained_cents" => ^retain,
                 "revision" => ^revision
               }
             ] =
               batch([
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => cancelled_on})
               ])

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = group(id)
    end

    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 250})])

    assert ledger() == %{
             "cash_held_cents" => 250,
             "cash_refunded_cents" => 1700,
             "cash_retained_cents" => 2100,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "refund eligibility follows the rescheduled arrival" do
    assert [_, _, _, %{"refunded_cents" => 700, "retained_cents" => 0, "revision" => 4}] =
             batch([
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 700}),
               operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
               operation("cancel_group", %{"occurred_on" => "2026-12-10"})
             ])
  end

  test "existence precedes revision checks and stale checks precede domain validation" do
    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, %{"expected_revision" => 99})])
    end

    batch([opening()])
    before = snapshot()

    for type <- ~w(record_cash_payment reschedule_group cancel_group),
        expected <- [0, 2, "1", 1.0, nil] do
      assert [result] =
               batch([
                 operation(type, %{"expected_revision" => expected, "occurred_on" => "bad"})
               ])

      assert result == %{
               "operation_id" => type,
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => expected,
               "actual_revision" => 1
             }

      assert snapshot() == before
    end
  end

  test "same-batch revisions include every applied operation and exclude every rejection" do
    assert [
             %{"revision" => 1},
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"code" => "invalid_amount"},
             %{"revision" => 3},
             %{"code" => "stale_revision", "actual_revision" => 3},
             %{"revision" => 4}
           ] =
             batch([
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 1
               }),
               operation("record_cash_payment", %{"amount_cents" => -1, "expected_revision" => 2}),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 2
               }),
               operation("cancel_group", %{"expected_revision" => 2}),
               operation("cancel_group", %{"expected_revision" => 3})
             ])

    assert group()["revision"] == 4
    assert ledger()["cash_refunded_cents"] == 100
  end

  test "cancelled groups reject all subsequent changes with revision precedence" do
    batch([opening(), operation("cancel_group")])
    before = snapshot()

    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_active"}] = batch([operation(type)])

      assert [%{"code" => "group_not_active"}] =
               batch([operation(type, %{"expected_revision" => 2})])

      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch([operation(type, %{"expected_revision" => 1})])

      assert snapshot() == before
    end
  end

  test "partner identifiers are preserved exactly" do
    attrs = %{
      "operation_id" => "OP-É-001",
      "group_id" => "GRüp-001",
      "guest_id" => " Guest 001 ",
      "property_id" => "AMS-001",
      "rooms" => [%{"room_id" => "Room-Ä", "nightly_rate_cents" => 0}]
    }

    assert [%{"operation_id" => "OP-É-001", "group_id" => "GRüp-001", "deposit_due_cents" => 0}] =
             batch([opening(attrs)])

    assert Map.take(group(attrs["group_id"]), ~w(group_id guest_id property_id rooms)) ==
             Map.take(attrs, ~w(group_id guest_id property_id rooms))
  end

  test "invalid operation dates reject atomically while missing dates still respect revision precedence" do
    batch([opening()])
    before = snapshot()

    for {type, attrs, code} <- [
          {"record_cash_payment", %{"amount_cents" => 500}, "invalid_operation"},
          {"reschedule_group", %{"new_arrival_on" => "2027-01-01"}, "invalid_stay"},
          {"cancel_group", %{}, "invalid_operation"}
        ] do
      assert [%{"code" => ^code}] = batch([operation(type, Map.put(attrs, "occurred_on", nil))])
      missing_date = operation(type, attrs) |> Map.delete("occurred_on")
      assert [%{"code" => "invalid_operation"}] = batch([missing_date])

      assert [%{"code" => "stale_revision"}] =
               batch([Map.put(missing_date, "expected_revision", 0)])

      assert snapshot() == before
    end
  end

  test "lodging overflow rejects before inserting and later operations still apply" do
    assert [%{"code" => "invalid_rooms"}, %{"revision" => 1}] =
             batch([
               opening(%{
                 "rooms" => [
                   %{"room_id" => "r", "nightly_rate_cents" => 9_223_372_036_854_775_807}
                 ]
               }),
               opening()
             ])

    assert group()["lodging_total_cents"] == 97500
  end
end
