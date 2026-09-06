defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerTestHelpers

  @moduledoc false

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result of an applied operation" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 3000})
      ])

      conn = get(build_conn(), "/api/v1/operations/op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-1",
                 "amount_cents" => 3000,
                 "outstanding_deposit_cents" => 6000,
                 "revision" => 2
               }
             }
    end

    test "returns the stored result of a rejected operation with its details" do
      apply_operations!(build_conn(), [
        open_group_operation(),
        payment_operation(%{"operation_id" => "op-pay", "amount_cents" => 1000})
      ])

      conn =
        submit(build_conn(), [
          payment_operation(%{
            "operation_id" => "op-stale",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ])

      assert [%{"code" => "stale_revision"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/operations/op-stale")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "operation_id" => "op-stale",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-1",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             }
    end

    test "exposes only the stored result, not the submission or commit order" do
      apply_operations!(build_conn(), [
        open_group_operation(%{"operation_id" => "op-a"}),
        payment_operation(%{"operation_id" => "op-b", "amount_cents" => 1000})
      ])

      conn = get(build_conn(), "/api/v1/operations/op-b")
      data = json_response(conn, 200)["data"]

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 "operation_id",
                 "status",
                 "group_id",
                 "amount_cents",
                 "outstanding_deposit_cents",
                 "revision"
               ])
    end

    test "returns the stored result for an operation that was never applied" do
      conn = submit(build_conn(), [payment_operation(%{"group_id" => "nope"})])
      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      conn = get(build_conn(), "/api/v1/operations/op-pay")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "operation_id" => "op-pay",
                 "status" => "rejected",
                 "code" => "group_not_found"
               }
             }
    end

    test "an unknown operation identifier is not found" do
      conn = get(build_conn(), "/api/v1/operations/op-never")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end
end
