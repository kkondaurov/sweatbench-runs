defmodule GroupStayWeb.Acceptance.OpenGroupTest do
  use GroupStayWeb.ConnCase, async: true

  describe "opening a group" do
    test "returns the deposit requirement and revision 1" do
      result = open_group!(build_conn())

      assert result == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
    end

    test "stores the group with its stay, rate plan, rooms, and booked_on date" do
      open_group!(build_conn())

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
               "rooms" => [
                 %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                 %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19500
             } = group_data("group-81")
    end

    test "a flexible room requires 20% of its lodging amount, rounded per room" do
      # Two rooms at 1002 cents for one night: each deposit is 200.4 -> 200,
      # so the group deposit is 400 even though 20% of the total (400.8) would
      # round to 401.
      result =
        open_group!(build_conn(), %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 1002},
            %{"room_id" => "room-b", "nightly_rate_cents" => 1002}
          ]
        })

      assert result["deposit_due_cents"] == 400
    end

    test "percentage remainders below half a cent round down" do
      result =
        open_group!(build_conn(), %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1001}]
        })

      assert result["deposit_due_cents"] == 200
    end

    test "percentage remainders at or above half a cent round up" do
      result =
        open_group!(build_conn(), %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1003}]
        })

      assert result["deposit_due_cents"] == 201
    end

    test "an advance-purchase room requires its full lodging amount" do
      result =
        open_group!(build_conn(), %{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 3333}]
        })

      assert result["deposit_due_cents"] == 9999

      assert group_data("group-81")["lodging_total_cents"] == 9999
    end

    test "the same group_id cannot be opened twice" do
      open_group!(build_conn())
      result = apply_one!(build_conn(), open_group_operation(%{"operation_id" => "op-again"}))
      assert %{"status" => "rejected", "code" => "group_already_exists"} = result

      assert group_data("group-81")["revision"] == 1
    end

    test "expected_revision is not used by open_group" do
      result = open_group!(build_conn(), %{"expected_revision" => 99})
      assert %{"status" => "applied", "revision" => 1} = result
    end
  end

  describe "open_group validation failures" do
    test "a stay must include at least one night" do
      result =
        apply_one!(
          build_conn(),
          open_group_operation(%{"arrival_on" => "2026-12-10", "departure_on" => "2026-12-10"})
        )

      assert %{"status" => "rejected", "code" => "invalid_stay"} = result
      assert group_missing?("group-81")
    end

    test "a departure before arrival is rejected" do
      result =
        apply_one!(
          build_conn(),
          open_group_operation(%{"arrival_on" => "2026-12-13", "departure_on" => "2026-12-10"})
        )

      assert %{"status" => "rejected", "code" => "invalid_stay"} = result
      assert group_missing?("group-81")
    end

    test "unusable arrival or departure dates are rejected" do
      for attrs <- [
            %{"arrival_on" => "2026-02-30"},
            %{"arrival_on" => "December"},
            %{"departure_on" => 12},
            %{"departure_on" => "2026-12-13T00:00:00"}
          ] do
        result = apply_one!(build_conn(), open_group_operation(attrs))
        assert %{"status" => "rejected", "code" => "invalid_stay"} = result
      end

      assert group_missing?("group-81")
    end

    test "a stay must include at least one room" do
      result = apply_one!(build_conn(), open_group_operation(%{"rooms" => []}))
      assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      assert group_missing?("group-81")
    end

    test "room identifiers must be unique within the group" do
      result =
        apply_one!(
          build_conn(),
          open_group_operation(%{
            "rooms" => [
              %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
              %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
            ]
          })
        )

      assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      assert group_missing?("group-81")
    end

    test "rooms must be usable room entries" do
      for attrs <- [
            %{"rooms" => nil},
            %{"rooms" => "room-a"},
            %{
              "rooms" => [
                %{"room_id" => "room-a"},
                %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
              ]
            },
            %{
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 0},
                %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
              ]
            },
            %{
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => -1},
                %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
              ]
            },
            %{
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 1750.5},
                %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
              ]
            },
            %{"rooms" => [%{"nightly_rate_cents" => 15000}]}
          ] do
        result = apply_one!(build_conn(), open_group_operation(attrs))
        assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      end

      assert group_missing?("group-81")
    end

    test "the rate plan must be known" do
      for attrs <- [%{"rate_plan" => "mystery"}, %{"rate_plan" => nil}] do
        result = apply_one!(build_conn(), open_group_operation(attrs))
        assert %{"status" => "rejected", "code" => "invalid_rate_plan"} = result
      end

      assert group_missing?("group-81")
    end
  end

  describe "reading a group" do
    test "a missing group returns 404 with group_not_found" do
      assert %{"error" => %{"code" => "group_not_found"}} =
               json_response(get_group(build_conn(), "nope"), 404)
    end
  end

  defp group_missing?(group_id) do
    %{status: 404} = get_group(build_conn(), group_id)
    true
  rescue
    _ -> false
  end

  defp group_data(group_id) do
    assert %{status: 200} = conn = get_group(build_conn(), group_id)
    json_response(conn, 200)["data"]
  end
end
