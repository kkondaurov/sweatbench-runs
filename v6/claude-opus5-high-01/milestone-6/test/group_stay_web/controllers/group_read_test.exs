defmodule GroupStayWeb.GroupReadTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group under a data key", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{"data" => data} =
               conn |> get("/api/v1/groups/group-81") |> json_response(200)

      assert Enum.sort(Map.keys(data)) == [
               "arrival_on",
               "booked_on",
               "cash_paid_cents",
               "credit_paid_cents",
               "departure_on",
               "deposit_due_cents",
               "deposit_paid_cents",
               "group_id",
               "guest_id",
               "lodging_total_cents",
               "outstanding_deposit_cents",
               "policy_version",
               "property_id",
               "rate_plan",
               "refundable_until",
               "revision",
               "rooms",
               "status"
             ]

      room_keys = [
        "cash_paid_cents",
        "credit_paid_cents",
        "deposit_due_cents",
        "nightly_rate_cents",
        "room_id",
        "status"
      ]

      assert Enum.map(data["rooms"], &Enum.sort(Map.keys(&1))) == [room_keys, room_keys]
    end

    test "returns the partner identifier unchanged", %{conn: conn} do
      submit_one(conn, open_group_op(%{group_id: "Group/81 x"}))

      assert %{"group_id" => "Group/81 x"} =
               conn
               |> get("/api/v1/groups/#{URI.encode("Group/81 x", &(&1 != ?/))}")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "a missing group is a 404", %{conn: conn} do
      assert %{"error" => %{"code" => "group_not_found"}} =
               conn |> get("/api/v1/groups/group-none") |> json_response(404)
    end
  end
end
