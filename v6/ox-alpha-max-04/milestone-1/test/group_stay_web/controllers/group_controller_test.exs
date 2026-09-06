defmodule GroupStayWeb.Controllers.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: true

  describe "GET /api/v1/groups/:group_id" do
    test "renders the group with its identifiers, dates, rooms, and totals", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation()])

      response = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => group} = json_response(response, 200)

      assert group == %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             }
    end

    test "reflects payments in the deposit totals and revision", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"amount_cents" => 5_000})
        ])

      assert %{
               "deposit_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             } =
               fetch_group!(conn, "group-81")
    end

    test "keeps rooms in their original order", %{conn: conn} do
      rooms = [
        %{"room_id" => "room-z", "nightly_rate_cents" => 9_000},
        %{"room_id" => "room-a", "nightly_rate_cents" => 8_000}
      ]

      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-order", "rooms" => rooms})
        ])

      assert %{"rooms" => rendered} = fetch_group!(conn, "group-order")
      assert Enum.map(rendered, & &1["room_id"]) == ["room-z", "room-a"]
    end

    test "returns 404 with a stable error code for a missing group", %{conn: conn} do
      response = get(conn, "/api/v1/groups/group-does-not-exist")
      assert json_response(response, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "a cancelled group is still readable and its deposit is settled", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          record_payment_operation(%{"amount_cents" => 5_000}),
          cancel_operation(%{"occurred_on" => "2026-11-26"})
        ])

      group = fetch_group!(conn, "group-81")

      assert %{
               "status" => "cancelled",
               "revision" => 3,
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = group
    end

    test "a rescheduled group reports the shifted stay", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          reschedule_operation(%{"new_arrival_on" => "2027-01-04"})
        ])

      group = fetch_group!(conn, "group-81")

      assert %{
               "booked_on" => "2026-10-03",
               "arrival_on" => "2027-01-04",
               "departure_on" => "2027-01-07",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "revision" => 2
             } = group
    end
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reschedule",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-24"
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end
end
