defmodule GroupStayWeb.OpenGroupTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "open_group" do
    test "opens a group at revision 1 and prices the deposit", %{conn: conn} do
      assert %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             } = submit_one(conn, open_group_op())

      assert %{
               "group_id" => "group-81",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "status" => "active",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500,
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
               ]
             } = read_group(conn, "group-81")
    end

    test "keeps rooms in the order the partner sent them", %{conn: conn} do
      rooms =
        for room_id <- ~w(room-z room-a room-m),
            do: %{"room_id" => room_id, "nightly_rate_cents" => 10_000}

      submit_one(conn, open_group_op(%{rooms: rooms}))

      assert ~w(room-z room-a room-m) ==
               conn |> read_group("group-81") |> Map.fetch!("rooms") |> Enum.map(& &1["room_id"])
    end

    test "an advance purchase group owes its full lodging total", %{conn: conn} do
      assert %{"status" => "applied", "deposit_due_cents" => 97_500} =
               submit_one(conn, open_group_op(%{rate_plan: "advance_purchase"}))

      assert %{"lodging_total_cents" => 97_500, "outstanding_deposit_cents" => 97_500} =
               read_group(conn, "group-81")
    end

    test "rounds each room's deposit separately", %{conn: conn} do
      # 20% of one night at 13 cents is 2.6 cents per room: 3 + 3, not 5.
      rooms = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 13},
        %{"room_id" => "room-b", "nightly_rate_cents" => 13}
      ]

      assert %{"status" => "applied", "deposit_due_cents" => 6} =
               submit_one(
                 conn,
                 open_group_op(%{
                   rooms: rooms,
                   arrival_on: "2026-12-10",
                   departure_on: "2026-12-11"
                 })
               )
    end

    test "a one night stay is priced for one night", %{conn: conn} do
      assert %{"status" => "applied", "deposit_due_cents" => 6500} =
               submit_one(conn, open_group_op(%{departure_on: "2026-12-11"}))

      assert %{"lodging_total_cents" => 32_500} = read_group(conn, "group-81")
    end

    test "rejects a second group with the same identifier and keeps the first", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert %{"status" => "rejected", "code" => "group_already_exists"} =
               submit_one(
                 conn,
                 open_group_op(%{operation_id: "op-2", guest_id: "guest-99", rooms: []})
               )

      assert %{"guest_id" => "guest-22", "revision" => 1} = read_group(conn, "group-81")
    end

    test "rejects a stay without a night", %{conn: conn} do
      for {departure_on, index} <- Enum.with_index(["2026-12-10", "2026-12-09", "not-a-date"]) do
        assert %{"status" => "rejected", "code" => "invalid_stay"} =
                 submit_one(
                   conn,
                   open_group_op(%{
                     operation_id: "op-open-#{index}",
                     departure_on: departure_on
                   })
                 ),
               "expected invalid_stay for #{inspect(departure_on)}"
      end

      assert %{"status" => "rejected", "code" => "invalid_stay"} =
               submit_one(conn, open_group_op(%{arrival_on: nil}))

      assert json_response(get(conn, "/api/v1/groups/group-81"), 404)
    end

    test "rejects unusable rooms", %{conn: conn} do
      duplicates = [
        %{"room_id" => "room-a", "nightly_rate_cents" => 100},
        %{"room_id" => "room-a", "nightly_rate_cents" => 200}
      ]

      unusable = [
        [],
        duplicates,
        [%{"room_id" => "room-a"}],
        [%{"nightly_rate_cents" => 100}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => -1}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => "100"}],
        [%{"room_id" => "room-a", "nightly_rate_cents" => 100.5}],
        ["room-a"]
      ]

      for {rooms, index} <- Enum.with_index(unusable) do
        assert %{"status" => "rejected", "code" => "invalid_rooms"} =
                 submit_one(
                   conn,
                   open_group_op(%{operation_id: "op-open-#{index}", rooms: rooms})
                 ),
               "expected invalid_rooms for #{inspect(rooms)}"
      end

      assert %{"status" => "rejected", "code" => "invalid_rooms"} =
               submit_one(conn, Map.delete(open_group_op(), "rooms"))

      assert json_response(get(conn, "/api/v1/groups/group-81"), 404)
    end

    test "rejects an unknown rate plan", %{conn: conn} do
      for {rate_plan, index} <- Enum.with_index(["premium", "", nil]) do
        assert %{"status" => "rejected", "code" => "invalid_rate_plan"} =
                 submit_one(
                   conn,
                   open_group_op(%{operation_id: "op-open-#{index}", rate_plan: rate_plan})
                 ),
               "expected invalid_rate_plan for #{inspect(rate_plan)}"
      end

      assert json_response(get(conn, "/api/v1/groups/group-81"), 404)
    end

    test "rejects operations missing the data needed to identify them", %{conn: conn} do
      # Each usable identifier is spent once: an operation is only remembered under
      # the identifier it carries, and reusing one with a different payload would
      # be an identifier conflict rather than the rejection under test.
      unusable = [
        Map.delete(open_group_op(), "operation_id"),
        Map.delete(open_group_op(%{operation_id: "op-1"}), "occurred_on"),
        Map.delete(open_group_op(%{operation_id: "op-2"}), "group_id"),
        Map.delete(open_group_op(%{operation_id: "op-3"}), "guest_id"),
        Map.delete(open_group_op(%{operation_id: "op-4"}), "property_id"),
        open_group_op(%{operation_id: "op-5", occurred_on: "2026-13-45"}),
        open_group_op(%{operation_id: "op-6", type: "teleport_group"}),
        Map.delete(open_group_op(%{operation_id: "op-7"}), "type"),
        "not-an-operation"
      ]

      for operation <- unusable do
        assert %{"status" => "rejected", "code" => "invalid_operation"} =
                 submit_one(conn, operation),
               "expected invalid_operation for #{inspect(operation)}"
      end

      assert json_response(get(conn, "/api/v1/groups/group-81"), 404)
    end

    test "echoes the operation id it was given", %{conn: conn} do
      assert %{"operation_id" => "op-1001"} =
               submit_one(conn, open_group_op(%{operation_id: "op-1001"}))
    end
  end
end
