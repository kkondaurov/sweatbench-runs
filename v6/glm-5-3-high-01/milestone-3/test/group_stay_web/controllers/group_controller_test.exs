defmodule GroupStayWeb.GroupControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  @docs_example %{
    "operation_id" => "op-1001",
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
  }

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group with its rooms and totals" do
      apply_operations!(build_conn(), [@docs_example])

      conn = get(build_conn(), "/api/v1/groups/group-81")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-11-26",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19500
               }
             }
    end

    test "returns rooms in their original order" do
      apply_operations!(build_conn(), [
        open_group_operation(%{
          "rooms" => [
            %{"room_id" => "room-z", "nightly_rate_cents" => 1000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 2000},
            %{"room_id" => "room-m", "nightly_rate_cents" => 3000}
          ]
        })
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert Enum.map(json_response(conn, 200)["data"]["rooms"], & &1["room_id"]) ==
               ["room-z", "room-a", "room-m"]
    end

    test "reflects payments in the totals" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 2500})
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["deposit_paid_cents"] == 2500
      assert data["outstanding_deposit_cents"] == 9000 - 2500
      assert data["revision"] == 2
    end

    test "a cancelled group keeps its history with nothing outstanding" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"amount_cents" => 2500}),
        cancel_operation()
      ])

      conn = get(build_conn(), "/api/v1/groups/group-1")
      data = json_response(conn, 200)["data"]

      assert data["status"] == "cancelled"
      assert data["deposit_paid_cents"] == 2500
      assert data["deposit_due_cents"] == 9000
      assert data["outstanding_deposit_cents"] == 0
      assert data["revision"] == 3
    end

    test "returns group_not_found for a missing group" do
      conn = get(build_conn(), "/api/v1/groups/nope")

      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end
end
