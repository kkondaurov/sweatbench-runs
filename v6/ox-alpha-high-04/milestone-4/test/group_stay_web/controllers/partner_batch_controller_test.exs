defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  describe "POST /api/v1/partner-batches - opening groups" do
    test "applies the documented flexible example and returns the applied result", %{conn: conn} do
      conn =
        post(conn, "/api/v1/partner-batches", batch([open_group(%{"operation_id" => "op-1001"})]))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-1001",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19500,
                   "revision" => 1
                 }
               ]
             }
    end

    test "rounds each flexible room deposit separately, then sums the rooms", %{conn: conn} do
      op =
        open_group(%{
          "group_id" => "group-round",
          "rooms" => [
            %{"room_id" => "r1", "nightly_rate_cents" => 12333},
            %{"room_id" => "r2", "nightly_rate_cents" => 12345}
          ]
        })

      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      # room 1: 3 * 12333 = 36999 lodging, 20% = 7399.8 -> 7400
      # room 2: 3 * 12345 = 37035 lodging, 20% = 7407 exactly
      assert [%{"status" => "applied", "deposit_due_cents" => 14807}] =
               json_response(conn, 200)["results"]
    end

    test "an advance_purchase room deposits its full lodging amount", %{conn: conn} do
      op =
        open_group(%{
          "group_id" => "group-ap",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12333}]
        })

      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      # 3 * 12333 = 36999 lodging and deposit
      assert [%{"status" => "applied", "deposit_due_cents" => 36999}] =
               json_response(conn, 200)["results"]
    end

    test "the occurred_on date becomes the group's booked_on date", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"booked_on" => "2026-10-03"}} = json_response(conn, 200)
    end

    test "rejects a duplicate group with group_already_exists and leaves it unchanged", %{
      conn: conn
    } do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn =
        post(
          conn,
          "/api/v1/partner-batches",
          batch([open_group(%{"operation_id" => "op-again"})])
        )

      assert [%{"status" => "rejected", "code" => "group_already_exists"}] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"revision" => 1, "deposit_due_cents" => 19500}} =
               json_response(conn, 200)
    end
  end

  describe "opening groups - domain validation" do
    test "requires at least one night", %{conn: conn} do
      op = open_group(%{"departure_on" => "2026-12-10"})
      assert_rejected(conn, [op], "invalid_stay")
    end

    test "rejects departure before arrival", %{conn: conn} do
      op = open_group(%{"departure_on" => "2026-12-09"})
      assert_rejected(conn, [op], "invalid_stay")
    end

    test "rejects unparseable stay dates", %{conn: conn} do
      assert_rejected(conn, [open_group(%{"arrival_on" => "December"})], "invalid_stay")

      assert_rejected(
        conn,
        [open_group(%{"operation_id" => "op-dep-bad", "departure_on" => "2026-13-40"})],
        "invalid_stay"
      )
    end

    test "requires at least one room and unique room identifiers", %{conn: conn} do
      assert_rejected(conn, [open_group(%{"rooms" => []})], "invalid_rooms")

      op =
        open_group(%{
          "operation_id" => "op-dup-room",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 16000}
          ]
        })

      assert_rejected(conn, [op], "invalid_rooms")
    end

    test "rejects unknown rate plans and unusable rates", %{conn: conn} do
      assert_rejected(conn, [open_group(%{"rate_plan" => "saver"})], "invalid_rate_plan")

      assert_rejected(
        conn,
        [
          open_group(%{
            "operation_id" => "op-zero-rate",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 0}]
          })
        ],
        "invalid_rate_plan"
      )
    end
  end

  describe "POST /api/v1/partner-batches - invalid operations" do
    test "rejects unknown operation types", %{conn: conn} do
      op = %{"operation_id" => "op-x", "type" => "shrink_group", "occurred_on" => "2026-10-03"}
      assert_rejected(conn, [op], "invalid_operation")
    end

    test "rejects operations missing data needed to identify and apply them", %{conn: conn} do
      assert_rejected(conn, [open_group(%{"group_id" => nil})], "invalid_operation")

      assert_rejected(
        conn,
        [open_group(%{"guest_id" => "", "operation_id" => "op-2"})],
        "invalid_operation"
      )

      assert_rejected(
        conn,
        [open_group(%{"rooms" => nil, "operation_id" => "op-3"})],
        "invalid_operation"
      )

      assert_rejected(
        conn,
        [pay("group-81", nil, %{"amount_cents" => nil, "operation_id" => "op-pay-missing"})],
        "invalid_operation"
      )

      assert_rejected(
        conn,
        [reschedule("group-81", nil, %{"new_arrival_on" => nil})],
        "invalid_operation"
      )

      assert_rejected(
        conn,
        [%{"type" => "cancel_group", "occurred_on" => "2026-10-03"}],
        "invalid_operation"
      )
    end
  end

  describe "POST /api/v1/partner-batches - invalid batches" do
    test "returns 422 invalid_batch without an operations array", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{"nope" => []})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => "not-a-list"})
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end
  end

  defp assert_rejected(conn, operations, code) do
    conn = post(conn, "/api/v1/partner-batches", batch(operations))
    results = json_response(conn, 200)["results"]

    assert Enum.all?(results, fn result ->
             result["status"] == "rejected" and result["code"] == code
           end)

    results
  end
end
