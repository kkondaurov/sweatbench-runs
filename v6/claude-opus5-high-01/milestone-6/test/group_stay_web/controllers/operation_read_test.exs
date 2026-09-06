defmodule GroupStayWeb.OperationReadTest do
  use GroupStayWeb.ConnCase

  import GroupStayWeb.PartnerCase

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result of an applied operation", %{conn: conn} do
      applied = submit_one(conn, open_group_op())

      assert %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 19_500,
               "revision" => 1
             } = read_operation(conn, "op-open")

      assert applied == read_operation(conn, "op-open")
    end

    test "returns the stored result of a rejected operation", %{conn: conn} do
      rejected = submit_one(conn, payment_op())

      assert %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-81"
             } = rejected

      assert rejected == read_operation(conn, "op-pay")
    end

    test "exposes only the stored result", %{conn: conn} do
      submit_one(conn, open_group_op())

      assert ~w(deposit_due_cents group_id operation_id revision status) ==
               conn |> read_operation("op-open") |> Map.keys() |> Enum.sort()
    end

    test "reports an unknown identifier as missing", %{conn: conn} do
      assert %{"error" => %{"code" => "operation_not_found"}} =
               conn |> get("/api/v1/operations/op-open") |> json_response(404)
    end

    test "does not remember an operation that was never usable", %{conn: conn} do
      submit_one(conn, Map.delete(payment_op(), "operation_id"))

      assert json_response(get(conn, "/api/v1/operations/op-pay"), 404)
    end
  end
end
