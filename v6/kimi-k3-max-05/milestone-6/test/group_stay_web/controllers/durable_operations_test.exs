defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)["data"]
  end

  defp get_operation(operation_id) do
    get(build_conn(), ~p"/api/v1/operations/#{operation_id}")
  end

  describe "retry behavior" do
    test "an exact retry returns the original result without reapplying", %{conn: conn} do
      operations = [open_op(), payment_op()]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => first_results} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => retry_results} = json_response(conn, 200)

      assert retry_results == first_results

      # the payment was not applied twice
      group = get_group("group-81")
      assert group["revision"] == 2
      assert group["deposit_paid_cents"] == 5_000
    end

    test "JSON object key order is irrelevant for equivalence", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [payment_op()]})
      assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(conn, 200)

      shuffled = %{
        "amount_cents" => 5_000,
        "group_id" => "group-81",
        "occurred_on" => "2026-10-04",
        "type" => "record_cash_payment",
        "operation_id" => "op-pay"
      }

      conn = post_batch(build_conn(), %{"operations" => [shuffled]})
      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"
    end

    test "rejected results are remembered and replayed", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [payment_op()]})

      assert %{"results" => [%{"status" => "rejected", "code" => "group_not_found"}]} =
               json_response(conn, 200)

      # the group now exists, but the retry still receives the original rejection
      conn = post_batch(build_conn(), %{"operations" => [open_op(), payment_op()]})
      assert %{"results" => [_, result]} = json_response(conn, 200)
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"

      group = get_group("group-81")
      assert group["revision"] == 1
      assert group["deposit_paid_cents"] == 0
    end

    test "reusing an identifier with a different payload conflicts and keeps the original", %{
      conn: conn
    } do
      conn = post_batch(conn, %{"operations" => [open_op()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conflicted = open_op(%{"group_id" => "group-other"})
      conn = post_batch(build_conn(), %{"operations" => [conflicted]})

      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-open",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-other"
             }

      # the original record is not replaced
      conn = get_operation("op-open")
      assert %{"data" => stored} = json_response(conn, 200)
      assert stored["status"] == "applied"
      assert stored["group_id"] == "group-81"

      # the conflicting operation had no effect
      conn = get(build_conn(), ~p"/api/v1/groups/group-other")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end

    test "array order and values remain significant", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      reordered_rooms =
        open_op(%{
          "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
        })

      conn = post_batch(build_conn(), %{"operations" => [reordered_rooms]})
      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "operation_id_conflict"
    end

    test "an exact retry of a stale rejection returns the stored revisions", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        payment_op(%{
          "operation_id" => "op-stale",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, stale]} = json_response(conn, 200)
      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2

      # the revision has since moved on, but the retry reports the original one
      conn =
        post_batch(build_conn(), %{"operations" => [payment_op(%{"operation_id" => "op-3"})]})

      assert %{"results" => [_]} = json_response(conn, 200)

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            payment_op(%{
              "operation_id" => "op-stale",
              "amount_cents" => 100,
              "expected_revision" => 1
            })
          ]
        })

      assert %{"results" => [retry]} = json_response(conn, 200)
      assert retry == stale

      # retrying the stale operation with a corrected revision is a different payload
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            payment_op(%{
              "operation_id" => "op-stale",
              "amount_cents" => 100,
              "expected_revision" => 3
            })
          ]
        })

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["code"] == "operation_id_conflict"
    end

    test "idempotency records survive outside the request that created them", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [open_op()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # a fresh connection (a fresh process) still sees the durable record
      conn = get_operation("op-open")

      assert %{
               "data" => %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result for applied and rejected operations", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"operation_id" => "op-bad", "amount_cents" => -5})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [applied, rejected]} = json_response(conn, 200)

      conn = get_operation("op-open")
      assert %{"data" => data} = json_response(conn, 200)
      assert data == applied

      conn = get_operation("op-bad")
      assert %{"data" => data} = json_response(conn, 200)
      assert data == rejected
    end

    test "returns the stored result for payment-targeted operations", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        %{
          "operation_id" => "op-reduce",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "op-pay",
          "amount_cents" => 1_000
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, reduced]} = json_response(conn, 200)

      conn = get_operation("op-reduce")
      assert %{"data" => data} = json_response(conn, 200)
      assert data == reduced
      assert data["payment_operation_id"] == "op-pay"
      assert data["group_id"] == "group-81"
    end

    test "returns 404 for an unknown operation", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/operations/op-unknown")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end
end
