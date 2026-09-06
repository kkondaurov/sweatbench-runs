defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import Phoenix.ConnTest

  describe "GET /api/v1/groups/:group_id" do
    test "renders the full group document", %{conn: conn} do
      conn
      |> submit_batch([
        open_operation(
          group_id: "group-doc",
          rooms: [
            %{"room_id" => "room-2", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-1", "nightly_rate_cents" => 15_000}
          ]
        ),
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-doc",
          "amount_cents" => 4000
        }
      ])
      |> json_response(200)

      %{"data" => group} = conn |> get_group("group-doc") |> json_response(200)

      assert %{
               "group_id" => "group-doc",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 2,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "rooms" => [
                 %{"room_id" => "room-2", "nightly_rate_cents" => 17_500},
                 %{"room_id" => "room-1", "nightly_rate_cents" => 15_000}
               ],
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 4000,
               "cash_paid_cents" => 4000,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 15_500
             } == group
    end

    test "returns group_not_found for a missing group", %{conn: conn} do
      conn = get_group(conn, "ghost-group")

      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "a cancelled group no longer reports an outstanding deposit", %{conn: conn} do
      conn
      |> submit_batch([
        open_operation(group_id: "group-cancelled"),
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-cancelled",
          "amount_cents" => 5000
        },
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "group-cancelled"
        }
      ])
      |> json_response(200)

      %{"data" => group} = conn |> get_group("group-cancelled") |> json_response(200)

      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
      # The unpaid deposit is no longer due but remains an accounting fact of the booking.
      assert group["deposit_due_cents"] == 19_500
      assert group["deposit_paid_cents"] == 5000
    end
  end
end
