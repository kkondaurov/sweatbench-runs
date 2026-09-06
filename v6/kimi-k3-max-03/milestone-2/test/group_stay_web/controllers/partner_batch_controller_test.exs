defmodule GroupStayWeb.PartnerBatchControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStayWeb.BatchHelpers

  defp post_batch(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", body)
  end

  describe "POST /api/v1/partner-batches batch validation" do
    test "returns 422 invalid_batch when operations is missing", %{conn: conn} do
      conn = post_batch(conn, %{})

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "returns 422 invalid_batch when operations is not a list", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => "not-a-list"})

      assert %{"error" => %{"code" => "invalid_batch"}} = json_response(conn, 422)
    end

    test "an empty operations list returns 200 with empty results", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => []})

      assert %{"results" => []} = json_response(conn, 200)
    end

    test "a non-map operation is rejected with invalid_operation", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => ["not-an-operation"]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end
  end

  describe "open_group" do
    test "applies and reports the group and deposit due", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_group_op()]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-open",
                   "status" => "applied",
                   "group_id" => "group-81",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rounds each flexible room deposit separately, half-cent upward", %{conn: conn} do
      # room-a: 1 night * 251 = 251 lodging, 20% = 50.2 -> 50
      # room-b: 1 night * 250 = 250 lodging, 20% = 50 -> 50
      # total 100 (not 20% of the combined 501 = 100.2 -> 100)
      op =
        open_group_op(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 251},
            %{"room_id" => "room-b", "nightly_rate_cents" => 250}
          ]
        })

      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "applied", "deposit_due_cents" => 100}]} =
               json_response(conn, 200)
    end

    test "advance_purchase requires the full lodging amount as deposit", %{conn: conn} do
      op = open_group_op(%{"rate_plan" => "advance_purchase"})
      conn = post_batch(conn, %{"operations" => [op]})

      # 3 nights * (15000 + 17500) = 97500
      assert %{
               "results" => [%{"status" => "applied", "deposit_due_cents" => 97_500}]
             } = json_response(conn, 200)
    end

    test "rejects a duplicate group id without creating anything new", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_group_op()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn =
        post_batch(build_conn(), %{"operations" => [open_group_op(%{"operation_id" => "op-2"})]})

      assert %{
               "results" => [
                 %{
                   "operation_id" => "op-2",
                   "status" => "rejected",
                   "code" => "group_already_exists",
                   "group_id" => "group-81"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects invalid rate plans", %{conn: conn} do
      op = open_group_op(%{"rate_plan" => "corporate"})
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rate_plan"}]} =
               json_response(conn, 200)
    end

    test "rejects missing rate plans", %{conn: conn} do
      op = open_group_op() |> Map.delete("rate_plan")
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rate_plan"}]} =
               json_response(conn, 200)
    end

    test "rejects a stay without a night", %{conn: conn} do
      op = open_group_op(%{"departure_on" => "2026-12-10"})
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects departure before arrival", %{conn: conn} do
      op = open_group_op(%{"departure_on" => "2026-12-09"})
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects unparseable stay dates", %{conn: conn} do
      op = open_group_op(%{"arrival_on" => "12/10/2026"})
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_stay"}]} =
               json_response(conn, 200)
    end

    test "rejects an empty rooms list", %{conn: conn} do
      op = open_group_op(%{"rooms" => []})
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
               json_response(conn, 200)
    end

    test "rejects duplicate room identifiers within the group", %{conn: conn} do
      op =
        open_group_op(%{
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 17_500}
          ]
        })

      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
               json_response(conn, 200)
    end

    test "rejects a room without a positive rate", %{conn: conn} do
      op = open_group_op(%{"rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 0}]})
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_rooms"}]} =
               json_response(conn, 200)
    end

    test "rejects operations missing the data needed to apply them", %{conn: conn} do
      op = open_group_op() |> Map.delete("guest_id")
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end

    test "rejects an operation missing its group id", %{conn: conn} do
      op = open_group_op() |> Map.delete("group_id")
      conn = post_batch(conn, %{"operations" => [op]})

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_operation"}]} =
               json_response(conn, 200)
    end

    test "a rejected open_group creates no group", %{conn: conn} do
      op = open_group_op(%{"rate_plan" => "nope"})
      post_batch(conn, %{"operations" => [op]})

      conn = get(build_conn(), ~p"/api/v1/groups/group-81")
      assert json_response(conn, 404)
    end
  end

  describe "open_group within batches" do
    test "a rejected operation does not stop later operations", %{conn: conn} do
      operations = [
        open_group_op(%{"rate_plan" => "nope"}),
        open_group_op(%{"group_id" => "group-82"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{
               "results" => [
                 %{"status" => "rejected", "code" => "invalid_rate_plan"},
                 %{"status" => "applied", "group_id" => "group-82", "revision" => 1}
               ]
             } = json_response(conn, 200)
    end
  end
end
