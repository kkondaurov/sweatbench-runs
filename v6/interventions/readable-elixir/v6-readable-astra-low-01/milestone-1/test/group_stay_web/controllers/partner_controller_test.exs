defmodule GroupStayWeb.PartnerControllerTest do
  use GroupStayWeb.ConnCase

  defp open(overrides \\ %{}) do
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

  defp op(type, overrides \\ %{}) do
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

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group,
    do: build_conn() |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

  defp ledger,
    do: build_conn() |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  test "ordered operations, room rounding, revisions, reschedule and refundable settlement" do
    assert [opened, paid, moved, cancelled] =
             batch([
               open(),
               op("record_cash_payment", %{"amount_cents" => 10000, "expected_revision" => 1}),
               op("reschedule_group", %{
                 "new_arrival_on" => "2027-01-01",
                 "expected_revision" => 2
               }),
               op("cancel_group", %{"expected_revision" => 3})
             ])

    assert opened["deposit_due_cents"] == 19502
    assert opened["revision"] == 1
    assert paid["outstanding_deposit_cents"] == 9502
    assert paid["revision"] == 2
    assert moved["new_departure_on"] == "2027-01-04"
    assert moved["revision"] == 3
    assert cancelled["refunded_cents"] == 10000
    assert cancelled["retained_cents"] == 0
    assert cancelled["revision"] == 4

    assert %{
             "status" => "cancelled",
             "outstanding_deposit_cents" => 0,
             "deposit_due_cents" => 0,
             "booked_on" => "2026-10-03",
             "lodging_total_cents" => 97506,
             "revision" => 4
           } = group()

    assert Enum.map(group()["rooms"], & &1["room_id"]) == ["b", "a"]

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 10000,
             "cash_retained_cents" => 0
           }
  end

  test "stale revision precedes domain validation and failures leave all state unchanged" do
    batch([open(), op("record_cash_payment", %{"amount_cents" => 100})])
    before = {group(), ledger()}

    for operation <- [
          op("record_cash_payment", %{"amount_cents" => -1}),
          op("reschedule_group", %{"new_arrival_on" => "bad"}),
          op("cancel_group")
        ] do
      assert [result] = batch([Map.put(operation, "expected_revision", 1)])

      assert result == %{
               "operation_id" => operation["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert {group(), ledger()} == before
    end

    assert [%{"code" => "group_not_found"}] =
             batch([op("cancel_group", %{"group_id" => "missing", "expected_revision" => 0})])

    assert [%{"revision" => 3}] = batch([op("cancel_group", %{"expected_revision" => 2})])

    assert [%{"code" => "stale_revision"}] =
             batch([op("cancel_group", %{"expected_revision" => 2})])
  end

  test "cancellation policy at fourteen days, thirteen days, and advance purchase" do
    for {id, plan, occurred, refunded, retained} <- [
          {"boundary", "flexible", "2026-11-26", 100, 0},
          {"late", "flexible", "2026-11-27", 0, 100},
          {"advance", "advance_purchase", "2026-10-03", 0, 100}
        ] do
      [opened, _, cancelled] =
        batch([
          open(%{"group_id" => id, "rate_plan" => plan}),
          op("record_cash_payment", %{"group_id" => id, "amount_cents" => 100}),
          op("cancel_group", %{"group_id" => id, "occurred_on" => occurred})
        ])

      assert opened["deposit_due_cents"] == if(plan == "flexible", do: 19502, else: 97506)
      assert cancelled["refunded_cents"] == refunded
      assert cancelled["retained_cents"] == retained
    end

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 100,
             "cash_retained_cents" => 200
           }
  end

  test "invalid opens never create records and processing continues" do
    invalid = [
      {%{"departure_on" => "2026-12-10"}, "invalid_stay"},
      {%{"arrival_on" => "2026-02-30"}, "invalid_stay"},
      {%{"rooms" => []}, "invalid_rooms"},
      {%{"rooms" => [nil]}, "invalid_rooms"},
      {%{"rooms" => [%{"room_id" => "x", "nightly_rate_cents" => -1}]}, "invalid_rooms"},
      {%{
         "rooms" => [
           %{"room_id" => "x", "nightly_rate_cents" => 1},
           %{"room_id" => "x", "nightly_rate_cents" => 2}
         ]
       }, "invalid_rooms"},
      {%{"rate_plan" => "other"}, "invalid_rate_plan"}
    ]

    for {changes, code} <- invalid do
      assert [%{"code" => ^code}] = batch([open(changes)])
      assert GroupStay.Reservations.get_group("group") == nil
    end

    assert [
             %{"code" => "invalid_operation"},
             %{"status" => "applied"},
             %{"code" => "group_already_exists"}
           ] = batch([nil, open(), open()])

    assert group()["revision"] == 1
  end

  test "payment validations, full funding, inactive groups and missing operations" do
    batch([open()])

    for amount <- [0, -1, 1.5, "100", nil] do
      assert [%{"code" => "invalid_amount"}] =
               batch([op("record_cash_payment", %{"amount_cents" => amount})])
    end

    assert [%{"code" => "payment_exceeds_outstanding"}] =
             batch([op("record_cash_payment", %{"amount_cents" => 19503})])

    assert group()["revision"] == 1

    assert [%{"outstanding_deposit_cents" => 0, "revision" => 2}] =
             batch([op("record_cash_payment", %{"amount_cents" => 19502})])

    assert ledger()["cash_held_cents"] == 19502

    assert [%{"code" => "invalid_stay"}] =
             batch([op("reschedule_group", %{"new_arrival_on" => "2026-11-26"})])

    batch([op("cancel_group")])
    before = {group(), ledger()}

    for operation <- [
          op("record_cash_payment", %{"amount_cents" => 1}),
          op("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
          op("cancel_group")
        ] do
      assert [%{"code" => "group_not_active"}] = batch([operation])
      assert {group(), ledger()} == before
    end

    for operation <- [
          op("unknown"),
          op("record_cash_payment"),
          Map.delete(open(), "guest_id"),
          %{},
          1
        ] do
      assert [%{"code" => "invalid_operation"}] = batch([operation])
    end
  end

  test "a rejection between successes preserves earlier cash and allows later operations" do
    assert [opened, paid, rejected, final_payment] =
             batch([
               open(%{"expected_revision" => 99}),
               op("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1}),
               op("record_cash_payment", %{"amount_cents" => 20000, "expected_revision" => 2}),
               op("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 2})
             ])

    assert opened["revision"] == 1
    assert paid["revision"] == 2
    assert rejected["code"] == "payment_exceeds_outstanding"
    assert final_payment["revision"] == 3
    assert group()["deposit_paid_cents"] == 600
    assert ledger()["cash_held_cents"] == 600
  end

  test "an unpaid cancellation releases the requirement without creating cash" do
    assert [_, result] = batch([open(), op("cancel_group")])
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0
    assert group()["outstanding_deposit_cents"] == 0

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "empty and malformed batches, missing groups and empty ledger", %{conn: conn} do
    assert batch([]) == []

    for body <- [%{}, %{"operations" => nil}, %{"operations" => %{}}] do
      assert conn |> post("/api/v1/partner-batches", body) |> json_response(422) == %{
               "error" => %{"code" => "invalid_batch"}
             }
    end

    assert conn |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end
end
