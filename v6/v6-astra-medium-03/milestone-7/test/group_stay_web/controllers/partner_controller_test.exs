defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp opening(attrs \\ %{}) do
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
        "operation_id" => "#{type}-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      attrs
    )
  end

  defp batch(ops) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => ops}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(id \\ "group-81"),
    do: build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger,
    do: build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  test "batch envelope and missing group responses" do
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
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "opens, funds, and moves a group preserving identifiers, room order and prices" do
    assert [opened, paid, moved] =
             batch([
               opening(%{"expected_revision" => 99, "operation_id" => "open-1"}),
               operation("record_cash_payment", %{
                 "amount_cents" => 5000,
                 "expected_revision" => 1
               }),
               operation("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 2
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
    assert paid["amount_cents"] == 5000
    assert paid["revision"] == 2
    assert moved["new_arrival_on"] == "2027-01-01"
    assert moved["new_departure_on"] == "2027-01-04"
    assert moved["revision"] == 3

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
             "refundable_until" => "2026-12-18",
             "outstanding_deposit_cents" => 14500
           }

    assert ledger()["cash_held_cents"] == 5000
  end

  test "deposits round per room and advance purchase requires all lodging" do
    for {plan, due} <- [{"flexible", 2}, {"advance_purchase", 6}] do
      [result] =
        batch([
          opening(%{
            "group_id" => plan,
            "rate_plan" => plan,
            "departure_on" => "2026-12-11",
            "rooms" => [
              %{"room_id" => "one", "nightly_rate_cents" => 3},
              %{"room_id" => "two", "nightly_rate_cents" => 3}
            ]
          })
        ])

      assert result["deposit_due_cents"] == due
      assert group(plan)["lodging_total_cents"] == 6
    end

    [result] =
      batch([
        opening(%{
          "group_id" => "round-down",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "one", "nightly_rate_cents" => 2}]
        })
      ])

    assert result["deposit_due_cents"] == 0
  end

  test "invalid openings leave no group and batch continues" do
    cases = [
      {%{"arrival_on" => "bad"}, "invalid_stay"},
      {%{"occurred_on" => nil}, "invalid_stay"},
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"departure_on" => "2026-12-09"}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => nil}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 1.2}]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "r"}]}, "invalid_rooms"},
      {%{"rooms" => List.duplicate(%{"room_id" => "r", "nightly_rate_cents" => 10}, 2)},
       "invalid_rooms"},
      {%{"rate_plan" => "unknown"}, "invalid_rate_plan"}
    ]

    for {attrs, code} <- cases do
      assert [%{"code" => ^code}] = batch([opening(attrs)])
      assert GroupStay.Repo.aggregate(GroupStay.Group, :count) == 0
    end

    assert [
             %{"status" => "applied"},
             %{"code" => "group_already_exists"},
             %{"status" => "applied"}
           ] =
             batch([
               opening(),
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 100})
             ])

    assert group()["revision"] == 2
  end

  test "malformed and unknown operations reject without interrupting the batch" do
    bad = [
      nil,
      1,
      "bad",
      [],
      %{},
      operation("unknown"),
      Map.delete(opening(), "guest_id"),
      Map.delete(opening(), "operation_id"),
      Map.delete(opening(), "occurred_on")
    ]

    results = batch(bad ++ [opening()])
    assert Enum.all?(Enum.take(results, length(bad)), &(&1["code"] == "invalid_operation"))
    assert List.last(results)["status"] == "applied"

    for {type, key} <- [
          {"record_cash_payment", "amount_cents"},
          {"reschedule_group", "new_arrival_on"}
        ] do
      assert [%{"code" => "invalid_operation"}] = batch([operation(type) |> Map.delete(key)])
    end

    assert group()["revision"] == 1
  end

  test "payment validation and rejections preserve all persisted state" do
    batch([opening()])
    before = GroupStay.Repo.all(GroupStay.Group)

    for {amount, code} <- [
          {0, "invalid_amount"},
          {-1, "invalid_amount"},
          {1.0, "invalid_amount"},
          {"100", "invalid_amount"},
          {nil, "invalid_amount"},
          {19501, "payment_exceeds_outstanding"}
        ] do
      assert [%{"code" => ^code}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])

      assert GroupStay.Repo.all(GroupStay.Group) == before
      assert ledger()["cash_held_cents"] == 0
    end

    assert [
             %{"outstanding_deposit_cents" => 0, "revision" => 2},
             %{"code" => "payment_exceeds_outstanding"}
           ] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => 19500}),
               operation("record_cash_payment", %{"amount_cents" => 1})
             ])
  end

  test "revision comparisons precede domain validation and observe batch changes" do
    batch([opening()])

    for type <- ~w(record_cash_payment reschedule_group cancel_group) do
      assert [%{"code" => "group_not_found"}] =
               batch([operation(type, %{"group_id" => "missing", "expected_revision" => 99})])

      before = GroupStay.Repo.all(GroupStay.Group)
      op = operation(type, %{"expected_revision" => 0})
      assert [result] = batch([op])

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 0,
               "actual_revision" => 1
             }

      assert GroupStay.Repo.all(GroupStay.Group) == before
    end

    assert [
             %{"revision" => 2},
             %{"code" => "stale_revision", "actual_revision" => 2},
             %{"revision" => 3}
           ] =
             batch([
               operation("record_cash_payment", %{"amount_cents" => 10, "expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 1}),
               operation("cancel_group", %{"expected_revision" => 2})
             ])

    assert [%{"code" => "stale_revision"}, %{"code" => "group_not_active"}] =
             batch([
               operation("cancel_group", %{"expected_revision" => 2}),
               operation("cancel_group", %{"expected_revision" => 3})
             ])

    assert group()["revision"] == 3
  end

  test "rescheduling validates dates and preserves calendar duration across leap day" do
    batch([opening()])
    before = group()

    for date <- [nil, "bad", "2026-02-30", "2026-11-26", "2026-11-25"] do
      assert [%{"code" => "invalid_stay"}] =
               batch([operation("reschedule_group", %{"new_arrival_on" => date})])

      assert group() == before
    end

    assert [%{"new_departure_on" => "2028-03-02", "revision" => 2}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])
  end

  test "cancellations settle only paid cash at the 14 day boundary" do
    cases = [
      {"early", "flexible", "2026-11-25", 5000, 0},
      {"boundary", "flexible", "2026-11-26", 5000, 0},
      {"late", "flexible", "2026-11-27", 0, 5000},
      {"advance", "advance_purchase", "2026-10-04", 0, 5000}
    ]

    for {id, plan, date, refund, retain} <- cases do
      assert [_, _, settled] =
               batch([
                 opening(%{"group_id" => id, "rate_plan" => plan}),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 5000}),
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => date})
               ])

      assert settled["refunded_cents"] == refund
      assert settled["retained_cents"] == retain
      assert settled["revision"] == 3
      assert group(id)["status"] == "cancelled"
      assert group(id)["outstanding_deposit_cents"] == 0
      assert group(id)["deposit_due_cents"] == 0
      before = GroupStay.Repo.all(GroupStay.Group)

      for type <- ~w(record_cash_payment reschedule_group cancel_group) do
        assert [%{"code" => "group_not_active"}] = batch([operation(type, %{"group_id" => id})])
        assert GroupStay.Repo.all(GroupStay.Group) == before
      end
    end

    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 123})])

    assert ledger() == %{
             "cash_held_cents" => 123,
             "cash_refunded_cents" => 10000,
             "cash_retained_cents" => 10000,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cancellation uses the moved arrival and unpaid groups create no cash" do
    assert [_, _, _, %{"refunded_cents" => 50}] =
             batch([
               opening(),
               operation("record_cash_payment", %{"amount_cents" => 50}),
               operation("reschedule_group", %{"new_arrival_on" => "2027-02-01"}),
               operation("cancel_group", %{"occurred_on" => "2026-12-09"})
             ])

    assert [_, %{"refunded_cents" => 0, "retained_cents" => 0}] =
             batch([
               opening(%{"group_id" => "unpaid"}),
               operation("cancel_group", %{"group_id" => "unpaid"})
             ])

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 50,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0,
             "credit_liability_cents" => 0
           }
  end
end
