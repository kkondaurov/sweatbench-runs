defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase

  describe "batch envelope" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/partner-batches", %{})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "rejects a body whose operations field is not an array", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/partner-batches", %{"operations" => %{"type" => "open_group"}})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "accepts an empty operations array", %{conn: conn} do
      assert %{"results" => []} = submit_batch(conn, [])
    end

    test "returns one result per operation in order", %{conn: conn} do
      first = valid_open_operation()
      second = %{valid_open_operation() | "operation_id" => "op-1002", "group_id" => "group-82"}

      %{"results" => results} = submit_batch(conn, [first, second])

      assert Enum.map(results, & &1["operation_id"]) == ["op-1001", "op-1002"]
      assert Enum.all?(results, &(&1["status"] == "applied"))
    end

    test "a rejected operation does not stop later operations", %{conn: conn} do
      duplicate = %{valid_open_operation() | "operation_id" => "op-1002"}
      other = %{valid_open_operation() | "operation_id" => "op-1003", "group_id" => "group-82"}

      %{"results" => [first, second, third]} =
        submit_batch(conn, [valid_open_operation(), duplicate, other])

      assert first["status"] == "applied"
      assert second["status"] == "rejected"
      assert second["code"] == "group_already_exists"
      assert third["status"] == "applied"
    end
  end

  describe "open_group" do
    test "applies the API example and reports the deposit", %{conn: conn} do
      %{"results" => [result]} = submit_batch(conn, [valid_open_operation()])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19500,
               "revision" => 1
             }
    end

    test "persists the group with booking, stay, rooms, and totals", %{conn: conn} do
      submit_batch(conn, [valid_open_operation()])

      assert group_data(conn, "group-81") == %{
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
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 15000,
                   "status" => "active",
                   "deposit_due_cents" => 9000,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 17500,
                   "status" => "active",
                   "deposit_due_cents" => 10500,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 97500,
               "deposit_due_cents" => 19500,
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19500
             }
    end

    test "uses the operation occurred_on as the group booked_on", %{conn: conn} do
      open_group_fixture(conn, %{"occurred_on" => "2026-09-01"})
      assert group_data(conn, "group-81")["booked_on"] == "2026-09-01"
    end

    test "rounds each flexible room deposit separately before summing", %{conn: conn} do
      operation = %{
        valid_open_operation()
        | "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10003},
            %{"room_id" => "room-b", "nightly_rate_cents" => 10003}
          ]
      }

      %{"results" => [result]} = submit_batch(conn, [operation])

      # Three nights at 10003 is 30009 per room; 20% is 6001.8, which rounds to
      # 6002 per room. Rounding the summed amount instead would give 12002.
      assert result["deposit_due_cents"] == 12004
    end

    test "requires the full lodging amount for advance purchase rooms", %{conn: conn} do
      open_group_fixture(conn, %{"rate_plan" => "advance_purchase"})

      data = group_data(conn, "group-81")
      assert data["rate_plan"] == "advance_purchase"
      assert data["deposit_due_cents"] == data["lodging_total_cents"]
      assert data["deposit_due_cents"] == 97500
    end

    test "rejects a duplicate group identifier", %{conn: conn} do
      duplicate = %{valid_open_operation() | "operation_id" => "op-1002"}

      %{"results" => [_first, second]} = submit_batch(conn, [valid_open_operation(), duplicate])

      assert second == %{
               "operation_id" => "op-1002",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "group-81"
             }
    end

    test "rejects a duplicate group identifier across batches", %{conn: conn} do
      open_group_fixture(conn)
      duplicate = %{valid_open_operation() | "operation_id" => "op-1002"}
      %{"results" => [result]} = submit_batch(conn, [duplicate])

      assert result["status"] == "rejected"
      assert result["code"] == "group_already_exists"
    end

    test "rejects stays without at least one night", %{conn: conn} do
      zero_nights = %{valid_open_operation() | "departure_on" => "2026-12-10"}

      backwards = %{
        valid_open_operation()
        | "operation_id" => "op-1002",
          "departure_on" => "2026-12-09"
      }

      %{"results" => [first, second]} = submit_batch(conn, [zero_nights, backwards])

      assert first["code"] == "invalid_stay"
      assert second["code"] == "invalid_stay"
    end

    test "rejects stay dates that cannot be parsed", %{conn: conn} do
      operation = %{valid_open_operation() | "arrival_on" => "not-a-date"}

      %{"results" => [result]} = submit_batch(conn, [operation])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_stay"
    end

    test "rejects a group without rooms", %{conn: conn} do
      %{"results" => [result]} =
        submit_batch(conn, [%{valid_open_operation() | "rooms" => []}])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rooms"
    end

    test "rejects duplicate room identifiers within the group", %{conn: conn} do
      operation = %{
        valid_open_operation()
        | "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
          ]
      }

      %{"results" => [result]} = submit_batch(conn, [operation])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rooms"
    end

    test "rejects rooms with unusable nightly rates", %{conn: conn} do
      missing_rate = %{valid_open_operation() | "rooms" => [%{"room_id" => "room-a"}]}

      negative_rate = %{
        valid_open_operation()
        | "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => -1}]
      }

      string_rate = %{
        valid_open_operation()
        | "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => "15000"}]
      }

      fractional_rate = %{
        valid_open_operation()
        | "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 150.5}]
      }

      not_a_room = %{valid_open_operation() | "rooms" => ["room-a"]}

      operations =
        [missing_rate, negative_rate, string_rate, fractional_rate, not_a_room]
        |> Enum.with_index(1)
        |> Enum.map(fn {operation, index} ->
          Map.put(operation, "operation_id", "op-10#{index}")
        end)

      %{"results" => results} = submit_batch(conn, operations)

      assert Enum.all?(results, &(&1["code"] == "invalid_rooms"))
    end

    test "rejects unknown rate plans", %{conn: conn} do
      %{"results" => [result]} =
        submit_batch(conn, [%{valid_open_operation() | "rate_plan" => "nonrefundable"}])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_rate_plan"
    end

    test "a rejected open_group does not create the group", %{conn: conn} do
      submit_batch(conn, [%{valid_open_operation() | "rate_plan" => "unknown"}])

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "ignores expected_revision", %{conn: conn} do
      operation = Map.put(valid_open_operation(), "expected_revision", 99)

      %{"results" => [result]} = submit_batch(conn, [operation])

      assert result["status"] == "applied"
      assert result["revision"] == 1
    end
  end

  describe "invalid operations" do
    test "rejects unknown operation types", %{conn: conn} do
      operation = %{valid_open_operation() | "type" => "extend_group"}

      %{"results" => [result]} = submit_batch(conn, [operation])

      assert result == %{
               "operation_id" => "op-1001",
               "status" => "rejected",
               "code" => "invalid_operation",
               "group_id" => "group-81"
             }
    end

    test "rejects operations missing identifying or required data", %{conn: conn} do
      missing_operation_id = Map.delete(valid_open_operation(), "operation_id")

      others =
        [
          Map.delete(valid_open_operation(), "type"),
          Map.delete(valid_open_operation(), "occurred_on"),
          %{valid_open_operation() | "occurred_on" => "yesterday"},
          Map.delete(valid_open_operation(), "group_id"),
          Map.delete(valid_open_operation(), "arrival_on"),
          Map.delete(valid_open_operation(), "rooms"),
          %{valid_open_operation() | "rooms" => "room-a"}
        ]
        |> Enum.with_index(2)
        |> Enum.map(fn {operation, index} ->
          Map.put(operation, "operation_id", "op-10#{index}")
        end)

      %{"results" => results} = submit_batch(conn, [missing_operation_id | others])

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_operation"))
      assert hd(results)["operation_id"] == nil
    end

    test "rejects operations that are not objects", %{conn: conn} do
      %{"results" => [first, second]} = submit_batch(conn, ["open_group", 7])

      assert first == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert second == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }
    end

    test "an invalid operation leaves domain state unchanged but is remembered", %{conn: conn} do
      open_group_fixture(conn)

      operation = %{
        "operation_id" => "op-2001",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81"
      }

      %{"results" => [result]} = submit_batch(conn, [operation])
      assert result["code"] == "invalid_operation"

      data = group_data(conn, "group-81")
      assert data["revision"] == 1
      assert data["deposit_paid_cents"] == 0

      %{"results" => [retry]} = submit_batch(conn, [operation])
      assert retry == result
    end
  end
end
