defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp opening(attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("open"),
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
        "operation_id" => unique_id(type),
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
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
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
             "operation_id" => opened["operation_id"],
             "status" => "applied",
             "group_id" => "group-81",
             "deposit_due_cents" => 19500,
             "revision" => 1
           }

    assert paid["outstanding_deposit_cents"] == 9500
    assert paid["revision"] == 2

    assert stale == %{
             "operation_id" => stale["operation_id"],
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
             "policy_version" => "flex-14",
             "refundable_until" => "2026-12-19",
             "cash_paid_cents" => 10000,
             "credit_paid_cents" => 0,
             "status" => "active",
             "revision" => 3,
             "rooms" => [
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 15000,
                 "status" => "active",
                 "lodging_total_cents" => 45000,
                 "deposit_due_cents" => 9000,
                 "cash_paid_cents" => 9000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 17500,
                 "status" => "active",
                 "lodging_total_cents" => 52500,
                 "deposit_due_cents" => 10500,
                 "cash_paid_cents" => 1000,
                 "credit_paid_cents" => 0
               }
             ],
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
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
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
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
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
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "cash_held_cents" => 0,
             "cash_retained_cents" => 100,
             "cash_refunded_cents" => 0
           }
  end

  defp credit(on, guest \\ "guest-22") do
    build_conn()
    |> get("/api/v1/guests/#{guest}/credit", %{on: on})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger_on(on) do
    build_conn() |> get("/api/v1/ledger", %{on: on}) |> json_response(200) |> Map.fetch!("data")
  end

  defp issue_credit(id, cash, on \\ "2026-11-26") do
    batch([
      opening(%{"group_id" => id, "arrival_on" => "2027-12-10", "departure_on" => "2027-12-13"}),
      operation("record_cash_payment", %{"group_id" => id, "amount_cents" => cash}),
      operation("cancel_group", %{
        "group_id" => id,
        "operation_id" => id,
        "occurred_on" => on,
        "refund_method" => "hotel_credit"
      })
    ])
    |> List.last()
  end

  test "booking policy boundaries and reschedules preserve the original policy" do
    for {booked, policy, deadline} <- [
          {"2026-12-31", "flex-14", "2027-02-15"},
          {"2027-01-01", "flex-30", "2027-01-30"}
        ] do
      id = booked

      [_, moved, cancelled] =
        batch([
          opening(%{"group_id" => id, "occurred_on" => booked}),
          operation("reschedule_group", %{
            "group_id" => id,
            "occurred_on" => "2027-01-02",
            "new_arrival_on" => "2027-03-01"
          }),
          operation("cancel_group", %{
            "group_id" => id,
            "occurred_on" => deadline,
            "refund_method" => "hotel_credit"
          })
        ])

      assert moved["policy_version"] == policy
      assert moved["refundable_until"] == deadline
      assert moved["new_departure_on"] == "2027-03-04"
      assert cancelled["status"] == "applied"
      assert cancelled["credit_issued_cents"] == 0
    end

    batch([
      opening(%{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02"
      })
    ])

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               operation("cancel_group", %{
                 "occurred_on" => "2027-01-31",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert group()["revision"] == 1
  end

  test "bonus rounding, mixed funding, restoration and cash conversion conserve finance totals" do
    assert issue_credit("source", 105)["credit_issued_cents"] == 116

    batch([
      opening(),
      operation("apply_hotel_credit", %{"amount_cents" => 100}),
      operation("record_cash_payment", %{"amount_cents" => 50})
    ])

    assert group()["cash_paid_cents"] == 50
    assert group()["credit_paid_cents"] == 100
    assert group()["deposit_paid_cents"] == 150
    assert credit("2026-11-26")["available_cents"] == 16
    assert ledger_on("2026-11-26")["credit_liability_cents"] == 116

    assert [
             %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 55,
               "revision" => 4
             }
           ] = batch([operation("cancel_group", %{"refund_method" => "hotel_credit"})])

    assert credit("2026-11-26")["available_cents"] == 171

    assert ledger_on("2026-11-26") == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 155,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 171
           }
  end

  test "lots are consumed by expiry then source and restored to original lots" do
    issue_credit("z", 100)
    issue_credit("a", 100)
    issue_credit("earlier", 100, "2026-11-25")

    assert Enum.map(credit("2026-11-26")["lots"], & &1["source_operation_id"]) == [
             "earlier",
             "a",
             "z"
           ]

    batch([opening(), operation("apply_hotel_credit", %{"amount_cents" => 150})])

    assert Enum.map(
             credit("2026-11-26")["lots"],
             &{&1["source_operation_id"], &1["remaining_cents"]}
           ) == [{"a", 70}, {"z", 110}]

    batch([operation("cancel_group")])
    assert Enum.map(credit("2026-11-26")["lots"], & &1["remaining_cents"]) == [110, 110, 110]
    assert ledger_on("2026-11-26")["credit_liability_cents"] == 330
  end

  test "expiry is inclusive and pauses for allocated credit, expired restoration is lost" do
    issue_credit("source", 100)
    assert credit("2027-11-26")["available_cents"] == 110
    assert credit("2027-11-27")["available_cents"] == 0

    batch([
      opening(),
      operation("apply_hotel_credit", %{"amount_cents" => 100, "occurred_on" => "2027-11-26"})
    ])

    assert ledger_on("2027-11-27")["credit_liability_cents"] == 100

    batch([
      operation("reschedule_group", %{
        "new_arrival_on" => "2028-02-01",
        "occurred_on" => "2027-11-27"
      }),
      operation("cancel_group", %{"occurred_on" => "2027-11-27"})
    ])

    assert ledger_on("2027-11-27")["credit_liability_cents"] == 0
    assert credit("2027-11-27")["lots"] == []
  end

  test "nonrefundable cancellation consumes credit and retains only cash" do
    issue_credit("source", 100)

    batch([
      opening(%{"rate_plan" => "advance_purchase"}),
      operation("apply_hotel_credit", %{"amount_cents" => 110}),
      operation("record_cash_payment", %{"amount_cents" => 20})
    ])

    assert group()["refundable_until"] == nil
    assert group()["policy_version"] == "advance-nonrefundable"
    before = group()

    assert [%{"code" => "refund_method_not_available"}] =
             batch([
               operation("cancel_group", %{"refund_method" => "hotel_credit"})
             ])

    assert group() == before

    assert [%{"retained_cents" => 20, "refunded_cents" => 0, "credit_issued_cents" => 0}] =
             batch([operation("cancel_group")])

    assert ledger_on("2026-11-26")["credit_liability_cents"] == 0
  end

  test "credit failures are atomic and respect revision and payment validation" do
    issue_credit("source", 100)
    batch([opening()])
    before = credit("2026-11-26")

    for {attrs, code} <- [
          {%{}, "invalid_operation"},
          {%{"amount_cents" => 0}, "invalid_amount"},
          {%{"amount_cents" => 19501}, "payment_exceeds_outstanding"},
          {%{"amount_cents" => 111}, "insufficient_credit"},
          {%{"amount_cents" => 1, "occurred_on" => "2027-11-27"}, "insufficient_credit"},
          {%{"amount_cents" => 111, "expected_revision" => 0}, "stale_revision"},
          {%{"group_id" => "missing", "expected_revision" => 0}, "group_not_found"}
        ] do
      assert [%{"code" => ^code}] = batch([operation("apply_hotel_credit", attrs)])
      assert group()["revision"] == 1
      assert credit("2026-11-26") == before
    end

    assert [%{"code" => "stale_revision"}, %{"code" => "invalid_operation"}] =
             batch([
               operation("cancel_group", %{"refund_method" => "bad", "expected_revision" => 0}),
               operation("cancel_group", %{"refund_method" => "bad"})
             ])

    batch([opening(%{"group_id" => "other", "guest_id" => "other-guest"})])

    assert [%{"code" => "insufficient_credit"}] =
             batch([
               operation("apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 1})
             ])

    assert credit("2026-11-26", "unknown")["lots"] == []
  end

  test "date reads reject malformed dates and default to UTC today" do
    for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"] do
      assert build_conn() |> get(path, %{on: "bad"}) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}

      assert build_conn() |> get(path) |> json_response(200) ==
               build_conn()
               |> get(path, %{on: Date.to_iso8601(Date.utc_today())})
               |> json_response(200)
    end
  end

  test "cash refunds restore repeated allocations on the original expiry date" do
    issue_credit("source", 100)

    results =
      batch([
        opening(),
        operation("apply_hotel_credit", %{"amount_cents" => 40, "expected_revision" => 1}),
        operation("apply_hotel_credit", %{"amount_cents" => 70, "expected_revision" => 2}),
        operation("record_cash_payment", %{"amount_cents" => 25}),
        operation("reschedule_group", %{"new_arrival_on" => "2028-01-01"}),
        operation("cancel_group", %{"occurred_on" => "2027-11-26"})
      ])

    assert Enum.at(results, 2)["revision"] == 3
    assert List.last(results)["refunded_cents"] == 25
    assert List.last(results)["credit_issued_cents"] == 0

    assert credit("2027-11-26")["lots"] == [
             %{
               "source_operation_id" => "source",
               "remaining_cents" => 110,
               "expires_on" => "2027-11-26"
             }
           ]

    assert ledger_on("2027-11-27")["credit_liability_cents"] == 0

    assert [%{"code" => "group_not_active"}] =
             batch([
               operation("apply_hotel_credit", %{"amount_cents" => 1})
             ])
  end
end
