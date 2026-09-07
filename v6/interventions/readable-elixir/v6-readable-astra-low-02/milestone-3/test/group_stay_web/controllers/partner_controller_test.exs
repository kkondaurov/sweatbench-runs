defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp opening(overrides \\ %{}) do
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
        "operation_id" => unique_id(type),
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

  test "batch shape, empty ledger, and missing group", %{conn: conn} do
    assert conn |> post("/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert batch([]) == []

    assert ledger() == %{
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    assert build_conn() |> get("/api/v1/groups/absent") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  test "opens with per-room rounding, original identifiers and room order" do
    assert [%{"status" => "applied", "deposit_due_cents" => 19502, "revision" => 1}] =
             batch([opening()])

    assert %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "lodging_total_cents" => 97506,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19502,
             "status" => "active"
           } = group()

    assert Enum.map(group()["rooms"], & &1["room_id"]) == ["b", "a"]
    assert [%{"code" => "group_already_exists"}] = batch([opening()])
    assert group()["revision"] == 1
  end

  test "payments, moves and cancellation observe previous operations and revisions" do
    results =
      batch([
        opening(%{"expected_revision" => 999}),
        operation("record_cash_payment", %{"amount_cents" => 5000, "expected_revision" => 1}),
        operation("reschedule_group", %{
          "new_arrival_on" => "2027-01-01",
          "expected_revision" => 2
        }),
        operation("cancel_group", %{"expected_revision" => 3})
      ])

    assert Enum.map(results, & &1["revision"]) == [1, 2, 3, 4]
    assert Enum.at(results, 1)["outstanding_deposit_cents"] == 14502
    assert Enum.at(results, 2)["new_departure_on"] == "2027-01-04"
    assert Enum.at(results, 3)["refunded_cents"] == 5000

    assert %{"status" => "cancelled", "deposit_due_cents" => 0, "outstanding_deposit_cents" => 0} =
             group()

    assert ledger() == %{
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 5000,
             "cash_retained_cents" => 0
           }
  end

  test "rejections preserve the entire database and stale revisions precede domain validation" do
    batch([opening(), operation("record_cash_payment", %{"amount_cents" => 100})])
    before = GroupStay.Repo.all(GroupStay.Reservations.Group)

    assert [stale, missing, invalid, applied] =
             batch([
               operation("record_cash_payment", %{"expected_revision" => 1, "amount_cents" => -10}),
               operation("cancel_group", %{"group_id" => "absent", "expected_revision" => 999}),
               operation("reschedule_group", %{"new_arrival_on" => "bad"}),
               operation("record_cash_payment", %{"expected_revision" => 2, "amount_cents" => 1})
             ])

    assert stale == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert missing["code"] == "group_not_found"
    assert invalid["code"] == "invalid_stay"
    assert applied["revision"] == 3
    current = GroupStay.Repo.all(GroupStay.Reservations.Group)
    assert [old] = before
    assert current == [%{old | revision: 3, deposit_paid_cents: 101}]
  end

  test "invalid opening data never creates a group" do
    for {attrs, code} <- [
          {%{"arrival_on" => "bad"}, "invalid_stay"},
          {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
          {%{"rate_plan" => "unknown"}, "invalid_rate_plan"},
          {%{"rooms" => []}, "invalid_rooms"},
          {%{"rooms" => [%{"room_id" => "x", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
          {%{
             "rooms" => [
               %{"room_id" => "x", "nightly_rate_cents" => 1},
               %{"room_id" => "x", "nightly_rate_cents" => 2}
             ]
           }, "invalid_rooms"}
        ] do
      assert [%{"code" => ^code}] = batch([opening(attrs)])
      assert GroupStay.Repo.all(GroupStay.Reservations.Group) == []
    end
  end

  test "malformed operations reject individually and allow later operations" do
    assert results =
             batch([
               nil,
               12,
               %{},
               %{"type" => "unknown"},
               Map.delete(opening(), "rooms"),
               opening()
             ])

    assert Enum.map(results, & &1["status"]) == List.duplicate("rejected", 5) ++ ["applied"]
    assert Enum.all?(Enum.take(results, 5), &(&1["code"] == "invalid_operation"))
  end

  test "invalid amounts and overpayments leave balances unchanged" do
    batch([opening()])

    for amount <- [0, -1, 1.5, "100", nil] do
      assert [%{"code" => "invalid_amount"}] =
               batch([operation("record_cash_payment", %{"amount_cents" => amount})])
    end

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19503})])

    assert group()["revision"] == 1

    assert [%{"outstanding_deposit_cents" => 0}] =
             batch([operation("record_cash_payment", %{"amount_cents" => 19502})])

    assert ledger()["cash_held_cents"] == 19502
  end

  test "refund cutoff is inclusive and advance purchase always retains cash" do
    for {id, plan, date, refunded} <- [
          {"boundary", "flexible", "2026-11-26", 100},
          {"late", "flexible", "2026-11-27", 0},
          {"advance", "advance_purchase", "2026-10-03", 0}
        ] do
      assert [opened, _, cancelled] =
               batch([
                 opening(%{"group_id" => id, "rate_plan" => plan}),
                 operation("record_cash_payment", %{"group_id" => id, "amount_cents" => 100}),
                 operation("cancel_group", %{"group_id" => id, "occurred_on" => date})
               ])

      assert opened["deposit_due_cents"] == if(plan == "flexible", do: 19502, else: 97506)
      assert cancelled["refunded_cents"] == refunded
      assert cancelled["retained_cents"] == 100 - refunded
    end

    assert ledger() == %{
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0,
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 100,
             "cash_retained_cents" => 200
           }
  end

  test "cancelled groups reject all mutations, with stale revision checked first" do
    batch([opening(), operation("cancel_group")])
    before = GroupStay.Repo.all(GroupStay.Reservations.Group)

    for op <- [
          operation("cancel_group"),
          operation("record_cash_payment", %{"amount_cents" => 1}),
          operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"})
        ] do
      assert [%{"code" => "group_not_active"}] = batch([op])

      assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
               batch([
                 op
                 |> Map.put("expected_revision", 1)
                 |> Map.put("operation_id", unique_id("stale"))
               ])
    end

    assert GroupStay.Repo.all(GroupStay.Reservations.Group) == before
  end

  test "rescheduling requires a future date and preserves stay length across leap day" do
    batch([opening()])

    assert [%{"code" => "invalid_stay"}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2026-11-26"})])

    assert [%{"new_departure_on" => "2028-03-02", "revision" => 2}] =
             batch([operation("reschedule_group", %{"new_arrival_on" => "2028-02-28"})])

    assert group()["deposit_due_cents"] == 19502
    assert group()["lodging_total_cents"] == 97506
  end
end
